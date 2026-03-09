#!/bin/bash
# Full scan pipeline: button press → TIFF → blank removal → PDF → OCR → filename → Nextcloud upload → HA notification
# Called by scanbd with $SCANBD_DEVICE set to the SANE device string.
set -euo pipefail

# Log immediately to confirm scanbd is calling this script
echo "[scan.sh] TRIGGERED by scanbd — device: ${SCANBD_DEVICE:-unknown} action: ${SCANBD_ACTION:-unknown}" >&2

# Load configuration written by run.sh (bashio context not available here)
source /etc/scanbd/addon.conf || { echo "[scan.sh] ERROR: failed to source /etc/scanbd/addon.conf" >&2; exit 1; }

WORKDIR=$(mktemp -d /tmp/scan-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

log() {
    echo "[scan.sh $(date +%H:%M:%S)] $*"
}

notify_ha() {
    local title="$1"
    local message="$2"
    curl -s -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"${title}\", \"message\": \"${message}\"}" \
        "http://supervisor/core/api/services/persistent_notification/create" \
        || log "WARNING: HA notification failed (pipeline continues)"
}

fail() {
    log "ERROR: $1"
    notify_ha "ScanSnap Error" "$1"
    exit 1
}

# ── Step 1: Scan ─────────────────────────────────────────────────────────────
# button_daemon releases USB before calling this script, so the device is
# available. SCANBD_DEVICE is written to addon.conf by run.sh.
SCAN_SOURCE="ADF Duplex"
if [ "${SCAN_DUPLEX:-true}" = "false" ]; then
    SCAN_SOURCE="ADF Front"
fi

log "Scanning with device: ${SCANBD_DEVICE:-fujitsu} | source: ${SCAN_SOURCE} | mode: ${SCAN_COLOR:-Color} | ${SCAN_RESOLUTION:-300} dpi..."

scanimage \
    -d "${SCANBD_DEVICE}" \
    --source "${SCAN_SOURCE}" \
    --mode "${SCAN_COLOR:-Color}" \
    --resolution "${SCAN_RESOLUTION:-300}" \
    --format=tiff \
    --batch="${WORKDIR}/page_%04d.tiff" \
    --batch-start=1 \
    || true  # Non-zero exit when ADF empties is expected behavior

PAGE_COUNT=$(ls "${WORKDIR}"/page_*.tiff 2>/dev/null | wc -l)
if [ "${PAGE_COUNT}" -eq 0 ]; then
    fail "No pages scanned — is the ADF loaded?"
fi
log "Scanned ${PAGE_COUNT} raw page(s)"

# ── Step 2: Remove blank pages ───────────────────────────────────────────────
# Pillow-based: deletes TIFFs where >97% of pixels are near-white.
# Strips blank duplex reverses from single-sided originals.
log "Checking for blank pages..."
/usr/local/bin/remove_blank_pages.py "${WORKDIR}"/page_*.tiff

KEPT_COUNT=$(ls "${WORKDIR}"/page_*.tiff 2>/dev/null | wc -l)
if [ "${KEPT_COUNT}" -eq 0 ]; then
    fail "All pages were blank — nothing to scan"
fi
log "Kept ${KEPT_COUNT} page(s) after blank removal"

# ── Step 3: Assemble lossless PDF ────────────────────────────────────────────
RAW_PDF="${WORKDIR}/raw.pdf"
log "Assembling PDF with img2pdf..."

# Sort TIFFs to maintain page order
TIFF_FILES=$(ls "${WORKDIR}"/page_*.tiff | sort)
# shellcheck disable=SC2086
img2pdf --output "${RAW_PDF}" ${TIFF_FILES} \
    || fail "img2pdf failed"

# ── Step 4: OCR ──────────────────────────────────────────────────────────────
OCR_PDF="${WORKDIR}/ocr.pdf"
log "Running OCR (language: ${OCR_LANGUAGE:-eng})..."

ocrmypdf \
    --rotate-pages \
    --deskew \
    --output-type pdfa \
    -l "${OCR_LANGUAGE:-eng}" \
    "${RAW_PDF}" "${OCR_PDF}" \
    || fail "ocrmypdf failed"

# ── Step 5: Generate smart filename ──────────────────────────────────────────
log "Extracting text for filename..."

# Extract first 3000 chars from OCR'd PDF for analysis
TEXT=$(pdftotext "${OCR_PDF}" - 2>/dev/null | head -c 3000 || true)
FILENAME=$(echo "${TEXT}" | /usr/local/bin/name_from_ocr.py)
log "Filename: ${FILENAME}"

# ── Step 6: Upload to Nextcloud File Drop ────────────────────────────────────
# File Drop WebDAV endpoint uses share token as both username and path auth.
# Auth: Basic auth with "{share_token}:{share_password}" (password can be empty)
WEBDAV_URL="${NEXTCLOUD_URL}/public.php/webdav/${FILENAME}"
log "Uploading to: ${WEBDAV_URL}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -u "${NEXTCLOUD_SHARE_TOKEN}:${NEXTCLOUD_SHARE_PASSWORD}" \
    -H "Content-Type: application/pdf" \
    --data-binary @"${OCR_PDF}" \
    "${WEBDAV_URL}")

if [ "${HTTP_CODE}" != "201" ] && [ "${HTTP_CODE}" != "204" ]; then
    fail "Upload failed (HTTP ${HTTP_CODE}) — check share token and Nextcloud URL"
fi

# ── Step 7: Success notification ─────────────────────────────────────────────
log "Upload successful (HTTP ${HTTP_CODE})"
notify_ha "Scan Complete" "Uploaded: ${FILENAME}"
log "Done."
