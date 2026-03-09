#!/usr/bin/env python3
"""
Rotate scanned image pages 180 degrees in place.

Usage: rotate_pages.py page_0001.jpg page_0002.tiff ...
"""

import sys
from PIL import Image


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <image> [image ...]", file=sys.stderr)
        return 1

    for path in sys.argv[1:]:
        try:
            with Image.open(path) as img:
                rotated = img.rotate(180, expand=True)
                rotated.save(path)
            print(f"ROTATE:           {path}", file=sys.stderr)
        except Exception as exc:
            print(f"ERROR rotating {path}: {exc}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
