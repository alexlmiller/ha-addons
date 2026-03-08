#!/usr/bin/env python3
"""
Remove blank TIFF pages in-place. Blank = >97% near-white pixels.

Usage: remove_blank_pages.py page_0001.tiff page_0002.tiff ...

Strips blank duplex reverses produced when scanning single-sided originals.
Prints kept/removed status to stderr; deletes blank files.
"""

import os
import sys
from PIL import Image, ImageStat

# Pixel value threshold: above this is considered "white" (0=black, 255=white)
WHITE_PIXEL_MIN = 240
# Fraction of white pixels required to call a page blank
BLANK_FRACTION = 0.97


def is_blank(path: str) -> bool:
    with Image.open(path) as img:
        gray = img.convert("L")
        stat = ImageStat.Stat(gray)
        mean = stat.mean[0]
        stddev = stat.stddev[0]
        # Fast pre-check: very high mean + very low stddev = uniform white
        if mean > 245 and stddev < 3:
            return True
        # Full pixel count for borderline cases
        pixels = list(gray.getdata())
        white_count = sum(1 for p in pixels if p > WHITE_PIXEL_MIN)
        return white_count / len(pixels) > BLANK_FRACTION


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <tiff> [tiff ...]", file=sys.stderr)
        sys.exit(1)

    for path in sys.argv[1:]:
        try:
            if is_blank(path):
                os.remove(path)
                print(f"BLANK  (removed): {path}", file=sys.stderr)
            else:
                print(f"KEEP:             {path}", file=sys.stderr)
        except Exception as e:
            print(f"ERROR processing {path}: {e}", file=sys.stderr)
            # Don't remove on error — keep the page


if __name__ == "__main__":
    main()
