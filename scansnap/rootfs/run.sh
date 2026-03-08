#!/usr/bin/with-contenv bashio

# Read configuration options
NEXTCLOUD_URL=$(bashio::config 'nextcloud_url')
NEXTCLOUD_SHARE_TOKEN=$(bashio::config 'nextcloud_share_token')
SCAN_RESOLUTION=$(bashio::config 'scan_resolution')
OCR_LANGUAGE=$(bashio::config 'ocr_language')

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

# Write config file for scan.sh (scanbd subprocess cannot use bashio)
# Include SUPERVISOR_TOKEN so scan.sh can call the HA API
mkdir -p /etc/scanbd
cat > /etc/scanbd/addon.conf <<EOF
NEXTCLOUD_URL="${NEXTCLOUD_URL}"
NEXTCLOUD_SHARE_TOKEN="${NEXTCLOUD_SHARE_TOKEN}"
NEXTCLOUD_SHARE_PASSWORD="${NEXTCLOUD_SHARE_PASSWORD}"
SCAN_RESOLUTION="${SCAN_RESOLUTION}"
OCR_LANGUAGE="${OCR_LANGUAGE}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"
EOF
chmod 600 /etc/scanbd/addon.conf

bashio::log.info "Nextcloud URL: ${NEXTCLOUD_URL}"
bashio::log.info "OCR language: ${OCR_LANGUAGE}"
bashio::log.info "Scan resolution: ${SCAN_RESOLUTION} dpi"

# Ensure scanbd pid directory exists
mkdir -p /var/run/scanbd

# Wait for USB to settle after container start
bashio::log.info "Waiting for USB devices to settle..."
sleep 3

# Log detected SANE devices (informational)
bashio::log.info "Detected SANE devices:"
scanimage -L 2>&1 | while IFS= read -r line; do
    bashio::log.info "  ${line}"
done || true

# Start scanbd in foreground; it polls the scanner button and calls scan.sh
bashio::log.info "Starting scanbd button daemon..."
exec /usr/sbin/scanbd -f -c /etc/scanbd/scanbd.conf
