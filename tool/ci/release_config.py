"""Validate release inputs and create the native GitHub Actions build matrix."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys

PROJECT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?")
PLATFORMS = [
    {"target": "windows", "runner": "windows-2022", "arch": "x64", "flutter": "3.47.8"},
    {"target": "linux", "runner": "ubuntu-22.04", "arch": "x64", "flutter": "3.44.9"},
    {"target": "macos", "runner": "macos-15", "arch": "arm64", "flutter": "3.47.8"},
    {"target": "macos", "runner": "macos-15-intel", "arch": "x64", "flutter": "3.47.8"},
]


def configure(event: dict, event_name: str, ref: str, pubspec: str) -> dict:
    inputs = event.get("inputs") or {}
    target = inputs.get("target", "all")
    mode = inputs.get("mode", "release")
    package = inputs.get("windows_package", "all")
    version = str(inputs.get("version", "")).strip()
    if event_name == "push":
        if not ref.startswith("refs/tags/v"):
            raise ValueError("Release push events must use a v<version> tag")
        version, mode, target, package = ref.removeprefix("refs/tags/v"), "release", "all", "all"
    if target not in ("all", "windows", "linux", "macos"):
        raise ValueError("Invalid target")
    if mode not in ("release", "debug") or package not in ("all", "msi", "portable"):
        raise ValueError("Invalid mode or Windows package")
    if not version:
        match = re.search(r"^version:\s*([^\r\n#]+)", pubspec, re.MULTILINE)
        if not match:
            raise ValueError("pubspec.yaml has no version field")
        version = match[1].strip()
    if not VERSION.fullmatch(version):
        raise ValueError("Version must use major.minor.patch[+build]")
    # Validate before any expensive platform jobs are allocated.
    if target in ("all", "windows"):
        parts = [int(part) for part in re.split(r"[.+]", version)]
        if any(part > 65535 for part in parts):
            raise ValueError("Windows version fields must fit 0..65535")
        if package != "portable" and (parts[0] > 255 or parts[1] > 255):
            raise ValueError("MSI major/minor versions must fit 0..255")
    matrix = {"include": [row for row in PLATFORMS if target == "all" or row["target"] == target]}
    return {"version": version, "mode": mode, "windows_package": package,
            "matrix": json.dumps(matrix, separators=(",", ":"))}


def main() -> None:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    result = configure(event, os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"],
                       (PROJECT / "pubspec.yaml").read_text(encoding="utf-8"))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
        for key, value in result.items():
            stream.write(f"{key}={value}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(f"Invalid release configuration: {error}")
