#!/usr/bin/env python3
"""Verify generated assets and their source-manifest coverage."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "assets/SOURCE_MANIFEST.json"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    before = MANIFEST.read_bytes()
    subprocess.run([sys.executable, ROOT / "scripts/generate_luts.py"], check=True, cwd=ROOT)
    subprocess.run([sys.executable, ROOT / "scripts/generate_visual_assets.py"], check=True, cwd=ROOT)
    subprocess.run([sys.executable, ROOT / "scripts/generate_source_manifest.py"], check=True, cwd=ROOT)
    if MANIFEST.read_bytes() != before:
        raise SystemExit("Source manifest was stale; regenerate assets and commit the result")

    manifest = json.loads(before)
    records = {record["path"]: record for record in manifest["resources"]}
    expected = {
        "assets/demo.png", "assets/demo_raw.png",
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "assets/editor_presets").glob("*.png")],
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "assets/brand").glob("*.png")],
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "assets/demo_media").glob("*.png")],
        "android/app/src/main/res/drawable/ic_launcher_foreground.png",
        "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml",
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "assets/watermark_templates").glob("*.png")],
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "android/app/src/main/assets/luts").glob("*.cube")],
        "android/app/src/main/assets/live_view.vert",
        "android/app/src/main/assets/live_view.frag",
        *[path.relative_to(ROOT).as_posix() for path in (ROOT / "android/app/src/main/res").glob("mipmap-*/ic_launcher.png")],
    }
    if set(records) != expected:
        raise SystemExit(f"Source manifest coverage mismatch: missing={expected - set(records)} extra={set(records) - expected}")
    for relative, record in records.items():
        path = ROOT / relative
        if digest(path) != record["sha256"]:
            raise SystemExit(f"Hash mismatch: {relative}")
    if len(list((ROOT / "android/app/src/main/assets/luts").glob("*.cube"))) != 8:
        raise SystemExit("Expected exactly 8 built-in LUT files")
    if len(list((ROOT / "assets/watermark_templates").glob("*.png"))) != 10:
        raise SystemExit("Expected exactly 10 watermark previews")
    print(f"Source check passed: {len(records)} generated or project-owned release resources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
