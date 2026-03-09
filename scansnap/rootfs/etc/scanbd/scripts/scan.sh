#!/bin/bash
# Full scan pipeline: scanned pages → blank removal → PDF → OCR → filename → destination upload → HA notification
set -euo pipefail

echo "[scan.sh] Processing scanned pages from: ${SCANNED_DIR:-unknown}" >&2

# Load configuration written by run.sh (bashio context not available here)
source /etc/scanbd/addon.conf || { echo "[scan.sh] ERROR: failed to source /etc/scanbd/addon.conf" >&2; exit 1; }

WORKDIR="${SCANNED_DIR:-}"
if [ -z "${WORKDIR}" ] || [ ! -d "${WORKDIR}" ]; then
    echo "[scan.sh] ERROR: SCANNED_DIR is missing or invalid" >&2
    exit 1
fi
trap 'rm -rf "$WORKDIR"' EXIT
shopt -s nullglob

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

upload_pdf() {
    local encoded_filename
    local http_code
    local webdav_url

    nextcloud_put() {
        local url="$1"
        local auth_mode="$2"

        case "${auth_mode}" in
            modern)
                if [ -n "${NEXTCLOUD_SHARE_PASSWORD:-}" ]; then
                    curl -s -o /dev/null -w "%{http_code}" \
                        -X PUT \
                        -u "anonymous:${NEXTCLOUD_SHARE_PASSWORD}" \
                        -H "Content-Type: application/pdf" \
                        --data-binary @"${OCR_PDF}" \
                        "${url}"
                else
                    curl -s -o /dev/null -w "%{http_code}" \
                        -X PUT \
                        -H "Content-Type: application/pdf" \
                        --data-binary @"${OCR_PDF}" \
                        "${url}"
                fi
                ;;
            legacy)
                curl -s -o /dev/null -w "%{http_code}" \
                    -X PUT \
                    -u "${NEXTCLOUD_SHARE_TOKEN}:${NEXTCLOUD_SHARE_PASSWORD}" \
                    -H "Content-Type: application/pdf" \
                    --data-binary @"${OCR_PDF}" \
                    "${url}"
                ;;
            *)
                return 99
                ;;
        esac
    }

    case "${STORAGE_BACKEND:-nextcloud}" in
        nextcloud)
            encoded_filename=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${FILENAME}")
            webdav_url="${NEXTCLOUD_URL}/public.php/dav/files/${NEXTCLOUD_SHARE_TOKEN}/${encoded_filename}"
            log "Uploading to Nextcloud (modern public DAV): ${webdav_url}" >&2
            http_code=$(nextcloud_put "${webdav_url}" modern)

            if [ "${http_code}" = "404" ] || [ "${http_code}" = "405" ] || [ "${http_code}" = "501" ]; then
                webdav_url="${NEXTCLOUD_URL}/public.php/webdav/${encoded_filename}"
                log "Falling back to legacy public WebDAV endpoint: ${webdav_url}" >&2
                http_code=$(nextcloud_put "${webdav_url}" legacy)
            fi

            if [ "${http_code}" = "409" ]; then
                FILENAME="${FILENAME%.pdf} ($(date +%H%M%S)).pdf"
                encoded_filename=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${FILENAME}")
                webdav_url="${NEXTCLOUD_URL}/public.php/dav/files/${NEXTCLOUD_SHARE_TOKEN}/${encoded_filename}"
                log "Retrying Nextcloud upload with unique filename: ${webdav_url}" >&2
                http_code=$(nextcloud_put "${webdav_url}" modern)
                if [ "${http_code}" = "404" ] || [ "${http_code}" = "405" ] || [ "${http_code}" = "501" ]; then
                    webdav_url="${NEXTCLOUD_URL}/public.php/webdav/${encoded_filename}"
                    log "Retrying with legacy public WebDAV endpoint: ${webdav_url}" >&2
                    http_code=$(nextcloud_put "${webdav_url}" legacy)
                fi
            fi
            printf '%s' "${http_code}"
            ;;
        *)
            fail "Unsupported storage backend: ${STORAGE_BACKEND}"
            ;;
    esac
}

# ── Step 1: Validate scanned page output ─────────────────────────────────────
PAGE_FILES=("${WORKDIR}"/page_*.jpg "${WORKDIR}"/page_*.jpeg "${WORKDIR}"/page_*.tiff)
PAGE_COUNT=${#PAGE_FILES[@]}
if [ "${PAGE_COUNT}" -eq 0 ]; then
    fail "No pages were produced by the scanner"
fi
log "Found ${PAGE_COUNT} raw page(s)"

# ── Step 2: Normalize page orientation ───────────────────────────────────────
log "Rotating pages to upright orientation..."
/usr/local/bin/rotate_pages.py "${PAGE_FILES[@]}"

# ── Step 3: Remove blank pages ───────────────────────────────────────────────
# Pillow-based: deletes image files where >97% of pixels are near-white.
# Strips blank duplex reverses from single-sided originals.
log "Checking for blank pages..."
/usr/local/bin/remove_blank_pages.py "${PAGE_FILES[@]}"

PAGE_FILES=("${WORKDIR}"/page_*.jpg "${WORKDIR}"/page_*.jpeg "${WORKDIR}"/page_*.tiff)
KEPT_COUNT=${#PAGE_FILES[@]}
if [ "${KEPT_COUNT}" -eq 0 ]; then
    fail "All pages were blank — nothing to scan"
fi
log "Kept ${KEPT_COUNT} page(s) after blank removal"

# ── Step 4: Assemble lossless PDF ────────────────────────────────────────────
RAW_PDF="${WORKDIR}/raw.pdf"
log "Assembling PDF with img2pdf..."
IFS=$'\n' PAGE_FILES=($(printf '%s\n' "${PAGE_FILES[@]}" | sort))
img2pdf --output "${RAW_PDF}" "${PAGE_FILES[@]}" \
    || fail "img2pdf failed"

# ── Step 5: OCR ──────────────────────────────────────────────────────────────
OCR_PDF="${WORKDIR}/ocr.pdf"
log "Running OCR (language: ${OCR_LANGUAGE:-eng})..."

ocrmypdf \
    --rotate-pages \
    --deskew \
    --output-type pdfa \
    -l "${OCR_LANGUAGE:-eng}" \
    "${RAW_PDF}" "${OCR_PDF}" \
    || fail "ocrmypdf failed"

# ── Step 6: Generate smart filename ──────────────────────────────────────────
log "Extracting text for filename..."

# Extract first 3000 chars from OCR'd PDF for analysis
TEXT=$(pdftotext "${OCR_PDF}" - 2>/dev/null | head -c 3000 || true)
FILENAME=$(echo "${TEXT}" | /usr/local/bin/name_from_ocr.py)
log "Filename: ${FILENAME}"

# ── Step 7: Upload to configured destination ─────────────────────────────────
HTTP_CODE=$(upload_pdf)

if [ "${HTTP_CODE}" != "201" ] && [ "${HTTP_CODE}" != "204" ]; then
    fail "Upload failed (HTTP ${HTTP_CODE}) — check destination configuration"
fi

# ── Step 8: Success notification ─────────────────────────────────────────────
log "Upload successful (HTTP ${HTTP_CODE})"
notify_ha "Scan Complete" "Uploaded: ${FILENAME}"
log "Done."
