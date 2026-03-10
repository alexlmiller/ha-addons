# ScanSnap iX500

Press the physical scan button to scan a stack of documents from the ADF, run OCR, and upload a searchable PDF to one or more configured destinations.

## Requirements

- Fujitsu ScanSnap iX500 connected via USB
- Home Assistant OS (amd64)
- At least one enabled destination:
  - Nextcloud File Drop
  - Seafile upload link
  - Paperless-ngx

## Storage Setup

### Nextcloud (one-time)

This add-on uses Nextcloud's **File Drop** feature — an upload-only share that gives the add-on no access to read or delete your existing files.

1. In Nextcloud, create or choose a folder (e.g. `Scans`)
2. Share it → enable **File Drop** mode → optionally set a password
3. Copy the share token from the link (e.g. `abc123` from `https://cloud.example.com/s/abc123`)
4. Leave `upload_nextcloud: true` enabled

### Seafile (one-time)

1. Create a Seafile upload link for the target folder
2. Copy the full upload link URL (e.g. `https://seafile.example.com/u/d/abcdef123456/`)
3. Set `upload_seafile: true` and paste the link into `seafile_upload_url`

### Paperless-ngx (one-time)

1. Create an API token in Paperless-ngx
2. Copy your Paperless base URL (e.g. `https://paperless.example.com`)
3. Set `upload_paperless: true`
4. Paste the base URL into `paperless_url`
5. Paste the token into `paperless_token`

## Configuration

### Storage Settings

| Option | Default | Description |
|--------|---------|-------------|
| `upload_nextcloud` | `true` | Upload to Nextcloud File Drop. |
| `upload_seafile` | `false` | Upload to Seafile using the public upload link. |
| `upload_paperless` | `false` | Upload to Paperless-ngx using its API. |
| `nextcloud_url` | — | Your Nextcloud base URL (e.g. `https://cloud.example.com`) |
| `nextcloud_share_token` | — | The share token from your File Drop link |
| `nextcloud_share_password` | _(empty)_ | Password for the share, if set |
| `seafile_upload_url` | _(empty)_ | Full Seafile upload link URL (e.g. `https://seafile.example.com/u/d/abcdef123456/`) |
| `paperless_url` | _(empty)_ | Paperless-ngx base URL (e.g. `https://paperless.example.com`) |
| `paperless_token` | _(empty)_ | Paperless-ngx API token |

### Scan Settings

| Option | Default | Description |
|--------|---------|-------------|
| `scan_profile` | `stable_300` | Low-level USB scan profile. `stable_300` is the normal default and `stable_600` is a fallback. |
| `processing_profile` | `document_clean` | Post-scan page rendering profile. `document_clean` is the default for readable, analysis-friendly document output. `document_texture` preserves more of the original paper character. |
| `archive_raw_scans` | `false` | If enabled, saves each raw `page_XXXX.jpg` scan set before any rotation, blank-page removal, or OCR. |
| `raw_scan_archive_dir` | `/share/scansnap-raw` | Where raw scan directories are archived when `archive_raw_scans` is enabled. This path is inside Home Assistant's shared folder. |
| `ocr_language` | `eng` | Tesseract language code(s) — e.g. `eng`, `fra`, `eng+fra` |
| `scan_duplex` | `true` | Scan both sides of each page (ADF Duplex). Blank reverses are removed automatically. |
| `scan_color` | `Color` | Color mode: `Color`, `Gray`, or `Lineart` |

Current limitation: the single-owner USB scanner path is stable, but the low-level duplex/color controls are still not fully mapped to the Home Assistant options.
`scan_profile` is the scanner-mode control that matters today; `scan_duplex` and `scan_color` remain reserved until the USB-native path is mapped more fully.
`processing_profile` selects between the two settled document-rendering modes; deeper local experimentation is documented in [SCAN_FORMATS.md](/Users/alex/code/ha-addon-scansnap/scansnap/SCAN_FORMATS.md).

## How It Works

1. **Button detection** — A dedicated Go daemon owns the iX500 over raw USB and polls its hardware status directly. This avoids the fragile USB handoff between button polling and SANE.
2. **Scan** — The same USB owner drives the scanner end-to-end and writes raw page JPEGs into a temporary working directory.
3. **Blank page removal** — Heuristic image analysis removes blank duplex reverses from single-sided originals while keeping real printed pages.
4. **PDF assembly** — `img2pdf` combines the remaining pages into a lossless PDF.
5. **OCR** — `ocrmypdf` produces a searchable PDF/A with auto-rotation and deskew.
6. **Smart filename** — The OCR text is analysed locally (no external API) to extract a document date, organisation name, and document type, producing a filename like `2026-03-07 - Chase Bank Statement.pdf`.
7. **Destination dispatch** — The finished PDF is handed to every enabled destination. Nextcloud, Seafile, and Paperless-ngx can be used together.

## Replaying Processing Profiles Locally

To avoid rescanning the same document while tuning post-processing:

1. Enable `archive_raw_scans`
2. Scan the document once
3. Use the archived raw scan directory with the local replay helper:

```bash
./scripts/replay_raw_scan.sh \
  /path/to/raw-scan-dir \
  /tmp/scansnap-replay \
  document_clean document_texture baseline
```

This re-runs the processing pipeline against a copy of the raw `page_XXXX.jpg` files for each requested `processing_profile` and writes the resulting PDFs to per-profile directories under the chosen output directory. The replay path uses a local-only backend, so it does not upload anything. Additional experimental/internal profiles are described in [SCAN_FORMATS.md](/Users/alex/code/ha-addon-scansnap/scansnap/SCAN_FORMATS.md).

The default archive directory `/share/scansnap-raw` corresponds to Home Assistant's shared folder, so archived raw scans should be accessible from the host after a scan completes.

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
- For Paperless-ngx, confirm `paperless_url` is the base site URL and `paperless_token` is a valid API token.
- If multiple destinations are enabled, one failing destination makes the overall scan fail after processing completes.
