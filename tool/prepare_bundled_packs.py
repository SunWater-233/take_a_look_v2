"""Build compact runtime CMSIS-Packs from pinned, verified upstream archives."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import posixpath
import sys
import time
import urllib.request
from urllib.parse import urlparse
import uuid
from xml.etree import ElementTree
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_CACHE = PROJECT / "build/tools/cmsis-packs"
COMPACTION_VERSION = 1
sys.path.insert(0, str(PROJECT / "backend"))

from take_a_look_backend.services.target_catalog import MAX_PACK_BYTES, _parse_pack


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_archive(source: dict, directory: Path, cache: Path) -> Path:
    expected = source["sha256"]
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ValueError("Invalid pinned SHA-256")
    url = source["url"]
    if urlparse(url).scheme != "https":
        raise ValueError("Bundled packs must use HTTPS")
    destination = cache / f"{expected}.pack"
    if not destination.is_file() or digest(destination) != expected:
        # Migrate full archives left by older builds out of the shipped payload.
        for original in (directory / f"{expected}.pack",
                         directory / f"{source['vendor']}.{source['name']}.{source['version']}.pack"):
            if original.is_file() and digest(original) == expected:
                temporary = cache / f"migrate-{uuid.uuid4().hex}.tmp"
                try:
                    temporary.write_bytes(original.read_bytes())
                    os.replace(temporary, destination)
                finally:
                    temporary.unlink(missing_ok=True)
                break
        else:
            temporary = cache / f"download-{uuid.uuid4().hex}.tmp"
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
    return destination


def compact_pack(original: Path, destination: Path, prefixes: list[str]) -> None:
    """Keep device inheritance and referenced runtime files, plus license notices."""
    def prune(node) -> bool:
        for child in list(node):
            if child.tag in {"family", "subFamily", "device", "variant"} and not prune(child):
                node.remove(child)
        name = node.get("Dname") or node.get("Dvariant", "")
        return (any(child.tag in {"family", "subFamily", "device", "variant"} for child in node)
                or name.lower().startswith(tuple(prefixes)))

    with zipfile.ZipFile(original) as archive:
        names = {item.filename for item in archive.infolist() if not item.is_dir()}
        descriptions = [name for name in names if name.lower().endswith(".pdsc")]
        if len(descriptions) != 1:
            raise ValueError("Expected one PDSC in the pinned archive")
        pdsc = descriptions[0]
        base = posixpath.dirname(pdsc)
        root = ElementTree.fromstring(archive.read(pdsc))
        devices = root.find("devices")
        if devices is None or not prune(devices):
            raise ValueError(f"No devices match {prefixes}")
        for parent in devices.iter():
            for child in list(parent):
                if child.tag in {"book", "compile"}:
                    parent.remove(child)
        for child in list(root):
            if child.tag in {"components", "boards", "examples", "conditions", "csolution"}:
                root.remove(child)
        keep = {pdsc}
        runtime_attributes = {"algorithm": "name", "debug": "svd", "debugvars": "configfile",
                              "debugconfig": "sdf"}
        for node in root.iter():
            # Flash algorithms, SVDs, debug configurations and license references.
            values = list(node.attrib.values())
            if node.tag == "license" and node.text:
                values.append(node.text.strip())
            for value in values:
                member = posixpath.normpath(posixpath.join(base, value.replace("\\", "/")))
                if member in names:
                    keep.add(member)
                elif value and value == node.get(runtime_attributes.get(node.tag, "")):
                    raise ValueError(f"Missing runtime resource in pinned pack: {value}")
        keep.update(name for name in names if posixpath.basename(name).lower().startswith(
            ("license", "licence", "copying", "notice")))
        descriptor = ElementTree.tostring(root, encoding="utf-8", xml_declaration=True)
        with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as output:
            for name in sorted(keep):
                # Fixed timestamps and attributes make repeated builds reproducible.
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                output.writestr(info, descriptor if name == pdsc else archive.read(name), compresslevel=9)


def prepare(directory: Path, lockfile: Path, cache: Path = DEFAULT_CACHE) -> dict:
    if directory.resolve() == cache.resolve() or directory.resolve() in cache.resolve().parents:
        raise ValueError("The upstream cache must be outside the shipped pack directory")
    sources = json.loads(lockfile.read_text(encoding="utf-8"))
    directory.mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    records = {}
    for source in sources["packs"]:
        original = source_archive(source, directory, cache)
        prefixes = source["targetPrefixes"]
        if not prefixes or any(not isinstance(prefix, str) or not prefix or prefix != prefix.lower()
                               for prefix in prefixes):
            raise ValueError("Expected nonempty lowercase target prefixes")
        temporary = directory / f"compact-{uuid.uuid4().hex}.tmp"
        try:
            compact_pack(original, temporary, prefixes)
            compact_digest = digest(temporary)
            metadata = _parse_pack(temporary, compact_digest)
            if (metadata["targetCount"] != source["expectedTargetCount"]
                    or any(not target["name"].startswith(tuple(prefixes)) for target in metadata["targets"])):
                raise ValueError(f"Unexpected compact target catalogue for {source['name']}")
            destination = directory / f"{compact_digest}.pack"
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
        if (metadata["vendor"], metadata["name"], metadata["version"]) != (
                source["vendor"], source["name"], source["version"]):
            raise ValueError("Bundled pack metadata does not match the pinned release")
        if not any(target["name"].startswith(source["requiredPrefix"]) for target in metadata["targets"]):
            raise ValueError(f"Required chip family missing: {source['requiredPrefix']}")
        metadata.pop("importedAt", None)
        metadata.update(bundled=True, sourceUrl=source["url"], sourceSha256=source["sha256"],
                        sourceSize=original.stat().st_size, compactionVersion=COMPACTION_VERSION,
                        targetPrefixes=prefixes, requiredPrefix=source["requiredPrefix"])
        records[compact_digest] = metadata
        print(f"Bundled {metadata['vendor']}.{metadata['name']} {metadata['version']}: "
              f"{metadata['targetCount']} targets, {metadata['size']} bytes "
              f"(upstream {original.stat().st_size} bytes)", flush=True)
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
    parser.add_argument("--cache-dir", type=Path,
                        default=Path(os.environ.get("TAL_PACK_CACHE_DIR", str(DEFAULT_CACHE))))
    args = parser.parse_args()
    prepare(args.output, args.lockfile, args.cache_dir)
