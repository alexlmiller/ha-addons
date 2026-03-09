# ScanSnap iX500

Press the physical scan button to scan a stack of documents from the ADF, run OCR, and upload a searchable PDF to a configured storage backend — with a Home Assistant notification on completion.

## Requirements

- Fujitsu ScanSnap iX500 connected via USB
- Home Assistant OS (amd64)
- A supported storage backend:
  - Nextcloud File Drop, or
  - Seafile upload link

## Storage Setup

### Nextcloud (one-time)

This add-on uses Nextcloud's **File Drop** feature — an upload-only share that gives the add-on no access to read or delete your existing files.

1. In Nextcloud, create or choose a folder (e.g. `Scans`)
2. Share it → enable **File Drop** mode → optionally set a password
3. Copy the share token from the link (e.g. `abc123` from `https://cloud.example.com/s/abc123`)

### Seafile (one-time)

1. Create a Seafile upload link for the target folder
2. Copy the full upload link URL (e.g. `https://seafile.example.com/u/d/abcdef123456/`)
3. Set `storage_backend: seafile` and paste the link into `seafile_upload_url`

## Configuration

### Storage Settings

| Option | Default | Description |
|--------|---------|-------------|
| `storage_backend` | `nextcloud` | Destination backend. `nextcloud` and `seafile` are implemented. |
| `nextcloud_url` | — | Your Nextcloud base URL (e.g. `https://cloud.example.com`) |
| `nextcloud_share_token` | — | The share token from your File Drop link |
| `nextcloud_share_password` | _(empty)_ | Password for the share, if set |
| `seafile_upload_url` | _(empty)_ | Full Seafile upload link URL (e.g. `https://seafile.example.com/u/d/abcdef123456/`) |

### Scan Settings

| Option | Default | Description |
|--------|---------|-------------|
| `scan_profile` | `stable_300` | Low-level USB scan profile. `stable_300` is the normal default and `stable_600` is a fallback. |
| `ocr_language` | `eng` | Tesseract language code(s) — e.g. `eng`, `fra`, `eng+fra` |
| `scan_duplex` | `true` | Scan both sides of each page (ADF Duplex). Blank reverses are removed automatically. |
| `scan_color` | `Color` | Color mode: `Color`, `Gray`, or `Lineart` |

Current limitation: the single-owner USB scanner path is stable, but the low-level duplex/color controls are still not fully mapped to the Home Assistant options.

## How It Works

1. **Button detection** — A dedicated Go daemon owns the iX500 over raw USB and polls its hardware status directly. This avoids the fragile USB handoff between button polling and SANE.
2. **Scan** — The same USB owner drives the scanner end-to-end and writes raw page JPEGs into a temporary working directory.
3. **Blank page removal** — Pages where >97% of pixels are near-white are discarded, eliminating blank duplex reverses from single-sided originals.
4. **PDF assembly** — `img2pdf` combines the remaining pages into a lossless PDF.
5. **OCR** — `ocrmypdf` produces a searchable PDF/A with auto-rotation and deskew.
6. **Smart filename** — The OCR text is analysed locally (no external API) to extract a document date, organisation name, and document type, producing a filename like `2026-03-07 - Chase Bank Statement.pdf`.
7. **Destination dispatch** — The finished PDF is handed to the configured storage backend. `nextcloud` and `seafile` are implemented.
8. **Notification** — A Home Assistant persistent notification confirms the upload or reports any error.

## Scanner On/Off Behaviour

The daemon handles the scanner being powered on and off at any time. When the scanner is off it retries every 5 seconds; when it comes back it resumes polling immediately.

## Troubleshooting

**Add-on can't find the scanner**
- Make sure the scanner is powered on — the iX500 disappears from USB entirely when in sleep mode.
- Check the add-on logs; the daemon lists all visible USB devices when the scanner isn't found.

**Upload fails (HTTP 4xx)**
- Verify `nextcloud_url` does not have a trailing slash.
- Confirm the share token is from a File Drop share (not a regular share).
- If the share has a password, make sure `nextcloud_share_password` is set.
- For Seafile, confirm `seafile_upload_url` is the full public upload-link URL and still opens in a browser.

**No HA notification**
- Ensure `homeassistant_api` is enabled (it is by default in this add-on).
- Check that the Supervisor token is being passed correctly — visible in the add-on logs on startup.
