FROM golang:1.24-bookworm AS builder

WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/scansnap_buttond ./cmd/scansnap_buttond

ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apt-get update && apt-get install -y --no-install-recommends \
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
    # Python scripts for scan processing
    python3 \
    python3-pillow \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/scansnap_buttond /usr/local/bin/scansnap_buttond
COPY rootfs/ /

RUN chmod +x \
    /run.sh \
    /etc/scanbd/scripts/scan.sh \
    /usr/local/bin/scansnap_buttond \
    /usr/local/bin/remove_blank_pages.py \
    /usr/local/bin/name_from_ocr.py

CMD ["/run.sh"]
