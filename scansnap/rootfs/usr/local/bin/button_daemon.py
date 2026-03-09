#!/usr/bin/env python3
"""
ScanSnap iX500 button daemon.

Detects the physical scan button via direct USB bulk transfer using the
GET_HW_STATUS SCSI command (opcode 0xc2), as reverse-engineered by
stapelberg/scan2drive (github.com/stapelberg/scan2drive).

The SANE fujitsu backend does NOT expose the iX500 scan button as a SANE
option, so scanbd-based approaches cannot detect it. This daemon claims
USB interface 0 directly, polls for button state, and coordinates with
SANE by releasing the interface before scanning and reclaiming it after.

Also serves a minimal HTTP endpoint so users can trigger scans from the
Home Assistant dashboard (ingress panel) without needing the physical button.

USB protocol (from scan2drive/internal/fss500/fss500.go):
  Interface 0, class 0xff (vendor-specific)
  Bulk OUT endpoint 0x02 (host → device)
  Bulk IN  endpoint 0x81 (device → host)

  Command: 31-byte frame
    byte[0x00] = 0x43  (frame header)
    byte[0x13] = 0xc2  (SCSI opcode: GET_HW_STATUS)
    byte[0x1b] = 0x0c  (allocation length = 12 bytes)

  Response: 12 bytes
    byte[3] & 0x80 = Hopper (paper loaded in ADF)
    byte[4] & 0x01 = ScanSw (scan button pressed)
    byte[4] & 0x04 = SendSw
"""

import os
import sys
import time
import threading
import subprocess
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
import usb.core
import usb.util

VENDOR_ID     = 0x04c5
PRODUCT_ID    = 0x132b
USB_INTERFACE = 0
EP_OUT        = 0x02   # bulk OUT: host → device
EP_IN         = 0x81   # bulk IN:  device → host
SCAN_SCRIPT   = "/etc/scanbd/scripts/scan.sh"
ADDON_CONF    = "/etc/scanbd/addon.conf"
POLL_INTERVAL = 0.5    # seconds between USB polls
SCAN_DEBOUNCE = 5.0    # minimum seconds between triggered scans
HTTP_PORT     = int(os.environ.get("INGRESS_PORT", "8099"))

# Set by the HTTP handler; consumed by the poll loop
http_scan_request = threading.Event()


def log(msg):
    print(f"[button_daemon] {msg}", file=sys.stderr, flush=True)


# ── USB ───────────────────────────────────────────────────────────────────────

def build_get_hw_status_cmd() -> bytes:
    """Build the 31-byte USB command frame for GET_HW_STATUS."""
    cmd = bytearray(31)
    cmd[0x00] = 0x43  # frame header magic
    cmd[0x13] = 0xc2  # SCSI opcode: GET_HW_STATUS
    cmd[0x1b] = 0x0c  # allocation length = 12 bytes
    return bytes(cmd)


def query_hw_status(dev) -> bytes | None:
    """Send GET_HW_STATUS and return the 12-byte response, or None on error."""
    try:
        dev.write(EP_OUT, build_get_hw_status_cmd(), timeout=3000)
        status = bytes(dev.read(EP_IN, 12, timeout=3000))
        # Drain any trailing response bytes
        try:
            dev.read(EP_IN, 32, timeout=200)
        except usb.core.USBError:
            pass
        return status
    except usb.core.USBError as e:
        log(f"USB read error: {e}")
        return None


def scan_button_pressed(status: bytes | None) -> bool:
    """True if the ScanSw bit is set in the hw status response."""
    return bool(status and len(status) >= 5 and status[4] & 0x01)


def open_usb() -> usb.core.Device | None:
    """Find the iX500 and claim interface 0 for button polling."""
    dev = usb.core.find(idVendor=VENDOR_ID, idProduct=PRODUCT_ID)
    if dev is None:
        # Log all visible USB devices to aid diagnosis
        all_devs = list(usb.core.find(find_all=True))
        if all_devs:
            log(f"USB devices visible ({len(all_devs)} total), looking for "
                f"{VENDOR_ID:04x}:{PRODUCT_ID:04x}:")
            for d in all_devs:
                try:
                    log(f"  {d.idVendor:04x}:{d.idProduct:04x}")
                except Exception:
                    pass
        else:
            log("No USB devices visible at all — check container USB access / full_access:true")
        return None
    try:
        if dev.is_kernel_driver_active(USB_INTERFACE):
            dev.detach_kernel_driver(USB_INTERFACE)
            log("Detached kernel driver from USB interface 0")
    except Exception:
        pass
    dev.set_configuration()
    usb.util.claim_interface(dev, USB_INTERFACE)
    log("USB interface 0 claimed — polling for button press")
    return dev


def close_usb(dev: usb.core.Device) -> None:
    """Release USB interface so SANE can open the scanner."""
    try:
        usb.util.release_interface(dev, USB_INTERFACE)
        usb.util.dispose_resources(dev)
        log("USB interface released for SANE")
    except Exception as e:
        log(f"Warning during USB release: {e}")


# ── Scan pipeline ─────────────────────────────────────────────────────────────

def read_addon_conf() -> dict:
    """Read /etc/scanbd/addon.conf into a dict (best-effort)."""
    conf = {}
    try:
        with open(ADDON_CONF) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    conf[k.strip()] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    return conf


def run_scan(dev: usb.core.Device, source: str) -> usb.core.Device | None:
    """
    Release USB, invoke scan.sh (which uses SANE), then return a fresh
    USB handle after SANE has finished.

    Returns the newly-opened USB device, or None if it can't be re-opened.
    """
    log(f"Scan triggered by: {source}")
    close_usb(dev)

    conf = read_addon_conf()
    env = os.environ.copy()
    env["SCANBD_ACTION"] = "scan"
    env["SCANBD_DEVICE"] = conf.get("SCANBD_DEVICE", "fujitsu")

    log("Invoking scan.sh…")
    result = subprocess.run([SCAN_SCRIPT], env=env)
    log(f"scan.sh exited with code {result.returncode}")

    # Give SANE a moment to release the device before we reclaim it
    log("Waiting 2s for SANE to release USB…")
    time.sleep(2)

    new_dev = open_usb()
    if new_dev is None:
        log("WARNING: could not reclaim USB after scan — will retry in poll loop")
    return new_dev


# ── HTTP server (HA ingress panel) ────────────────────────────────────────────

SCAN_PAGE = b"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ScanSnap iX500</title>
  <style>
    *{box-sizing:border-box}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
         display:flex;flex-direction:column;align-items:center;
         justify-content:center;min-height:100vh;margin:0;
         background:#1c1c1c;color:#f0f0f0}
    h2{font-size:1.4rem;font-weight:500;margin-bottom:2rem;letter-spacing:.03em}
    button{font-size:1.1rem;padding:.9rem 2.4rem;border:none;border-radius:10px;
           background:#0288d1;color:#fff;cursor:pointer;transition:background .15s}
    button:hover{background:#0277bd}
    button:active{background:#01579b}
    button:disabled{background:#555;cursor:default}
    #status{margin-top:1.5rem;font-size:.85rem;color:#aaa;min-height:1.2em}
  </style>
</head>
<body>
  <h2>ScanSnap iX500</h2>
  <button id="btn" onclick="scan()">Scan Now</button>
  <div id="status"></div>
  <script>
    function scan(){
      const btn=document.getElementById('btn');
      const st=document.getElementById('status');
      btn.disabled=true;
      st.innerText='Starting scan\u2026';
      fetch('scan',{method:'POST'})
        .then(r=>r.text())
        .then(t=>{st.innerText=t;setTimeout(()=>{btn.disabled=false;st.innerText=''},4000)})
        .catch(()=>{st.innerText='Error contacting daemon.';btn.disabled=false});
    }
  </script>
</body>
</html>"""


class ScanHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(SCAN_PAGE)

    def do_POST(self):
        http_scan_request.set()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Scan queued")

    def log_message(self, fmt, *args):
        log(f"HTTP {fmt % args}")


def start_http_server():
    server = HTTPServer(("0.0.0.0", HTTP_PORT), ScanHandler)
    log(f"HTTP trigger listening on :{HTTP_PORT} (HA ingress panel)")
    server.serve_forever()


# ── Main poll loop ────────────────────────────────────────────────────────────

def main():
    log("Starting ScanSnap iX500 button daemon")
    log(f"  USB: GET_HW_STATUS on ep 0x{EP_OUT:02x}/0x{EP_IN:02x}, every {POLL_INTERVAL}s")
    log(f"  HTTP trigger: POST :{HTTP_PORT}/scan")

    threading.Thread(target=start_http_server, daemon=True).start()

    last_scan = 0.0

    while True:
        dev = None
        try:
            dev = open_usb()
            if dev is None:
                log("Scanner not found — retrying in 5s…")
                time.sleep(5)
                continue

            while True:
                # Check physical button and HTTP trigger
                status   = query_hw_status(dev)
                physical = scan_button_pressed(status)
                virtual  = http_scan_request.is_set()

                if physical or virtual:
                    now = time.time()
                    if now - last_scan < SCAN_DEBOUNCE:
                        log(f"Scan request ignored — {SCAN_DEBOUNCE}s debounce active")
                        http_scan_request.clear()
                        time.sleep(1)
                        continue

                    http_scan_request.clear()
                    source = "physical button" if physical else "HA dashboard"
                    dev = run_scan(dev, source)
                    last_scan = time.time()

                    if dev is None:
                        break  # re-enter outer loop to find device again

                time.sleep(POLL_INTERVAL)

        except usb.core.USBError as e:
            log(f"USB error: {e} — reconnecting in 5s…")
        except Exception as e:
            log(f"Unexpected error: {e}")
            traceback.print_exc(file=sys.stderr)
        finally:
            if dev is not None:
                try:
                    usb.util.dispose_resources(dev)
                except Exception:
                    pass

        time.sleep(5)


if __name__ == "__main__":
    main()
