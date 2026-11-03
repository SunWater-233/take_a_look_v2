#!/usr/bin/env python3
"""Shared desktop build entry point. Requires Python 3.11+, no extra packages."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = r"[0-9]+\.[0-9]+\.[0-9]+(?:\+[0-9]+)?"
KEEP_BUILD_ENTRIES = {"releases", "logs", "tools", ".desktop-build.lock", "linux-release.lock"}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--target", choices=("windows", "linux", "all"),
                        default="windows" if os.name == "nt" else "linux")
    result.add_argument("--mode", choices=("release", "debug"), default="release")
    result.add_argument("--version", help="major.minor.patch[+build]; defaults to pubspec.yaml")
    result.add_argument("--windows-package", choices=("all", "msi", "portable"), default="all")
    result.add_argument("--clean", action="store_true", help="remove old intermediates before building")
    result.add_argument("--clean-only", action="store_true", help="clean build/ without compiling")
    result.add_argument("--dry-run", action="store_true", help="print actions without changing files")
    result.add_argument("--check", action="store_true", help="check toolchains without compiling")
    result.add_argument("--skip-build", action="store_true", help="repackage the last Windows build of this mode/version")
    result.add_argument("--distribution", default=os.environ.get("TAL_WSL_DISTRO"), help="WSL distribution")
    result.add_argument("--native", action="store_true", help="use the Linux host instead of the prepared Debian chroot")
    result.add_argument("--keep-build", action="store_true", help="retain the Linux temporary build after success")
    result.add_argument("--python", default="python", help="Windows backend setup interpreter")
    result.add_argument("--flutter", default="flutter", help="Windows Flutter executable")
    result.add_argument("--vc-runtime-directory", default="", help="Windows x64 Release CRT directory")
    return result


def read_version(project: Path) -> str:
    match = re.search(r"^version:\s*([^\r\n#]+)",
                      (project / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise ValueError("pubspec.yaml has no version field")
    return match[1].strip()


def is_link(path: Path) -> bool:
    # Junctions are not reported by is_symlink() on older Python versions.
    return path.is_symlink() or bool(getattr(path.lstat(), "st_file_attributes", 0)
                                    & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def build_root(project: Path) -> Path:
    root = project.resolve() / "build"
    if (root.exists() or root.is_symlink()) and is_link(root):
        raise ValueError(f"Refusing a linked build root: {root}")
    return root


def clean_build(project: Path, *, dry_run: bool = False) -> tuple[int, int]:
    """Prune generated files in place, preserving complete acquisition directories.

    Never traverse links/junctions. All removal paths are checked within the
    resolved build root; recordings and standalone .talraw files stay in place.
    """
    root = build_root(project)
    removed_files = removed_bytes = 0
    if not root.exists():
        return 0, 0

    def retry_remove(operation):
        for attempt in range(4):
            try:
                return operation()
            except OSError as error:
                if os.name != "nt" or error.winerror not in (5, 32, 145) or attempt == 3:
                    raise
                time.sleep(0.1 * (attempt + 1))

    def remove(path: Path) -> None:
        nonlocal removed_files, removed_bytes
        if not path.is_relative_to(root) or path == root:
            raise ValueError(f"Refusing to remove outside build/: {path}")
        if path.name.lower() == "recordings" or path.suffix.lower() == ".talraw":
            return
        info = path.lstat()
        linked = is_link(path)
        if stat.S_ISDIR(info.st_mode) and not linked:
            for child in path.iterdir():
                remove(child)
            if not dry_run and not any(path.iterdir()):
                try:
                    retry_remove(path.rmdir)
                except OSError as error:
                    # A process may still use an empty directory as its CWD.
                    # Its contents are clean; retaining the directory is harmless.
                    if os.name != "nt" or error.winerror != 32 or any(path.iterdir()):
                        raise
            return
        removed_files += 1
        removed_bytes += 0 if linked else info.st_size
        if not dry_run:
            if linked and not path.is_symlink() and stat.S_ISDIR(info.st_mode):
                retry_remove(path.rmdir)
            else:
                if not linked and not info.st_mode & stat.S_IWRITE:
                    path.chmod(info.st_mode | stat.S_IWRITE)
                retry_remove(path.unlink)

    for child in root.iterdir():
        if child.name not in KEEP_BUILD_ENTRIES:
            remove(child)
    verb = "Would remove" if dry_run else "Removed"
    print(f"{verb} {removed_files:,} generated files ({removed_bytes / 1024**3:.2f} GiB).", flush=True)
    print("Kept releases/, logs/, tools/, recordings/ and *.talraw files.", flush=True)
    return removed_files, removed_bytes


@contextmanager
def build_lock(project: Path):
    root = build_root(project)
    root.mkdir(exist_ok=True)
    lock = root / ".desktop-build.lock"
    if lock.exists() and is_link(lock):
        raise ValueError(f"Refusing a linked build lock: {lock}")
    with lock.open("a+b") as stream:
        stream.seek(0, os.SEEK_END)
        if stream.tell() == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise ValueError("Another desktop build/cleanup is running for this checkout") from error
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == "nt":
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def build_commands(options, project: Path, host: str) -> list[list[str]]:
    targets = ("windows", "linux") if options.target == "all" else (options.target,)
    if "windows" in targets and host != "nt":
        raise ValueError("Windows packages require a Windows host. Use --target linux here; --target all runs on Windows with WSL.")
    if options.skip_build and ("linux" in targets or options.clean):
        raise ValueError("--skip-build requires --target windows and cannot be combined with --clean")
    if options.windows_package in ("msi", "all") and "windows" in targets:
        parts = [int(part) for part in options.version.split("+")[0].split(".")]
        if any(part > limit for part, limit in zip(parts, (255, 255, 65535))):
            raise ValueError("MSI versions must fit 0..255.0..255.0..65535")
    if "windows" in targets:
        parts = [int(part) for part in re.split(r"[.+]", options.version)]
        if any(part > 65535 for part in parts):
            raise ValueError("Windows EXE version fields must fit 0..65535")
    commands = []
    for target in targets:
        if target == "windows":
            command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                       str(project / "tool/package_windows.ps1"), "-Package", options.windows_package,
                       "-Mode", options.mode, "-Version", options.version,
                       "-Python", options.python, "-Flutter", options.flutter]
            if options.vc_runtime_directory:
                command += ["-VcRuntimeDirectory", options.vc_runtime_directory]
            if options.skip_build:
                command += ["-SkipBuild"]
            if options.check:
                command += ["-Check"]
        elif host == "nt":
            command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                       str(project / "tool/build_release_wsl.ps1"), "-Mode", options.mode,
                       "-Version", options.version]
            if options.distribution:
                command += ["-Distribution", options.distribution]
            for enabled, argument in ((options.native, "-Native"), (options.check, "-Check"),
                                      (options.keep_build, "-KeepBuild")):
                if enabled:
                    command.append(argument)
        else:
            command = ["bash", str(project / "tool/build_release_wsl.sh"),
                       "--mode", options.mode, "--version", options.version]
            for enabled, argument in ((options.native, "--native"), (options.check, "--check"),
                                      (options.keep_build, "--keep-build")):
                if enabled:
                    command.append(argument)
        commands.append(command)
    return commands


def main(argv=None) -> int:
    argument_parser = parser()
    options = argument_parser.parse_args(argv)
    try:
        if options.clean_only:
            if options.dry_run:
                clean_build(PROJECT, dry_run=True)
            else:
                with build_lock(PROJECT):
                    clean_build(PROJECT)
            return 0
        if options.check and options.clean:
            raise ValueError("--check cannot be combined with --clean")
        options.version = options.version or read_version(PROJECT)
        if not re.fullmatch(VERSION_PATTERN, options.version):
            raise ValueError("Version must use major.minor.patch[+build]")
        commands = build_commands(options, PROJECT, os.name)
        print(f"Building {options.target}, {options.mode}, version {options.version}", flush=True)
        if options.dry_run:
            if options.clean:
                clean_build(PROJECT, dry_run=True)
            for command in commands:
                print(subprocess.list2cmdline(command), flush=True)
            return 0
        for command in commands:
            if not shutil.which(command[0]):
                raise ValueError(f"Required executable not found: {command[0]}")
        with build_lock(PROJECT):
            if options.clean:
                clean_build(PROJECT)
            for command in commands:
                subprocess.run(command, cwd=PROJECT, check=True)
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        return error.returncode if isinstance(error, subprocess.CalledProcessError) else 1
    except KeyboardInterrupt:
        print("Build interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
