"""Record the actual ABI floor and redistributable dependency notices."""

import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig


package_root = Path(sys.argv[1])
version = sys.argv[2]
flutter = sys.argv[3]
elf_requirements = {}
for path in sorted(package_root.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as stream:
        if stream.read(4) != b"\x7fELF":
            continue
    if path.name in {"libc.so.6", "libpthread.so.0", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1"}:
        raise SystemExit(f"Do not bundle the host glibc: {path}")
    output = subprocess.check_output(["readelf", "--version-info", "--wide", str(path)], text=True)
    versions = re.findall(r"\bGLIBC_(\d+\.\d+(?:\.\d+)?)\b", output)
    if versions:
        elf_requirements[str(path.relative_to(package_root))] = max(
            versions, key=lambda value: tuple(map(int, value.split(".")))
        )
minimum = max(elf_requirements.values(), key=lambda value: tuple(map(int, value.split("."))))
maximum = os.environ.get("TAL_MAX_GLIBC")
if maximum and tuple(map(int, minimum.split("."))) > tuple(map(int, maximum.split("."))):
    offenders = {name: value for name, value in elf_requirements.items()
                 if tuple(map(int, value.split("."))) > tuple(map(int, maximum.split(".")))}
    raise SystemExit(f"GLIBC floor {minimum} exceeds requested {maximum}: {offenders}")
(package_root / "runtime-requirements").write_text(f"{platform.machine()} {minimum}\n")
flutter_info = json.loads(subprocess.check_output([flutter, "--version", "--machine"], text=True))
manifest = {
    "version": version,
    "architecture": platform.machine(),
    "glibc_minimum": minimum,
    "build_os": platform.freedesktop_os_release().get("PRETTY_NAME", "Linux"),
    "source_revision": os.environ.get("SOURCE_REVISION", "unknown"),
    "source_note": "Built from the working tree, including local packaging changes.",
    "flutter": flutter_info,
    "python": platform.python_version(),
    "elf_glibc_requirements": elf_requirements,
}
(package_root / "BUILD-INFO.json").write_text(json.dumps(manifest, indent=2) + "\n")
licenses = package_root / "licenses"
licenses.mkdir(exist_ok=True)
python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
if python_license.is_file():
    shutil.copy2(python_license, licenses / "Python-LICENSE.txt")
for distribution in importlib.metadata.distributions():
    for entry in distribution.files or []:
        if re.search(r"(^|[/_.-])(licen[cs]e|copying|notice)([/_.-]|$)", str(entry), re.I):
            source = Path(distribution.locate_file(entry))
            if source.is_file() and not source.is_symlink():
                target = licenses / distribution.metadata["Name"] / str(entry).replace("../", "")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
for name in ("libusb-1.0-0", "libudev1", "libstdc++6", "libgcc-s1", "libffi7", "zlib1g"):
    copyright_file = Path("/usr/share/doc") / name / "copyright"
    if copyright_file.is_file():
        shutil.copy2(copyright_file, licenses / f"{name}-copyright")
(licenses / "README.txt").write_text(
    "Flutter/Dart dependencies: see data/flutter_assets/NOTICES.Z and FLUTTER-PACKAGES.lock.\n"
    "Python distribution notices are copied here and/or in backend/runtime/*/_internal/*.dist-info.\n"
    "Bundled libusb source: https://libusb.info/ (LGPL-2.1-or-later).\n"
    "Bundled system library sources: https://sources.debian.org/ .\n"
    "SEGGER J-Link software is not redistributed; install it separately from SEGGER if needed.\n"
)
print(f"Audited {len(elf_requirements)} ELF files; required glibc >= {minimum}")
