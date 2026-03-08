ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
    # SANE + Fujitsu backend
    sane-utils \
    libsane \
    # Button daemon
    scanbd \
    # OCR engine
    tesseract-ocr \
    tesseract-ocr-eng \
    # OCR pipeline (also installs ghostscript, unpaper)
    ocrmypdf \
    # Lossless TIFF→PDF assembly
    img2pdf \
    # Text extraction from OCR'd PDF
    poppler-utils \
    # Upload and HA API calls
    curl \
    # USB access for SANE
    libusb-1.0-0 \
    # Python scripts
    python3 \
    python3-pip \
    python3-pillow \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs/ /

RUN chmod +x \
    /run.sh \
    /etc/scanbd/scripts/scan.sh \
    /usr/local/bin/remove_blank_pages.py \
    /usr/local/bin/name_from_ocr.py

CMD ["/run.sh"]
