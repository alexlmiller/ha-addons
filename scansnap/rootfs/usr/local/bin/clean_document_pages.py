#!/usr/bin/env python3
"""
Apply conservative document cleanup to scanned image pages in-place.

This targets paper texture and bleed-through while preserving dark text.
It intentionally avoids aggressive binarization so the result remains
readable as an archival scan and suitable for OCR/LLM processing.
"""

import sys
from PIL import Image, ImageFilter, ImageOps

TEXT_THRESHOLD = 185
BACKGROUND_FLOOR = 236
CONTRAST_CUTOFF = 1
JPEG_QUALITY = 72


def flatten_background(gray: Image.Image) -> Image.Image:
    text_mask = gray.point(lambda p: 255 if p < TEXT_THRESHOLD else 0, mode="L")
    background = gray.point(
        lambda p: p if p < TEXT_THRESHOLD else max(BACKGROUND_FLOOR, p),
        mode="L",
    )
    return Image.composite(gray, background, text_mask)


def clean_page(path: str) -> None:
    with Image.open(path) as img:
        gray = img.convert("L")
        cleaned = ImageOps.autocontrast(gray, cutoff=CONTRAST_CUTOFF)
        cleaned = flatten_background(cleaned)
        cleaned = cleaned.filter(ImageFilter.MedianFilter(size=3))
        cleaned.save(path, format="JPEG", quality=JPEG_QUALITY, optimize=True)


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <image> [image ...]", file=sys.stderr)
        return 1

    for path in sys.argv[1:]:
        try:
            clean_page(path)
            print(f"CLEAN:            {path}", file=sys.stderr)
        except Exception as exc:
            print(f"ERROR cleaning {path}: {exc}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
