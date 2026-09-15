#!/usr/bin/env python3
"""Render sr's app icon and pack it into resources/sr.icns.

The icon is drawn here rather than checked in as a pile of PNGs so the
artwork has a single, readable source of truth: change a colour or a bar
height below, re-run, commit the regenerated .icns.

    python3 -m pip install Pillow
    python3 scripts/make-icon.py

Everything is drawn on a 1024-point Apple icon grid: an 824-point rounded
squircle centred in the canvas (Apple's macOS Big Sur proportions), a soft
contact shadow underneath, and a speech waveform on top. Drawing happens at
4x and is downsampled, which is cheaper to reason about than hand-rolled
antialiasing.
"""

from __future__ import annotations

import io
import math
import os
import struct

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT_ICNS = os.path.join(REPO, "resources", "sr.icns")
OUT_PNG = os.path.join(REPO, "resources", "sr-icon-1024.png")

# Apple's macOS icon grid, in 1024-point units.
CANVAS = 1024
SQUIRCLE = 824           # width of the rounded square
CORNER = 185.4           # corner radius at 824 points
SUPERSAMPLE = 4

# Deep indigo → violet, the accent family a "read it to me" utility wants:
# calm, high contrast against both light and dark Dock backgrounds.
TOP_COLOR = (99, 91, 255)       # indigo
BOTTOM_COLOR = (168, 66, 214)   # violet

# Waveform bar heights as a fraction of the squircle's height, symmetric and
# tallest in the middle. Small renders drop bars rather than shrink them:
# seven 66-point bars turn to mush below 32 points, where a bar and its gap
# are barely a pixel each, so those sizes get a chunkier three-bar mark that
# still reads as "speech".
BAR_SETS = [
    # (largest size this set is used for, heights, bar width at 1024 points)
    (24, [0.52, 1.0, 0.52], 128.0),
    (64, [0.40, 0.72, 1.0, 0.72, 0.40], 92.0),
    (10_000, [0.24, 0.46, 0.72, 0.98, 0.72, 0.46, 0.24], 66.0),
]


def bars_for(size: int) -> tuple[list[float], float]:
    for limit, heights, width in BAR_SETS:
        if size <= limit:
            return heights, width
    return BAR_SETS[-1][1], BAR_SETS[-1][2]


def squircle_mask(size: int, inset: float, radius: float) -> Image.Image:
    """A superellipse ("squircle") mask, the shape macOS icons actually use.

    Pillow's rounded_rectangle uses circular corners, which read as visibly
    pinched next to real macOS icons, so the outline is walked by hand.
    """
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    left, top = inset, inset
    right, bottom = size - inset, size - inset
    half = (right - left) / 2.0
    cx, cy = left + half, top + half
    # Superellipse exponent chosen so the curve passes through the same
    # corner offset a radius-`radius` rounded rect would.
    n = math.log(2.0) / math.log(half / (half - radius * (1 - math.sqrt(2) / 2)))
    n = max(n, 2.2)
    points = []
    steps = 720
    for i in range(steps):
        theta = 2.0 * math.pi * i / steps
        ct, st = math.cos(theta), math.sin(theta)
        x = cx + half * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + half * math.copysign(abs(st) ** (2.0 / n), st)
        points.append((x, y))
    draw.polygon(points, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        grad.putpixel((0, y), tuple(
            int(round(top[c] + (bottom[c] - top[c]) * t)) for c in range(3)))
    return grad.resize((size, size), Image.BILINEAR)


def render(size: int, points: int | None = None) -> Image.Image:
    """`size` is the pixel size; `points` the logical size it is drawn for."""
    points = points if points is not None else size
    s = size * SUPERSAMPLE
    scale = s / CANVAS
    inset = (CANVAS - SQUIRCLE) / 2.0 * scale
    radius = CORNER * scale

    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shape = squircle_mask(s, inset, radius)

    # Contact shadow: the squircle, blurred, nudged down, at low opacity.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shadow.putalpha(shape.point(lambda v: int(v * 0.30)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(s * 0.014, 1)))
    shadow = shadow.transform(
        (s, s), Image.AFFINE, (1, 0, 0, 0, 1, -s * 0.012), resample=Image.BILINEAR)
    canvas.alpha_composite(shadow)

    body = vertical_gradient(s, TOP_COLOR, BOTTOM_COLOR).convert("RGBA")

    # Top-edge sheen, the way macOS icons catch light from above. Blurred
    # well past the ellipse's own edge so it fades out instead of banding.
    sheen = Image.new("L", (s, s), 0)
    ImageDraw.Draw(sheen).ellipse(
        [-s * 0.45, -s * 0.95, s * 1.45, s * 0.38], fill=46)
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=max(s * 0.07, 1)))
    body.alpha_composite(Image.merge(
        "RGBA", (Image.new("L", (s, s), 255),) * 3 + (sheen,)))

    body.putalpha(shape)
    canvas.alpha_composite(body)

    draw_waveform(canvas, s, scale, points)

    # Hairline inner rim (shape minus an eroded copy of itself), so the icon
    # keeps a defined edge against a white Finder background.
    eroded = shape.filter(ImageFilter.MinFilter(3))
    rim_alpha = Image.composite(Image.new("L", (s, s), 0), shape, eroded)
    rim = Image.new("RGBA", (s, s), (255, 255, 255, 255))
    rim.putalpha(rim_alpha.point(lambda v: int(v * 0.22)))
    canvas.alpha_composite(rim)

    return canvas.resize((size, size), Image.LANCZOS)


def draw_waveform(canvas: Image.Image, s: int, scale: float, points: int) -> None:
    """White rounded bars, centred, with a soft drop shadow for depth."""
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    heights, bar_points = bars_for(points)
    bar_w = bar_points * scale
    gap = bar_w * 0.64
    count = len(heights)
    total_w = count * bar_w + (count - 1) * gap
    left = (s - total_w) / 2.0
    cy = s / 2.0
    max_h = SQUIRCLE * scale * 0.52

    for i, factor in enumerate(heights):
        h = max_h * factor
        x0 = left + i * (bar_w + gap)
        draw.rounded_rectangle(
            [x0, cy - h / 2.0, x0 + bar_w, cy + h / 2.0],
            radius=bar_w / 2.0, fill=(255, 255, 255, 255))

    glow = layer.filter(ImageFilter.GaussianBlur(radius=max(s * 0.012, 1)))
    glow.putalpha(glow.getchannel("A").point(lambda v: int(v * 0.35)))
    shifted = glow.transform(
        (s, s), Image.AFFINE, (1, 0, 0, 0, 1, -s * 0.008), resample=Image.BILINEAR)
    shadow = Image.new("RGBA", (s, s), (40, 12, 80, 0))
    shadow.putalpha(shifted.getchannel("A"))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(layer)


# ICNS entry types that take a PNG payload: (type, pixels, points). Both the
# @1x and @2x slots are filled so macOS never has to rescale. The point size
# — not the pixel size — picks the bar set, so a 16-point icon shows the same
# mark on a Retina display as on a plain one, just sharper.
ICNS_TYPES = [
    (b"icp4", 16, 16),
    (b"icp5", 32, 32),
    (b"icp6", 64, 64),
    (b"ic07", 128, 128),
    (b"ic08", 256, 256),
    (b"ic09", 512, 512),
    (b"ic10", 1024, 512),
    (b"ic11", 32, 16),
    (b"ic12", 64, 32),
    (b"ic13", 256, 128),
    (b"ic14", 512, 256),
]


def main() -> None:
    os.makedirs(os.path.dirname(OUT_ICNS), exist_ok=True)

    cache: dict[tuple[int, int], bytes] = {}
    for _, pixels, points in ICNS_TYPES:
        if (pixels, points) in cache:
            continue
        buffer = io.BytesIO()
        render(pixels, points).save(buffer, format="PNG", optimize=True)
        cache[(pixels, points)] = buffer.getvalue()

    entries = b"".join(
        kind + struct.pack(">I", len(cache[(pixels, points)]) + 8)
        + cache[(pixels, points)]
        for kind, pixels, points in ICNS_TYPES
    )
    icns = b"icns" + struct.pack(">I", len(entries) + 8) + entries
    with open(OUT_ICNS, "wb") as handle:
        handle.write(icns)

    with open(OUT_PNG, "wb") as handle:
        handle.write(cache[(1024, 512)])

    print(f"wrote {OUT_ICNS} ({len(icns):,} bytes, {len(ICNS_TYPES)} variants)")
    print(f"wrote {OUT_PNG}")


if __name__ == "__main__":
    main()
