#!/usr/bin/env python3
"""
Remove blank scanned image pages in-place.

Usage: remove_blank_pages.py page_0001.jpg page_0002.tiff ...

Strips blank duplex reverses produced when scanning single-sided originals.
Prints kept/removed status to stderr; deletes blank files.
"""

import os
import sys
from PIL import Image, ImageStat

NEAR_WHITE_MIN = 245
DARK_PIXEL_MAX = 200
NEAR_WHITE_FRACTION = 0.985
DARK_FRACTION_MAX = 0.0035
STDDEV_MAX = 18.0
MEAN_MIN = 235.0
MAX_SIDE = 1000
VERY_DARK_MAX = 160
VERY_DARK_FRACTION_MAX = 0.0008
MID_DARK_MAX = 225
MID_DARK_FRACTION_MAX = 0.035
AVG_DARKNESS_MAX = 0.05


def normalized_gray(img: Image.Image) -> Image.Image:
    gray = img.convert("L")
    width, height = gray.size
    scale = max(width, height)
    if scale > MAX_SIDE:
        ratio = MAX_SIDE / scale
        gray = gray.resize(
            (max(1, int(width * ratio)), max(1, int(height * ratio))),
            Image.Resampling.BILINEAR,
        )
    return gray


def is_blank(path: str) -> bool:
    with Image.open(path) as img:
        gray = normalized_gray(img)
        stat = ImageStat.Stat(gray)
        mean = stat.mean[0]
        stddev = stat.stddev[0]
        if mean > 245 and stddev < 4:
            return True

        hist = gray.histogram()
        total = sum(hist)
        near_white = sum(hist[NEAR_WHITE_MIN:])
        dark = sum(hist[: DARK_PIXEL_MAX + 1])
        very_dark = sum(hist[: VERY_DARK_MAX + 1])
        mid_dark = sum(hist[: MID_DARK_MAX + 1])
        near_white_fraction = near_white / total
        dark_fraction = dark / total
        very_dark_fraction = very_dark / total
        mid_dark_fraction = mid_dark / total
        avg_darkness = sum((255 - value) * count for value, count in enumerate(hist)) / (255 * total)

        blank = (
            near_white_fraction >= NEAR_WHITE_FRACTION
            and dark_fraction <= DARK_FRACTION_MAX
            and mean >= MEAN_MIN
            and stddev <= STDDEV_MAX
        ) or (
            mean >= 228.0
            and very_dark_fraction <= VERY_DARK_FRACTION_MAX
            and mid_dark_fraction <= MID_DARK_FRACTION_MAX
            and avg_darkness <= AVG_DARKNESS_MAX
        )

        print(
            "STATS:            "
            f"{path} mean={mean:.1f} stddev={stddev:.1f} "
            f"near_white={near_white_fraction:.4f} dark={dark_fraction:.4f} "
            f"very_dark={very_dark_fraction:.4f} mid_dark={mid_dark_fraction:.4f} "
            f"avg_darkness={avg_darkness:.4f}",
            file=sys.stderr,
        )

        return blank


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
