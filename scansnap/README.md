# ScanSnap iX500

Press the physical scan button (or click **Scan Now** in the HA sidebar) to scan a stack of documents from the ADF, run OCR, and upload a searchable PDF to a Nextcloud File Drop folder — with a Home Assistant notification on completion.

## Requirements

- Fujitsu ScanSnap iX500 connected via USB
- Home Assistant OS (amd64)
- A Nextcloud instance with a File Drop share

## Nextcloud Setup (one-time)

This add-on uses Nextcloud's **File Drop** feature — an upload-only share that gives the add-on no access to read or delete your existing files.

1. In Nextcloud, create or choose a folder (e.g. `Scans`)
2. Share it → enable **File Drop** mode → optionally set a password
3. Copy the share token from the link (e.g. `abc123` from `https://cloud.example.com/s/abc123`)

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `nextcloud_url` | — | Your Nextcloud base URL (e.g. `https://cloud.example.com`) |
| `nextcloud_share_token` | — | The share token from your File Drop link |
| `nextcloud_share_password` | _(empty)_ | Password for the share, if set |
| `scan_resolution` | `300` | Scan resolution in DPI (150 / 300 / 600) |
| `ocr_language` | `eng` | Tesseract language code(s) — e.g. `eng`, `fra`, `eng+fra` |
| `scan_duplex` | `true` | Scan both sides of each page (ADF Duplex). Blank reverses are removed automatically. |
| `scan_color` | `Color` | Color mode: `Color`, `Gray`, or `Lineart` |

## How It Works

1. **Button detection** — A Python daemon polls the scanner via USB bulk transfer (GET_HW_STATUS, SCSI opcode 0xc2) every 500ms. This is necessary because the iX500 button is not exposed as a SANE option.
2. **Scan** — `scanimage` pulls all pages from the ADF in the configured mode and resolution, producing TIFF files.
3. **Blank page removal** — Pages where >97% of pixels are near-white are discarded, eliminating blank duplex reverses from single-sided originals.
4. **PDF assembly** — `img2pdf` combines the remaining TIFFs into a lossless PDF.
5. **OCR** — `ocrmypdf` produces a searchable PDF/A with auto-rotation and deskew.
6. **Smart filename** — The OCR text is analysed locally (no external API) to extract a document date, organisation name, and document type, producing a filename like `2026-03-07 - Chase Bank Statement.pdf`.
7. **Upload** — The PDF is uploaded to the Nextcloud File Drop folder via WebDAV.
8. **Notification** — A Home Assistant persistent notification confirms the upload or reports any error.

## Scanner On/Off Behaviour

The daemon handles the scanner being powered on and off at any time. When the scanner is off it retries every 5 seconds; when it comes back it resumes polling immediately.

## Troubleshooting

**Add-on can't find the scanner**
- Make sure the scanner is powered on — the iX500 disappears from USB entirely when in sleep mode.
- Check the add-on logs; the daemon lists all visible USB devices when the scanner isn't found.

**`sane_start: Error during device I/O`**
- Transient USB state issue after button detection. The add-on resets the USB device before handing off to SANE; if it recurs, restart the add-on.

**Upload fails (HTTP 4xx)**
- Verify `nextcloud_url` does not have a trailing slash.
- Confirm the share token is from a File Drop share (not a regular share).
- If the share has a password, make sure `nextcloud_share_password` is set.

**No HA notification**
- Ensure `homeassistant_api` is enabled (it is by default in this add-on).
- Check that the Supervisor token is being passed correctly — visible in the add-on logs on startup.
