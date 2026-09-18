#!/usr/bin/env python3
"""Inspect an APK for the expected application resources."""

from __future__ import annotations

import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: scripts/inspect_apk.py path/to/app.apk")
    apk = Path(sys.argv[1]).resolve()
    manifest = json.loads((ROOT / "assets/SOURCE_MANIFEST.json").read_text())
    expected_luts = {
        "assets/luts/" + Path(record["path"]).name
        for record in manifest["resources"]
        if "/luts/" in record["path"]
    }
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        packaged_luts = {
            name
            for name in names
            if name.startswith("assets/luts/") and name.endswith(".cube")
        }
        if packaged_luts != expected_luts:
            raise SystemExit(
                f"Packaged LUT mismatch: expected={expected_luts} actual={packaged_luts}"
            )
        dex_names = [name for name in names if re.fullmatch(r"classes\d*\.dex", name)]
        if not dex_names:
            raise SystemExit("APK contains no application DEX file")
    print(
        f"APK check passed: {apk}; {len(dex_names)} app DEX file(s), "
        f"{len(packaged_luts)} manifest-covered LUTs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
