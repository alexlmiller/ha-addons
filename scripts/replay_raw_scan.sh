#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <raw_scan_dir> <output_dir> [profile ...]" >&2
    echo "Example: $0 /share/scansnap-raw/20260310-101500-scan-abcd /tmp/replay baseline gray_light" >&2
    exit 1
fi

RAW_SCAN_DIR="$1"
OUTPUT_DIR="$2"
shift 2

if [ ! -d "${RAW_SCAN_DIR}" ]; then
    echo "ERROR: raw scan dir not found: ${RAW_SCAN_DIR}" >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    set -- baseline gray_light gray_soft gray_bg_flatten
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCAN_SCRIPT="${ROOT_DIR}/scansnap/rootfs/etc/scanbd/scripts/scan.sh"

mkdir -p "${OUTPUT_DIR}"

for profile in "$@"; do
    workdir="$(mktemp -d /tmp/scansnap-replay-XXXXXX)"
    cp -R "${RAW_SCAN_DIR}/." "${workdir}/"
    addon_conf="$(mktemp /tmp/scansnap-addon-conf-XXXXXX)"
    cat > "${addon_conf}" <<EOF
NEXTCLOUD_URL=""
NEXTCLOUD_SHARE_TOKEN=""
NEXTCLOUD_SHARE_PASSWORD=""
SEAFILE_UPLOAD_URL=""
STORAGE_BACKEND="local"
SCAN_PROFILE="stable_300"
PROCESSING_PROFILE="${profile}"
ARCHIVE_RAW_SCANS="false"
RAW_SCAN_ARCHIVE_DIR="/tmp/scansnap-raw"
OCR_LANGUAGE="eng"
SCAN_DUPLEX="true"
SCAN_COLOR="Gray"
EOF

    outfile_dir="${OUTPUT_DIR}/${profile}"
    mkdir -p "${outfile_dir}"

    echo "==> Replaying ${RAW_SCAN_DIR} with profile=${profile}" >&2
    SCANNED_DIR="${workdir}" \
    LOCAL_OUTPUT_DIR="${outfile_dir}" \
    ADDON_CONF_PATH="${addon_conf}" \
    PROCESSING_PROFILE="${profile}" \
    "${SCAN_SCRIPT}"

    rm -f "${addon_conf}"
done
