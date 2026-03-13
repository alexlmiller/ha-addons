#!/usr/bin/with-contenv bashio

# Read configuration options
UPLOAD_NEXTCLOUD=$(bashio::config 'upload_nextcloud')
UPLOAD_SEAFILE=$(bashio::config 'upload_seafile')
UPLOAD_PAPERLESS=$(bashio::config 'upload_paperless')
NEXTCLOUD_URL=$(bashio::config 'nextcloud_url')
NEXTCLOUD_SHARE_TOKEN=$(bashio::config 'nextcloud_share_token')
SEAFILE_UPLOAD_URL=$(bashio::config 'seafile_upload_url')
PAPERLESS_URL=$(bashio::config 'paperless_url')
PAPERLESS_TOKEN=$(bashio::config 'paperless_token')
OCR_LANGUAGE=$(bashio::config 'ocr_language')
SCAN_DUPLEX=$(bashio::config 'scan_duplex')
SCAN_COLOR=$(bashio::config 'scan_color')
SCAN_PROFILE=$(bashio::config 'scan_profile')
PROCESSING_PROFILE=$(bashio::config 'processing_profile')
ARCHIVE_RAW_SCANS=$(bashio::config 'archive_raw_scans')
RAW_SCAN_ARCHIVE_DIR=$(bashio::config 'raw_scan_archive_dir')
ACTIVE_PROFILE_FILE="/data/active_processing_profile"

if bashio::config.has_value 'nextcloud_share_password'; then
    NEXTCLOUD_SHARE_PASSWORD=$(bashio::config 'nextcloud_share_password')
else
    NEXTCLOUD_SHARE_PASSWORD=""
fi

if ! bashio::var.true "${UPLOAD_NEXTCLOUD}" && ! bashio::var.true "${UPLOAD_SEAFILE}" && ! bashio::var.true "${UPLOAD_PAPERLESS}"; then
    bashio::exit.nok "Enable at least one upload destination"
fi

if bashio::var.true "${UPLOAD_NEXTCLOUD}"; then
    if bashio::var.is_empty "${NEXTCLOUD_URL}"; then
        bashio::exit.nok "nextcloud_url is required when upload_nextcloud=true"
    fi
    if bashio::var.is_empty "${NEXTCLOUD_SHARE_TOKEN}"; then
        bashio::exit.nok "nextcloud_share_token is required when upload_nextcloud=true"
    fi
fi

if bashio::var.true "${UPLOAD_SEAFILE}"; then
    if bashio::var.is_empty "${SEAFILE_UPLOAD_URL}"; then
        bashio::exit.nok "seafile_upload_url is required when upload_seafile=true"
    fi
fi

if bashio::var.true "${UPLOAD_PAPERLESS}"; then
    if bashio::var.is_empty "${PAPERLESS_URL}"; then
        bashio::exit.nok "paperless_url is required when upload_paperless=true"
    fi
    if bashio::var.is_empty "${PAPERLESS_TOKEN}"; then
        bashio::exit.nok "paperless_token is required when upload_paperless=true"
    fi
fi

# Write config file for scan.sh (subprocess cannot use bashio)
mkdir -p /etc/scanbd
cat > /etc/scanbd/addon.conf <<EOF
NEXTCLOUD_URL="${NEXTCLOUD_URL}"
NEXTCLOUD_SHARE_TOKEN="${NEXTCLOUD_SHARE_TOKEN}"
NEXTCLOUD_SHARE_PASSWORD="${NEXTCLOUD_SHARE_PASSWORD}"
SEAFILE_UPLOAD_URL="${SEAFILE_UPLOAD_URL}"
PAPERLESS_URL="${PAPERLESS_URL}"
PAPERLESS_TOKEN="${PAPERLESS_TOKEN}"
UPLOAD_NEXTCLOUD="${UPLOAD_NEXTCLOUD}"
UPLOAD_SEAFILE="${UPLOAD_SEAFILE}"
UPLOAD_PAPERLESS="${UPLOAD_PAPERLESS}"
SCAN_PROFILE="${SCAN_PROFILE}"
PROCESSING_PROFILE="${PROCESSING_PROFILE}"
ARCHIVE_RAW_SCANS="${ARCHIVE_RAW_SCANS}"
RAW_SCAN_ARCHIVE_DIR="${RAW_SCAN_ARCHIVE_DIR}"
ACTIVE_PROFILE_FILE="${ACTIVE_PROFILE_FILE}"
OCR_LANGUAGE="${OCR_LANGUAGE}"
SCAN_DUPLEX="${SCAN_DUPLEX}"
SCAN_COLOR="${SCAN_COLOR}"
EOF
chmod 600 /etc/scanbd/addon.conf

mkdir -p /data
if [ ! -f "${ACTIVE_PROFILE_FILE}" ]; then
    printf '%s\n' "${PROCESSING_PROFILE}" > "${ACTIVE_PROFILE_FILE}"
fi

bashio::log.info "Nextcloud URL: ${NEXTCLOUD_URL}"
bashio::log.info "Seafile upload URL: ${SEAFILE_UPLOAD_URL}"
bashio::log.info "Paperless URL: ${PAPERLESS_URL}"
bashio::log.info "OCR language: ${OCR_LANGUAGE}"
bashio::log.info "Upload destinations: nextcloud=${UPLOAD_NEXTCLOUD} seafile=${UPLOAD_SEAFILE} paperless=${UPLOAD_PAPERLESS}"
bashio::log.info "Configured scan mode: profile=${SCAN_PROFILE} | color: ${SCAN_COLOR} | duplex: ${SCAN_DUPLEX}"
bashio::log.info "Document processing profile: ${PROCESSING_PROFILE}"
bashio::log.info "Active processing profile file: ${ACTIVE_PROFILE_FILE}"
bashio::log.info "Archive raw scans: ${ARCHIVE_RAW_SCANS} (${RAW_SCAN_ARCHIVE_DIR})"
bashio::log.info "Low-level scan profile: ${SCAN_PROFILE}"
case "${SCAN_PROFILE}" in
    stable_300)
        bashio::log.info "USB-native scanning is using the stable 300dpi profile"
        ;;
    stable_600)
        bashio::log.warning "USB-native scanning is using the legacy 600dpi fallback profile"
        ;;
    *)
        bashio::log.warning "USB-native scanning is using an experimental low-level profile: ${SCAN_PROFILE}"
        ;;
esac

# Wait for USB to settle after container start
bashio::log.info "Waiting for USB devices to settle..."
sleep 3

bashio::log.info "Starting ScanSnap single-owner scanner daemon..."
exec env SCAN_PROFILE="${SCAN_PROFILE}" /usr/local/bin/scansnap_buttond
