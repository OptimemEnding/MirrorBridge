#!/usr/bin/env python3
"""Generate demo scenes and watermark thumbnails without external packages."""

from __future__ import annotations

import struct
import zlib
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 960, 640
TEMPLATES = [
    "clean_white", "night_frame", "gallery_label", "soft_shadow", "film_contact",
    "minimal_line", "studio_card", "focus_grid", "wide_caption", "compact_caption",
]


def png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    payload = b"\x89PNG\r\n\x1a\n"
    payload += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    payload += chunk(b"tEXt", b"Software\0MirrorBridge scripts/generate_visual_assets.py")
    payload += chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def canvas(width: int, height: int, color: tuple[int, int, int]) -> bytearray:
    return bytearray(color * (width * height))


def rectangle(pixels: bytearray, width: int, height: int, box: tuple[int, int, int, int], color: tuple[int, int, int]) -> None:
    left, top, right, bottom = box
    for y in range(max(0, top), min(height, bottom)):
        start = (y * width + max(0, left)) * 3
        end = (y * width + min(width, right)) * 3
        pixels[start:end] = bytearray(color * ((end - start) // 3))


def scene(width: int, height: int, dusk: bool = False) -> bytearray:
    pixels = canvas(width, height, (0, 0, 0))
    horizon = int(height * 0.58)
    top = (40, 60, 92) if dusk else (98, 166, 214)
    bottom = (220, 150, 108) if dusk else (214, 232, 226)
    for y in range(horizon):
        ratio = y / max(1, horizon - 1)
        color = tuple(round(a + (b - a) * ratio) for a, b in zip(top, bottom))
        rectangle(pixels, width, height, (0, y, width, y + 1), color)
    rectangle(pixels, width, height, (0, horizon, width, height), (71, 92, 78))
    rectangle(pixels, width, height, (0, int(height * .72), width, height), (82, 82, 86))
    rectangle(pixels, width, height, (int(width * .18), int(height * .38), int(width * .46), int(height * .75)), (188, 72, 56))
    rectangle(pixels, width, height, (int(width * .23), int(height * .47), int(width * .30), int(height * .61)), (38, 60, 72))
    rectangle(pixels, width, height, (int(width * .34), int(height * .47), int(width * .41), int(height * .61)), (38, 60, 72))
    rectangle(pixels, width, height, (int(width * .62), int(height * .28), int(width * .77), int(height * .73)), (221, 210, 179))
    for x in range(int(width * .05), int(width * .95), max(8, width // 13)):
        rectangle(pixels, width, height, (x, int(height * .52), x + width // 60, int(height * .73)), (42, 73, 52))
    rectangle(pixels, width, height, (int(width * .10), int(height * .84), int(width * .42), int(height * .87)), (231, 218, 167))
    rectangle(pixels, width, height, (int(width * .58), int(height * .84), int(width * .90), int(height * .87)), (231, 218, 167))
    return pixels


def thumbnail(name: str) -> bytearray:
    width, height = 360, 240
    dark = name in {"night_frame", "film_contact", "focus_grid"}
    backgrounds = {
        "clean_white": (252, 252, 250),
        "night_frame": (19, 23, 29),
        "gallery_label": (239, 234, 222),
        "soft_shadow": (222, 228, 232),
        "film_contact": (37, 32, 29),
        "minimal_line": (247, 248, 245),
        "studio_card": (230, 238, 236),
        "focus_grid": (28, 32, 34),
        "wide_caption": (242, 239, 232),
        "compact_caption": (235, 241, 244),
    }
    background = backgrounds[name]
    pixels = canvas(width, height, background)
    border = {"compact_caption": 12, "clean_white": 16, "studio_card": 24}.get(name, 20)
    band = {"wide_caption": 48, "gallery_label": 38, "film_contact": 24}.get(name, 30)
    image = scene(width - border * 2, height - border - band, dusk=dark)
    inner_width = width - border * 2
    inner_height = height - border - band
    for y in range(inner_height):
        source = y * inner_width * 3
        target = ((y + border) * width + border) * 3
        pixels[target:target + inner_width * 3] = image[source:source + inner_width * 3]
    lines = {
        "clean_white": (74, 84, 92), "night_frame": (93, 204, 155),
        "gallery_label": (112, 76, 52), "soft_shadow": (78, 101, 118),
        "film_contact": (224, 156, 70), "minimal_line": (52, 113, 95),
        "studio_card": (40, 118, 130), "focus_grid": (112, 220, 150),
        "wide_caption": (105, 68, 137), "compact_caption": (43, 92, 136),
    }
    line = lines[name]
    if name in {"minimal_line", "gallery_label"}:
        rectangle(pixels, width, height, (border, height - band + 6, width - border, height - band + 9), line)
    if name == "focus_grid":
        for x in range(0, width, 30): rectangle(pixels, width, height, (x, 0, x + 1, height), (52, 58, 64))
        for y in range(0, height, 30): rectangle(pixels, width, height, (0, y, width, y + 1), (52, 58, 64))
    if name in {"studio_card", "gallery_label", "wide_caption", "compact_caption"}:
        rectangle(pixels, width, height, (border, height - band + 12, int(width * .54), height - band + 18), line)
        rectangle(pixels, width, height, (int(width * .68), height - band + 12, width - border, height - band + 18), line)
    if name == "soft_shadow":
        rectangle(pixels, width, height, (border + 4, height - band + 8, width - border + 4, height - band + 13), (155, 165, 172))
    if name == "night_frame":
        rectangle(pixels, width, height, (width - border - 44, height - band + 9, width - border, height - band + 15), line)
    if name == "film_contact":
        for x in range(8, width, 24):
            rectangle(pixels, width, height, (x, 4, x + 10, 9), (218, 190, 132))
            rectangle(pixels, width, height, (x, height - 9, x + 10, height - 4), (218, 190, 132))
    return pixels


def launcher_icon(size: int) -> bytearray:
    pixels = canvas(size, size, (239, 244, 242))
    center = (size - 1) / 2
    outer = size * .39
    inner = size * .16
    colors = [(29, 48, 58), (36, 105, 112), (48, 139, 112), (210, 172, 68), (196, 83, 62), (99, 74, 117)]
    for y in range(size):
        for x in range(size):
            dx, dy = x - center, y - center
            radius = math.hypot(dx, dy)
            if inner <= radius <= outer:
                angle = (math.atan2(dy, dx) + math.pi * 2) % (math.pi * 2)
                sector = int(angle / (math.pi / 3)) % 6
                offset = (y * size + x) * 3
                pixels[offset:offset + 3] = bytes(colors[sector])
            elif radius < inner:
                offset = (y * size + x) * 3
                pixels[offset:offset + 3] = bytes((239, 244, 242))
    return pixels


def generate() -> None:
    # Project photographs and launcher artwork are canonical checked-in assets.
    # Regeneration only owns the procedural watermark previews.
    output = ROOT / "assets/watermark_templates"
    for old in output.glob("*"):
        if old.is_file(): old.unlink()
    for name in TEMPLATES:
        png(output / f"{name}.png", 360, 240, thumbnail(name))



if __name__ == "__main__":
    generate()
