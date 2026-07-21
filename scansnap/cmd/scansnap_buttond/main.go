package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"scansnap_buttond/internal/fss500"
	"scansnap_buttond/internal/scansnapusb"
	"scansnap_buttond/internal/usb"
)

const (
	processScript = "/etc/scanbd/scripts/scan.sh"
	pollInterval  = 500 * time.Millisecond
	scanDebounce  = 5 * time.Second
)

func main() {
	log.Printf("Starting ScanSnap iX500 single-owner daemon")
	log.Printf("Button press starts scan -> OCR -> upload pipeline")
	log.Printf("USB-native low-level scan profile: %s", activeScanProfile())

	var (
		lastScan       time.Time
		scanButtonHeld bool
	)
	for {
		dev, err := usb.FindDevice()
		if err != nil {
			log.Printf("Scanner not found: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		log.Printf("USB device opened - waiting for button press")
		loopErr := waitLoop(dev, &lastScan, &scanButtonHeld)
		deviceReset := false
		if loopErr != nil {
			log.Printf("Scanner loop ended: %v", loopErr)
			if requiresUSBRecovery(loopErr) {
				if err := dev.Recover(); err != nil {
					log.Printf("Scanner USB endpoint recovery failed: %v", err)
				} else {
					log.Printf("Scanner USB endpoints recovered after loop error")
				}
				if err := dev.Reset(); err != nil {
					log.Printf("Scanner USB function reset failed: %v", err)
				} else {
					deviceReset = true
					log.Printf("Scanner USB function reset after loop error")
				}
			}
		}
		var closeErr error
		if deviceReset {
			closeErr = dev.CloseAfterReset()
		} else {
			closeErr = dev.Close()
		}
		if closeErr != nil {
			log.Printf("Device close warning: %v", closeErr)
		}
		if transientUSBError(loopErr) {
			time.Sleep(5 * time.Second)
		} else {
			time.Sleep(2 * time.Second)
		}
	}
}

func activeScanProfile() string {
	profile := normalizeScanProfile(os.Getenv("SCAN_PROFILE"))
	if profile == "" {
		return string(fss500.ProfileStable300)
	}
	return profile
}

func activeScanProfileFile() string {
	if path := strings.TrimSpace(os.Getenv("ACTIVE_SCAN_PROFILE_FILE")); path != "" {
		return path
	}
	return "/data/active_scan_profile"
}

func normalizeScanProfile(raw string) string {
	raw = strings.TrimSpace(strings.ToLower(strings.ReplaceAll(raw, "-", "_")))
	switch raw {
	case string(fss500.ProfileStable300), string(fss500.ProfileStable600):
		return raw
	default:
		return ""
	}
}

func loadSavedScanProfile() string {
	data, err := os.ReadFile(activeScanProfileFile())
	if err != nil {
		return ""
	}
	profile := normalizeScanProfile(string(data))
	if profile != "" {
		log.Printf("Active scan profile override: %s", profile)
	}
	return profile
}

func loadHAScanProfile() string {
	entityID := strings.TrimSpace(os.Getenv("HA_SCAN_PROFILE_ENTITY"))
	token := strings.TrimSpace(os.Getenv("SUPERVISOR_TOKEN"))
	if entityID == "" || token == "" {
		return ""
	}

	req, err := http.NewRequest(http.MethodGet, "http://supervisor/core/api/states/"+url.PathEscape(entityID), nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+token)

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ""
	}

	var state struct {
		State string `json:"state"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&state); err != nil {
		return ""
	}

	profile := normalizeScanProfile(state.State)
	if profile != "" {
		log.Printf("HA scan profile override: %s (from %s)", profile, entityID)
	}
	return profile
}

func resolvedScanProfile() string {
	profile := activeScanProfile()
	if saved := loadSavedScanProfile(); saved != "" {
		profile = saved
	}
	if helper := loadHAScanProfile(); helper != "" {
		profile = helper
	}
	return profile
}

func waitLoop(dev *usb.Device, lastScan *time.Time, scanButtonHeld *bool) error {
	var lastStatus string
	for {
		status, err := fss500.GetHardwareStatus(dev)
		if err != nil {
			return fmt.Errorf("get hardware status: %w", err)
		}

		paperLoaded := !status.Hopper
		statusLine := fmt.Sprintf("paper_loaded=%t scan_button=%t", paperLoaded, status.ScanSw)
		if statusLine != lastStatus {
			log.Printf("HW status changed: %s", statusLine)
			lastStatus = statusLine
		}

		if !status.ScanSw {
			*scanButtonHeld = false
		}

		if status.ScanSw && !*scanButtonHeld && time.Since(*lastScan) > scanDebounce {
			*scanButtonHeld = true
			*lastScan = time.Now()
			if err := performScan(dev); err != nil {
				return fmt.Errorf("scan: %w", err)
			} else {
				log.Printf("Scan completed")
			}
		}

		if paperLoaded {
			time.Sleep(50 * time.Millisecond)
		} else {
			time.Sleep(pollInterval)
		}
	}
}

func transientUSBError(err error) bool {
	return errors.Is(err, syscall.EPROTO) ||
		errors.Is(err, syscall.EOVERFLOW) ||
		errors.Is(err, syscall.ETIMEDOUT) ||
		errors.Is(err, syscall.EAGAIN) ||
		errors.Is(err, syscall.ENOMEM)
}

func requiresUSBRecovery(err error) bool {
	return transientUSBError(err) || errors.Is(err, fss500.ErrTemporaryNoData)
}

func performScan(dev *usb.Device) error {
	workdir, err := os.MkdirTemp("/tmp", "scan-")
	if err != nil {
		return err
	}

	profile := resolvedScanProfile()
	if err := os.Setenv("SCAN_PROFILE", profile); err != nil {
		return fmt.Errorf("set scan profile env: %w", err)
	}

	log.Printf("Scanning to %s using profile %s", workdir, profile)
	if err := scansnapusb.ScanToDir(dev, workdir); err != nil {
		_ = os.RemoveAll(workdir)
		return err
	}

	cmd := exec.Command(processScript)
	cmd.Env = append(os.Environ(), "SCANNED_DIR="+workdir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	log.Printf("Invoking processing pipeline")
	return cmd.Run()
}
