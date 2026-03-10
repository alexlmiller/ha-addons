#!/usr/bin/with-contenv bashio

# Read configuration options
NEXTCLOUD_URL=$(bashio::config 'nextcloud_url')
NEXTCLOUD_SHARE_TOKEN=$(bashio::config 'nextcloud_share_token')
SEAFILE_UPLOAD_URL=$(bashio::config 'seafile_upload_url')
OCR_LANGUAGE=$(bashio::config 'ocr_language')
SCAN_DUPLEX=$(bashio::config 'scan_duplex')
SCAN_COLOR=$(bashio::config 'scan_color')
STORAGE_BACKEND=$(bashio::config 'storage_backend')
SCAN_PROFILE=$(bashio::config 'scan_profile')
PROCESSING_PROFILE=$(bashio::config 'processing_profile')
ARCHIVE_RAW_SCANS=$(bashio::config 'archive_raw_scans')
RAW_SCAN_ARCHIVE_DIR=$(bashio::config 'raw_scan_archive_dir')

if bashio::config.has_value 'nextcloud_share_password'; then
    NEXTCLOUD_SHARE_PASSWORD=$(bashio::config 'nextcloud_share_password')
else
    NEXTCLOUD_SHARE_PASSWORD=""
fi

# Validate required fields for the selected backend
case "${STORAGE_BACKEND}" in
    nextcloud)
        if bashio::var.is_empty "${NEXTCLOUD_URL}"; then
            bashio::exit.nok "nextcloud_url is required when storage_backend=nextcloud"
        fi
        if bashio::var.is_empty "${NEXTCLOUD_SHARE_TOKEN}"; then
            bashio::exit.nok "nextcloud_share_token is required when storage_backend=nextcloud"
        fi
        ;;
    seafile)
        if bashio::var.is_empty "${SEAFILE_UPLOAD_URL}"; then
            bashio::exit.nok "seafile_upload_url is required when storage_backend=seafile"
        fi
        ;;
    *)
        bashio::exit.nok "unsupported storage_backend: ${STORAGE_BACKEND}"
        ;;
esac

# Write config file for scan.sh (subprocess cannot use bashio)
mkdir -p /etc/scanbd
cat > /etc/scanbd/addon.conf <<EOF
NEXTCLOUD_URL="${NEXTCLOUD_URL}"
NEXTCLOUD_SHARE_TOKEN="${NEXTCLOUD_SHARE_TOKEN}"
NEXTCLOUD_SHARE_PASSWORD="${NEXTCLOUD_SHARE_PASSWORD}"
SEAFILE_UPLOAD_URL="${SEAFILE_UPLOAD_URL}"
STORAGE_BACKEND="${STORAGE_BACKEND}"
SCAN_PROFILE="${SCAN_PROFILE}"
PROCESSING_PROFILE="${PROCESSING_PROFILE}"
ARCHIVE_RAW_SCANS="${ARCHIVE_RAW_SCANS}"
RAW_SCAN_ARCHIVE_DIR="${RAW_SCAN_ARCHIVE_DIR}"
OCR_LANGUAGE="${OCR_LANGUAGE}"
SCAN_DUPLEX="${SCAN_DUPLEX}"
SCAN_COLOR="${SCAN_COLOR}"
EOF
chmod 600 /etc/scanbd/addon.conf

bashio::log.info "Nextcloud URL: ${NEXTCLOUD_URL}"
bashio::log.info "Seafile upload URL: ${SEAFILE_UPLOAD_URL}"
bashio::log.info "OCR language: ${OCR_LANGUAGE}"
bashio::log.info "Storage backend: ${STORAGE_BACKEND}"
bashio::log.info "Configured scan mode: profile=${SCAN_PROFILE} | color: ${SCAN_COLOR} | duplex: ${SCAN_DUPLEX}"
bashio::log.info "Document processing profile: ${PROCESSING_PROFILE}"
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
