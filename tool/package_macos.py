#!/usr/bin/env python3
"""Build a native, ad-hoc signed macOS app with its independent hardware backend."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from build import VERSION_PATTERN, read_version

PROJECT = Path(__file__).resolve().parents[1]


def run(*arguments, cwd=None, env=None, capture=False):
    print("+ " + " ".join(map(str, arguments)), flush=True)
    return subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def copy_sources(destination: Path) -> None:
    names = subprocess.check_output(
        ["git", "-C", str(PROJECT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    ).decode("utf-8").split("\0")
    for name in sorted(set(filter(None, names))):
        relative = Path(name)
        if any(part in ("build", "recordings", ".venv", ".dart_tool", "ephemeral", "__pycache__")
               or part.startswith("pytest-of-") for part in relative.parts) or relative.suffix == ".talraw":
            continue
        source = PROJECT / relative
        if not source.is_file():
            continue
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, output)


def patch_macos_project(source: Path, architecture: str, version: str) -> Path:
    pubspec = source / "pubspec.yaml"
    embedded_version = version if "+" in version else version + "+0"
    text, count = re.subn(r"(?m)^version:\s*[^\r\n]+", f"version: {embedded_version}", pubspec.read_text(encoding="utf-8"), count=1)
    if not count:
        raise ValueError("pubspec.yaml has no version field")
    pubspec.write_text(text, encoding="utf-8")
    native = "arm64" if architecture == "arm64" else "x86_64"
    excluded = "x86_64" if architecture == "arm64" else "arm64"
    config = source / "macos/Runner/Configs/AppInfo.xcconfig"
    with config.open("a", encoding="utf-8") as stream:
        stream.write(f"\nARCHS = {native}\nEXCLUDED_ARCHS = {excluded}\nONLY_ACTIVE_ARCH = YES\n")
    # Direct-distribution builds launch a frozen backend and access USB probes.
    # Change only the isolated copy; existing development/App Store settings stay intact.
    for name in ("Release.entitlements", "DebugProfile.entitlements"):
        path = source / "macos/Runner" / name
        with path.open("rb") as stream:
            values = plistlib.load(stream)
        values["com.apple.security.app-sandbox"] = False
        with path.open("wb") as stream:
            plistlib.dump(values, stream)
    return source / "macos/Runner"


def publish(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    destination = output / source.name
    partial = output / (source.name + ".partial")
    shutil.copy2(source, partial)
    os.replace(partial, destination)
    with destination.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if source.suffix in (".zip", ".dmg"):
        Path(str(destination) + ".sha256").write_text(f"{digest}  {source.name}\n", encoding="ascii")
    print(f"Published: {destination}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("release", "debug"), default="release")
    parser.add_argument("--version")
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--keep-build", action="store_true")
    options = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("macOS packages require a macOS host")
    version = options.version or read_version(PROJECT)
    if not re.fullmatch(VERSION_PATTERN, version):
        parser.error("Version must use major.minor.patch[+build]")
    architecture = {"arm64": "arm64", "x86_64": "x64"}.get(platform.machine())
    if architecture is None:
        parser.error("Supported macOS hosts: arm64, x86_64")
    flutter = shutil.which(options.flutter)
    if not flutter:
        parser.error("Flutter was not found")
    for command in ("git", "xcodebuild", "codesign", "ditto", "hdiutil", "lipo", "otool"):
        if not shutil.which(command):
            parser.error(f"Missing build tool: {command}")
    run("xcodebuild", "-version")
    run(flutter, "--version")
    if options.check:
        return
    temporary = Path(tempfile.mkdtemp(prefix="take-a-look-macos-"))
    succeeded = False
    try:
        source = temporary / "source"
        source.mkdir()
        copy_sources(source)
        entitlements = patch_macos_project(source, architecture, version)
        run(sys.executable, "-m", "venv", source / "backend/.venv")
        python = source / "backend/.venv/bin/python"
        run(python, "-m", "pip", "install", "--disable-pip-version-check", "-e", "./backend[dev]", cwd=source)
        run(python, "-m", "pytest", "-q", "backend", cwd=source)
        # Reuse the checked pack cache; the preparation tool verifies every digest.
        run(python, PROJECT / "tool/prepare_bundled_packs.py")
        shutil.copytree(PROJECT / "backend/bundled_packs", source / "backend/bundled_packs")
        environment = {**os.environ, "PYTHON": str(python)}
        run("bash", "tool/build_backend.sh", cwd=source, env=environment)
        run(flutter, "pub", "get", cwd=source)
        run(flutter, "build", "macos", f"--{options.mode}", "--no-pub", cwd=source)
        configuration = "Debug" if options.mode == "debug" else "Release"
        apps = list((source / f"build/macos/Build/Products/{configuration}").glob("*.app"))
        if len(apps) != 1:
            raise ValueError(f"Expected one macOS app, found {apps}")
        app = apps[0]
        resources = app / "Contents/Resources"
        backend = resources / "backend"
        shutil.copytree(source / "backend/runtime", backend / "runtime", symlinks=True)
        shutil.copy2(source / "backend/pyproject.toml", backend / "pyproject.toml")
        # Include notices and dependency records in the delivered bundle.
        (resources / "PYTHON-PACKAGES.txt").write_text(run(python, "-m", "pip", "freeze", capture=True), encoding="utf-8")
        shutil.copy2(source / "pubspec.lock", resources / "FLUTTER-PACKAGES.lock")
        info = {"version": version, "build_mode": options.mode, "architecture": architecture,
                "source_revision": run("git", "-C", PROJECT, "rev-parse", "HEAD", capture=True).strip(),
                "python": platform.python_version(), "signing": "ad-hoc", "notarized": False}
        (resources / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
        run("xattr", "-cr", app)
        from verify_macos_package import macho_files, verify_app
        for binary in macho_files(backend):
            run("codesign", "--force", "--sign", "-", "--timestamp=none", binary)
        run("codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", "--entitlements",
            entitlements / ("DebugProfile.entitlements" if options.mode == "debug" else "Release.entitlements"), app)
        verify_app(app, architecture, version, options.mode)
        suffix = "-debug" if options.mode == "debug" else ""
        name = f"Take-A-Look-V2-{version}-macos-{architecture}{suffix}"
        archive = temporary / (name + ".zip")
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        verification = temporary / "relocated package 中文"
        run("ditto", "-x", "-k", archive, verification)
        verify_app(verification / app.name, architecture, version, options.mode)
        image_source = temporary / "disk-image"
        image_source.mkdir()
        shutil.copytree(app, image_source / app.name, symlinks=True)
        (image_source / "Applications").symlink_to("/Applications", target_is_directory=True)
        shutil.copy2(PROJECT / "docs/macos-install.md", image_source / "INSTALL.md")
        image = temporary / (name + ".dmg")
        run("hdiutil", "create", "-volname", "Take A Look V2", "-srcfolder", image_source,
            "-format", "UDZO", "-ov", image)
        mountpoint = temporary / "mounted-image"
        mountpoint.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mountpoint, image)
        try:
            verify_app(mountpoint / app.name, architecture, version, options.mode)
        finally:
            run("hdiutil", "detach", mountpoint)
        output = PROJECT / "build/releases" / version / "macos"
        publish(archive, output)
        publish(image, output)
        manifest = temporary / (name + ".BUILD-INFO.json")
        shutil.copy2(resources / "BUILD-INFO.json", manifest)
        publish(manifest, output)
        succeeded = True
    finally:
        if succeeded and not options.keep_build:
            shutil.rmtree(temporary)
        else:
            print(f"Build files retained: {temporary}", flush=True)


if __name__ == "__main__":
    main()
