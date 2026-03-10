#!/bin/bash
# Full scan pipeline: scanned pages → blank removal → PDF → OCR → filename → destination upload → HA notification
set -euo pipefail

echo "[scan.sh] Processing scanned pages from: ${SCANNED_DIR:-unknown}" >&2

# Load configuration written by run.sh (bashio context not available here)
ADDON_CONF_PATH="${ADDON_CONF_PATH:-/etc/scanbd/addon.conf}"
source "${ADDON_CONF_PATH}" || { echo "[scan.sh] ERROR: failed to source ${ADDON_CONF_PATH}" >&2; exit 1; }

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

ocr_args() {
    printf '%s\n' \
        --rotate-pages \
        --deskew \
        --clean-final \
        -O 2 \
        --output-type pdfa \
        -l "${OCR_LANGUAGE:-eng}"
}

fail() {
    log "ERROR: $1"
    exit 1
}

archive_raw_scan() {
    local archive_dir
    local archive_name
    local archive_path

    if [ "${ARCHIVE_RAW_SCANS:-false}" != "true" ]; then
        return 0
    fi

    archive_dir="${RAW_SCAN_ARCHIVE_DIR:-/share/scansnap-raw}"
    archive_name="$(date +%Y%m%d-%H%M%S)-$(basename "${WORKDIR}")"
    archive_path="${archive_dir}/${archive_name}"

    mkdir -p "${archive_dir}" || fail "Could not create raw scan archive dir: ${archive_dir}"
    cp -R "${WORKDIR}" "${archive_path}" || fail "Could not archive raw scan to ${archive_path}"
    log "Archived raw scan pages to: ${archive_path}"
}

upload_pdf() {
    local done_code
    local encoded_filename
    local http_code
    local file_path
    local path
    local public_html
    local seafile_base_url
    local seafile_token
    local upload_url
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
        seafile)
            seafile_base_url=$(python3 -c 'import sys, urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(f"{u.scheme}://{u.netloc}")' "${SEAFILE_UPLOAD_URL}")
            seafile_token=$(python3 -c 'import re, sys, urllib.parse; path=urllib.parse.urlparse(sys.argv[1]).path; m=re.search(r"/u/d/([^/]+)/?$", path); print(m.group(1) if m else "")' "${SEAFILE_UPLOAD_URL}")

            if [ -z "${seafile_token}" ]; then
                fail "Could not extract Seafile upload token from seafile_upload_url"
            fi

            public_html=$(curl -fsSL "${SEAFILE_UPLOAD_URL}") \
                || fail "Failed to fetch Seafile upload page"
            path=$(printf '%s' "${public_html}" | python3 -c 'import re, sys; html=sys.stdin.read(); m=re.search(r"path:\s*\"([^\"]+)\"", html); print(m.group(1) if m else "")')

            if [ -z "${path}" ]; then
                fail "Could not extract Seafile upload path from upload page"
            fi

            upload_url=$(curl -fsSL "${seafile_base_url}/api/v2.1/upload-links/${seafile_token}/upload/" | python3 -c 'import json, sys; data=json.load(sys.stdin); print(data.get("upload_link", ""))') \
                || fail "Failed to fetch Seafile upload URL"

            if [ -z "${upload_url}" ]; then
                fail "Seafile upload API returned an empty upload URL"
            fi

            file_path=$(python3 -c 'import posixpath, sys; print(posixpath.join(sys.argv[1], sys.argv[2]))' "${path}" "${FILENAME}")
            log "Uploading to Seafile: ${upload_url} (parent_dir=${path})" >&2
            http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                -X POST \
                -F "file=@${OCR_PDF};type=application/pdf;filename=${FILENAME}" \
                -F "parent_dir=${path}" \
                "${upload_url}?ret-json=1")

            if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
                done_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -X POST \
                    -F "file_path=${file_path}" \
                    "${seafile_base_url}/api/v2.1/share-links/${seafile_token}/upload/done/")
                if [ "${done_code}" != "200" ] && [ "${done_code}" != "201" ] && [ "${done_code}" != "204" ]; then
                    fail "Seafile upload finalize failed (HTTP ${done_code})"
                fi
            fi

            printf '%s' "${http_code}"
            ;;
        local)
            mkdir -p "${LOCAL_OUTPUT_DIR:?LOCAL_OUTPUT_DIR is required for local backend}" \
                || fail "Could not create local output dir"
            cp "${OCR_PDF}" "${LOCAL_OUTPUT_DIR}/${FILENAME}" \
                || fail "Could not write local output PDF"
            printf '%s' "201"
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
archive_raw_scan

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

# ── Step 4: Apply processing profile ─────────────────────────────────────────
PROCESSING_PROFILE="${PROCESSING_PROFILE:-baseline}"
log "Processing profile: ${PROCESSING_PROFILE}"
case "${PROCESSING_PROFILE}" in
    baseline)
        log "Using baseline page processing (no extra image cleanup)"
        ;;
    gray_light|gray_soft|gray_bg_flatten)
        log "Cleaning page backgrounds with profile: ${PROCESSING_PROFILE}"
        /usr/local/bin/clean_document_pages.py "${PROCESSING_PROFILE}" "${PAGE_FILES[@]}" \
            || fail "document page cleanup failed"
        ;;
    *)
        fail "Unsupported processing profile: ${PROCESSING_PROFILE}"
        ;;
esac

# ── Step 5: Assemble lossless PDF ────────────────────────────────────────────
RAW_PDF="${WORKDIR}/raw.pdf"
log "Assembling PDF with img2pdf..."
IFS=$'\n' PAGE_FILES=($(printf '%s\n' "${PAGE_FILES[@]}" | sort))
img2pdf --output "${RAW_PDF}" "${PAGE_FILES[@]}" \
    || fail "img2pdf failed"

# ── Step 6: OCR ──────────────────────────────────────────────────────────────
OCR_PDF="${WORKDIR}/ocr.pdf"
log "Running OCR (language: ${OCR_LANGUAGE:-eng})..."

mapfile -t OCR_ARGS < <(ocr_args)
ocrmypdf \
    "${OCR_ARGS[@]}" \
    "${RAW_PDF}" "${OCR_PDF}" \
    || fail "ocrmypdf failed"

# ── Step 7: Generate smart filename ──────────────────────────────────────────
log "Extracting text for filename..."

# Extract first 3000 chars from OCR'd PDF for analysis
TEXT=$(pdftotext "${OCR_PDF}" - 2>/dev/null | head -c 3000 || true)
FILENAME=$(echo "${TEXT}" | /usr/local/bin/name_from_ocr.py)
log "Filename: ${FILENAME}"

# ── Step 8: Upload to configured destination ─────────────────────────────────
HTTP_CODE=$(upload_pdf)

if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "201" ] && [ "${HTTP_CODE}" != "204" ]; then
    fail "Upload failed (HTTP ${HTTP_CODE}) — check destination configuration"
fi

# ── Step 9: Success ───────────────────────────────────────────────────────────
log "Upload successful (HTTP ${HTTP_CODE})"
log "Done."
