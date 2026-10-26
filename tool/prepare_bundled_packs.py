"""Prepare pinned, verified CMSIS-Packs for all platform release entrypoints."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
from urllib.parse import urlparse
import uuid

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "backend"))

from take_a_look_backend.services.target_catalog import MAX_PACK_BYTES, _parse_pack


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def prepare(directory: Path, lockfile: Path) -> dict:
    sources = json.loads(lockfile.read_text(encoding="utf-8"))
    directory.mkdir(parents=True, exist_ok=True)
    records = {}
    for source in sources["packs"]:
        expected = source["sha256"]
        if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise ValueError("Invalid pinned SHA-256")
        url = source["url"]
        if urlparse(url).scheme != "https":
            raise ValueError("Bundled packs must use HTTPS")
        destination = directory / f"{expected}.pack"
        original = directory / f"{source['vendor']}.{source['name']}.{source['version']}.pack"
        if original.is_file() and digest(original) == expected and not destination.exists():
            os.replace(original, destination)
        if not destination.is_file() or digest(destination) != expected:
            temporary = directory / f"download-{uuid.uuid4().hex}.tmp"
            try:
                deadline = time.monotonic() + 600
                request = urllib.request.Request(url, headers={"User-Agent": "TakeALook release builder"})
                with urllib.request.urlopen(request, timeout=60) as response, temporary.open("xb") as writer:
                    received = 0
                    read = getattr(response, "read1", response.read)
                    while block := read(256 * 1024):
                        received += len(block)
                        if received > MAX_PACK_BYTES or time.monotonic() > deadline:
                            raise ValueError("Bundled pack download exceeds size/time limit")
                        writer.write(block)
                if digest(temporary) != expected:
                    raise ValueError(f"SHA-256 mismatch for {source['name']}; the pinned release was not downloaded")
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
        metadata = _parse_pack(destination, expected)
        if (metadata["vendor"], metadata["name"], metadata["version"]) != (
                source["vendor"], source["name"], source["version"]):
            raise ValueError("Bundled pack metadata does not match the pinned release")
        if not any(target["name"].startswith(source["requiredPrefix"]) for target in metadata["targets"]):
            raise ValueError(f"Required chip family missing: {source['requiredPrefix']}")
        metadata.pop("importedAt", None)
        metadata.update(bundled=True, sourceUrl=url, requiredPrefix=source["requiredPrefix"])
        records[expected] = metadata
        print(f"Bundled {metadata['vendor']}.{metadata['name']} {metadata['version']}: "
              f"{metadata['targetCount']} targets, {metadata['size']} bytes", flush=True)
    index = {"version": 1, "packs": records,
             "requiredPrefixes": [source["requiredPrefix"] for source in sources["packs"]]}
    temporary = directory / f"index-{uuid.uuid4().hex}.tmp"
    try:
        temporary.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, directory / "index.json")
    finally:
        temporary.unlink(missing_ok=True)
    # Copy only the pinned release set; old, unreferenced versions must not leak
    # into the distribution or silently inflate every platform package.
    for path in directory.glob("*.pack"):
        if path.name not in {f"{key}.pack" for key in records}:
            path.unlink()
    return index


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=PROJECT / "backend/bundled_packs")
    parser.add_argument("--lockfile", type=Path, default=PROJECT / "tool/bundled_packs.json")
    args = parser.parse_args()
    prepare(args.output, args.lockfile)
