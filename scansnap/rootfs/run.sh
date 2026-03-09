#!/usr/bin/with-contenv bashio

# Read configuration options
NEXTCLOUD_URL=$(bashio::config 'nextcloud_url')
NEXTCLOUD_SHARE_TOKEN=$(bashio::config 'nextcloud_share_token')
SCAN_RESOLUTION=$(bashio::config 'scan_resolution')
OCR_LANGUAGE=$(bashio::config 'ocr_language')
SCAN_DUPLEX=$(bashio::config 'scan_duplex')
SCAN_COLOR=$(bashio::config 'scan_color')
STORAGE_BACKEND=$(bashio::config 'storage_backend')
SCAN_PROFILE=$(bashio::config 'scan_profile')

if bashio::config.has_value 'nextcloud_share_password'; then
    NEXTCLOUD_SHARE_PASSWORD=$(bashio::config 'nextcloud_share_password')
else
    NEXTCLOUD_SHARE_PASSWORD=""
fi

# Validate required fields
if bashio::var.is_empty "${NEXTCLOUD_URL}"; then
    bashio::exit.nok "nextcloud_url is required"
fi
if bashio::var.is_empty "${NEXTCLOUD_SHARE_TOKEN}"; then
    bashio::exit.nok "nextcloud_share_token is required"
fi

# Write config file for scan.sh (subprocess cannot use bashio)
mkdir -p /etc/scanbd
cat > /etc/scanbd/addon.conf <<EOF
NEXTCLOUD_URL="${NEXTCLOUD_URL}"
NEXTCLOUD_SHARE_TOKEN="${NEXTCLOUD_SHARE_TOKEN}"
NEXTCLOUD_SHARE_PASSWORD="${NEXTCLOUD_SHARE_PASSWORD}"
STORAGE_BACKEND="${STORAGE_BACKEND}"
SCAN_PROFILE="${SCAN_PROFILE}"
SCAN_RESOLUTION="${SCAN_RESOLUTION}"
OCR_LANGUAGE="${OCR_LANGUAGE}"
SCAN_DUPLEX="${SCAN_DUPLEX}"
SCAN_COLOR="${SCAN_COLOR}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"
EOF
chmod 600 /etc/scanbd/addon.conf

bashio::log.info "Nextcloud URL: ${NEXTCLOUD_URL}"
bashio::log.info "OCR language: ${OCR_LANGUAGE}"
bashio::log.info "Storage backend: ${STORAGE_BACKEND}"
bashio::log.info "Configured scan mode: ${SCAN_RESOLUTION} dpi | color: ${SCAN_COLOR} | duplex: ${SCAN_DUPLEX}"
bashio::log.info "Low-level scan profile: ${SCAN_PROFILE}"
if [ "${SCAN_PROFILE}" = "stable_600" ]; then
    bashio::log.warning "USB-native scanning is using the stable fixed duplex/color/600dpi profile"
else
    bashio::log.warning "USB-native scanning is using the faster 300dpi test profile by default: ${SCAN_PROFILE}"
fi

# Wait for USB to settle after container start
bashio::log.info "Waiting for USB devices to settle..."
sleep 3

bashio::log.info "Starting ScanSnap single-owner scanner daemon..."
exec env SCAN_PROFILE="${SCAN_PROFILE}" /usr/local/bin/scansnap_buttond
