#!/usr/bin/env python3
"""Check the source tree for the current application package identity."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "io.github.dearzl.mirrorbridge"
PACKAGE_PATH = "io/github/dearzl/mirrorbridge"


def tracked_files() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
    )
    return [
        ROOT / value.decode()
        for value in output.split(b"\0")
        if value and (ROOT / value.decode()).is_file()
    ]


def main() -> int:
    findings: list[str] = []
    for path in tracked_files():
        relative = path.relative_to(ROOT).as_posix()
        if PACKAGE_PATH in relative:
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if path.suffix in {".kt", ".kts"} and "package " in text:
                if "package " + PACKAGE not in text:
                    findings.append(f"PACKAGE {relative}")
    if findings:
        print("Package identity findings:")
        print("\n".join(findings))
        return 1
    print(f"Package check passed: {len(tracked_files())} source files inspected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
