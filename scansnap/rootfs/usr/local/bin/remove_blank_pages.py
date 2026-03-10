#!/usr/bin/env python3
"""
Remove blank scanned image pages in-place.

Usage: remove_blank_pages.py page_0001.jpg page_0002.tiff ...

Strips blank duplex reverses produced when scanning single-sided originals.
Prints kept/removed status to stderr; deletes blank files.
"""

import os
import sys
from dataclasses import dataclass
from PIL import Image, ImageFilter, ImageStat

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
BLEED_MEAN_MIN = 232.0
BLEED_STDDEV_MAX = 20.0
BLEED_DARK_FRACTION_MAX = 0.012
BLEED_VERY_DARK_FRACTION_MAX = 0.008
BLEED_MID_DARK_FRACTION_MAX = 0.14
BLEED_AVG_DARKNESS_MAX = 0.08
BLEED_EDGE_MEAN_MAX = 8.5
BLEED_EDGE_DARK_FRACTION_MAX = 0.035
FAINT_BLEED_MEAN_MIN = 234.0
FAINT_BLEED_STDDEV_MAX = 18.5
FAINT_BLEED_DARK_FRACTION_MAX = 0.02
FAINT_BLEED_VERY_DARK_FRACTION_MAX = 0.01
FAINT_BLEED_MID_DARK_FRACTION_MAX = 0.15
FAINT_BLEED_AVG_DARKNESS_MAX = 0.085
FAINT_BLEED_EDGE_MEAN_MAX = 12.0
FAINT_BLEED_EDGE_DARK_FRACTION_MAX = 0.085
TRAILING_BLANK_MEAN_MIN = 220.0
TRAILING_BLANK_STDDEV_MAX = 22.0
TRAILING_BLANK_DARK_FRACTION_MAX = 0.02
TRAILING_BLANK_EDGE_MEAN_MAX = 12.0
TRAILING_BLANK_EDGE_DARK_FRACTION_MAX = 0.08
TRAILING_BLANK_MEAN_DELTA_MIN = 12.0
TRAILING_BLANK_STDDEV_RATIO_MAX = 0.55
TRAILING_BLANK_EDGE_RATIO_MAX = 0.42


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


@dataclass
class PageStats:
    path: str
    mean: float
    stddev: float
    near_white_fraction: float
    dark_fraction: float
    very_dark_fraction: float
    mid_dark_fraction: float
    avg_darkness: float
    edge_mean: float
    edge_dark_fraction: float


def page_stats(path: str) -> PageStats:
    with Image.open(path) as img:
        gray = normalized_gray(img)
        stat = ImageStat.Stat(gray)
        mean = stat.mean[0]
        stddev = stat.stddev[0]

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
        edges = gray.filter(ImageFilter.FIND_EDGES)
        edge_hist = edges.histogram()
        edge_total = sum(edge_hist)
        edge_mean = ImageStat.Stat(edges).mean[0]
        edge_dark_fraction = sum(edge_hist[32:]) / edge_total

        return PageStats(
            path=path,
            mean=mean,
            stddev=stddev,
            near_white_fraction=near_white / total,
            dark_fraction=dark / total,
            very_dark_fraction=very_dark / total,
            mid_dark_fraction=mid_dark / total,
            avg_darkness=sum((255 - value) * count for value, count in enumerate(hist)) / (255 * total),
            edge_mean=edge_mean,
            edge_dark_fraction=edge_dark_fraction,
        )


def print_stats(stats: PageStats) -> None:
    print(
        "STATS:            "
        f"{stats.path} mean={stats.mean:.1f} stddev={stats.stddev:.1f} "
        f"near_white={stats.near_white_fraction:.4f} dark={stats.dark_fraction:.4f} "
        f"very_dark={stats.very_dark_fraction:.4f} mid_dark={stats.mid_dark_fraction:.4f} "
        f"avg_darkness={stats.avg_darkness:.4f} edge_mean={stats.edge_mean:.1f} "
        f"edge_dark={stats.edge_dark_fraction:.4f}",
        file=sys.stderr,
    )


def is_blank(stats: PageStats) -> bool:
    if stats.mean > 245 and stats.stddev < 4:
        return True

    return (
        stats.near_white_fraction >= NEAR_WHITE_FRACTION
        and stats.dark_fraction <= DARK_FRACTION_MAX
        and stats.mean >= MEAN_MIN
        and stats.stddev <= STDDEV_MAX
    ) or (
        stats.mean >= 228.0
        and stats.very_dark_fraction <= VERY_DARK_FRACTION_MAX
        and stats.mid_dark_fraction <= MID_DARK_FRACTION_MAX
        and stats.avg_darkness <= AVG_DARKNESS_MAX
    ) or (
        stats.mean >= BLEED_MEAN_MIN
        and stats.stddev <= BLEED_STDDEV_MAX
        and stats.dark_fraction <= BLEED_DARK_FRACTION_MAX
        and stats.very_dark_fraction <= BLEED_VERY_DARK_FRACTION_MAX
        and stats.mid_dark_fraction <= BLEED_MID_DARK_FRACTION_MAX
        and stats.avg_darkness <= BLEED_AVG_DARKNESS_MAX
        and stats.edge_mean <= BLEED_EDGE_MEAN_MAX
        and stats.edge_dark_fraction <= BLEED_EDGE_DARK_FRACTION_MAX
    ) or (
        stats.mean >= FAINT_BLEED_MEAN_MIN
        and stats.stddev <= FAINT_BLEED_STDDEV_MAX
        and stats.dark_fraction <= FAINT_BLEED_DARK_FRACTION_MAX
        and stats.very_dark_fraction <= FAINT_BLEED_VERY_DARK_FRACTION_MAX
        and stats.mid_dark_fraction <= FAINT_BLEED_MID_DARK_FRACTION_MAX
        and stats.avg_darkness <= FAINT_BLEED_AVG_DARKNESS_MAX
        and stats.edge_mean <= FAINT_BLEED_EDGE_MEAN_MAX
        and stats.edge_dark_fraction <= FAINT_BLEED_EDGE_DARK_FRACTION_MAX
    )


def is_trailing_blank_candidate(stats: PageStats, reference: PageStats) -> bool:
    return (
        stats.mean >= TRAILING_BLANK_MEAN_MIN
        and stats.stddev <= TRAILING_BLANK_STDDEV_MAX
        and stats.dark_fraction <= TRAILING_BLANK_DARK_FRACTION_MAX
        and stats.edge_mean <= TRAILING_BLANK_EDGE_MEAN_MAX
        and stats.edge_dark_fraction <= TRAILING_BLANK_EDGE_DARK_FRACTION_MAX
        and (stats.mean - reference.mean) >= TRAILING_BLANK_MEAN_DELTA_MIN
        and stats.stddev <= reference.stddev * TRAILING_BLANK_STDDEV_RATIO_MAX
        and stats.edge_mean <= reference.edge_mean * TRAILING_BLANK_EDGE_RATIO_MAX
    )


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <tiff> [tiff ...]", file=sys.stderr)
        sys.exit(1)

    stats_by_path = []
    for path in sys.argv[1:]:
        try:
            stats = page_stats(path)
            stats_by_path.append(stats)
            print_stats(stats)
        except Exception as e:
            print(f"ERROR processing {path}: {e}", file=sys.stderr)
            # Don't remove on error — keep the page

    blank_paths = {stats.path for stats in stats_by_path if is_blank(stats)}

    kept_candidates = [stats for stats in stats_by_path if stats.path not in blank_paths]
    if len(kept_candidates) >= 2:
        trailing = kept_candidates[-1]
        reference = kept_candidates[-2]
        if is_trailing_blank_candidate(trailing, reference):
            print(
                f"TRAILING_BLANK:   {trailing.path} "
                f"(lighter and lower-detail than {reference.path})",
                file=sys.stderr,
            )
            blank_paths.add(trailing.path)

    for stats in stats_by_path:
        if stats.path in blank_paths:
            try:
                os.remove(stats.path)
                print(f"BLANK  (removed): {stats.path}", file=sys.stderr)
            except Exception as e:
                print(f"ERROR removing {stats.path}: {e}", file=sys.stderr)
        else:
            print(f"KEEP:             {stats.path}", file=sys.stderr)


if __name__ == "__main__":
    main()
