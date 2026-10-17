#!/usr/bin/env bash
# One-click entry point; package_linux.sh owns compilation and package validation.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash tool/build_release_wsl.sh [--version <version>] [--check] [--native] [--keep-build]

Default: discover a prepared Debian 11 chroot and its Linux Flutter SDK.
  --version     Override major.minor.patch[+build] for this build only.
                Defaults to pubspec.yaml; the source checkout is not changed.
  --check       Check the build environment without compiling.
  --native      Build with the current Linux system instead of the chroot.
  --keep-build  Keep the isolated source/build directory after success.
  --help        Show this help.

Outputs: build/releases/*.tar.gz, SHA-256 and build manifest.
Logs:    build/logs/linux-release-<timestamp>-<pid>.log

Optional Linux environment variables:
  TAL_LINUX_CACHE         Environment cache (default: ~/.cache/take-a-look-linux)
  TAL_LINUX_ROOTFS        Prepared Debian chroot (overrides discovery)
  TAL_LINUX_FLUTTER_ROOT  Linux Flutter SDK (overrides discovery)
  TAL_MAX_GLIBC          ABI limit (default: 2.31 in chroot; unset in native mode)
  FLUTTER, PYTHON        Tool overrides for --native; see docs/linux-install.md

Windows: run .\tool\build_release_wsl.ps1 [-Version <version>] [-Distribution <name>] [-Check] [-KeepBuild]
or double-click tool/build_release_wsl.cmd, which launches the PowerShell script.
TAL_NO_PAUSE=1 disables the CMD launcher's final pause.
HELP
}

die() { echo "ERROR: $*" >&2; exit 1; }
check_only=0
native=0
package_arguments=()
while (( $# )); do
  case "$1" in
    --version)
      (( $# >= 2 )) || die '--version requires major.minor.patch[+build].'
      [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || die 'Invalid version; expected major.minor.patch[+build].'
      package_arguments=(--version "$2")
      shift
      ;;
    --check) check_only=1 ;;
    --native) native=1 ;;
    --keep-build) export TAL_KEEP_BUILD=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == Linux ]] || die 'Run this script in Linux/WSL, or use tool/build_release_wsl.cmd on Windows.'
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_root="${TAL_LINUX_CACHE:-$HOME/.cache/take-a-look-linux}"
rootfs="${TAL_LINUX_ROOTFS:-}"
sdk_root="${TAL_LINUX_FLUTTER_ROOT:-}"

linux_sdk_ready() {
  [[ -x "$1/bin/flutter" && -x "$1/bin/cache/dart-sdk/bin/dart" ]]
}

discover_environment() {
  local candidate
  if [[ -z "$rootfs" ]]; then
    for candidate in "$cache_root/bullseye" /root/.cache/take-a-look-linux/bullseye /opt/take-a-look-build/debian11; do
      if [[ -x "$candidate/bin/bash" ]]; then
        rootfs=$candidate
        break
      fi
    done
  fi
  [[ -n "$rootfs" && -x "$rootfs/bin/bash" ]] || die "Prepared Debian build environment missing: ${rootfs:-$cache_root/bullseye}. See docs/linux-install.md; use --native for a configured Linux host."
  rootfs="$(realpath "$rootfs")"
  [[ "$rootfs" != / ]] || die 'TAL_LINUX_ROOTFS must not be the host root directory.'
  if [[ -z "$sdk_root" ]]; then
    for candidate in "$cache_root/flutter-3.44.9" /root/.cache/take-a-look-linux/flutter-3.44.9 "$rootfs/opt/flutter"; do
      if linux_sdk_ready "$candidate"; then
        sdk_root=$candidate
        break
      fi
    done
  fi
  [[ -n "$sdk_root" ]] || die 'Linux Flutter SDK missing. Set TAL_LINUX_FLUTTER_ROOT to a prepared Linux SDK.'
}

require_linux_sdk() {
  local dart="$1/bin/cache/dart-sdk/bin/dart"
  [[ -x "$1/bin/flutter" && -x "$dart" ]] || die "Linux Flutter SDK not ready: $1. Set TAL_LINUX_FLUTTER_ROOT to a prepared Linux SDK."
  [[ "$(od -An -tx1 -N4 "$dart" | tr -d ' \n')" == 7f454c46 ]] || die "Not a Linux Flutter SDK: $1. Do not use the Windows Flutter cache."
}

run_build() {
  if (( native )); then
    sdk_root="${sdk_root:-$cache_root/flutter-3.44.9}"
    if [[ -z "${FLUTTER:-}" && -x "$sdk_root/bin/flutter" ]]; then
      export FLUTTER="$sdk_root/bin/flutter"
    fi
    local flutter_path
    flutter_path="$(command -v "${FLUTTER:-flutter}")" || die 'Linux Flutter not found. Set FLUTTER to its bin/flutter path.'
    flutter_path="$(readlink -f "$flutter_path")"
    require_linux_sdk "$(dirname "$(dirname "$flutter_path")")"
    echo 'Build environment: native Linux (ABI requirements follow the host toolchain).'
    for command in "${PYTHON:-python3}" rsync cmake ninja clang++ pkg-config readelf tar gzip sha256sum; do
      command -v "$command" >/dev/null || die "Missing build tool: $command"
    done
    "${PYTHON:-python3}" -c 'import sys, venv; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
    pkg-config --exists gtk+-3.0 libusb-1.0 || die 'GTK 3 / libusb development libraries are missing.'
    "$flutter_path" --version
    if (( check_only )); then
      echo 'Build environment check passed.'
    else
      FLUTTER="$flutter_path" bash "$project_root/tool/package_linux.sh" "${package_arguments[@]}"
    fi
    return
  fi

  (( EUID == 0 )) || die 'The prepared chroot requires root. Use tool/build_release_wsl.ps1 on Windows, or sudo -E bash tool/build_release_wsl.sh in Linux.'
  discover_environment
  require_linux_sdk "$sdk_root"
  sdk_root="$(realpath "$sdk_root")"
  local backend_python
  if [[ -f "$rootfs/opt/tal-python-path" ]]; then
    backend_python="$(tr -d '\r\n' < "$rootfs/opt/tal-python-path")"
  else
    # The original /opt/take-a-look-build environment predates this marker.
    backend_python=/opt/python311/bin/python3.11
  fi
  [[ "$backend_python" == /* && -x "$rootfs$backend_python" ]] || die "Python missing inside $rootfs. Set /opt/tal-python-path inside the chroot to its Python 3.11+ executable."
  for command in unshare mount chroot; do
    command -v "$command" >/dev/null || die "Missing build tool: $command"
  done
  # Both the rootfs and its Flutter cache are shared between invocations.
  exec 9>"$rootfs/.take-a-look-build.lock"
  flock -n 9 || die 'Another release build is using this Debian environment.'
  echo "Build environment: $rootfs"
  echo "Linux Flutter SDK: $sdk_root"
  echo "Chroot Python: $backend_python"
  echo "Maximum allowed glibc requirement: ${TAL_MAX_GLIBC:-2.31}"

  # All mounts belong to this child namespace, including when compilation fails
  # or is interrupted. No persistent host mounts or unmount cleanup are needed.
  unshare --mount --propagation private bash -s -- "$project_root" "$rootfs" "$sdk_root" "$backend_python" "$check_only" "${package_arguments[@]}" <<'CHROOT'
set -euo pipefail
project_root=$1
rootfs=$2
sdk_root=$3
backend_python=$4
check_only=$5
shift 5
mkdir -p "$rootfs"/{proc,dev,sys,opt/flutter,workspace}
mount --bind /proc "$rootfs/proc"
mount --rbind /dev "$rootfs/dev"
mount --make-rslave "$rootfs/dev"
mount --bind /sys "$rootfs/sys"
if [[ "$sdk_root" != "$(realpath "$rootfs/opt/flutter")" ]]; then
  mount --bind "$sdk_root" "$rootfs/opt/flutter"
fi
mount --bind "$project_root" "$rootfs/workspace"
# Replace a possible symlink rather than following it outside the rootfs.
cp -L --remove-destination /etc/resolv.conf "$rootfs/etc/resolv.conf"
chroot "$rootfs" /usr/bin/env \
  -u DISPLAY -u WAYLAND_DISPLAY -u TAKE_A_LOOK_TEST_GDB \
  -u PYTHONHOME -u PYTHONPATH -u LD_LIBRARY_PATH -u VIRTUAL_ENV -u FLUTTER_ROOT \
  HOME=/root LANG=C.UTF-8 \
  PATH=/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  FLUTTER=/opt/flutter/bin/flutter PYTHON="$backend_python" \
  TAL_MAX_GLIBC="${TAL_MAX_GLIBC:-2.31}" TAL_OUTPUT_DIR=/workspace/build/releases \
  bash -s -- "$check_only" "$@" <<'BUILD'
set -euo pipefail
check_only=$1
shift
cd /workspace
for command in "$FLUTTER" "$PYTHON" rsync cmake ninja clang++ pkg-config readelf git tar gzip sha256sum; do
  command -v "$command" >/dev/null || { echo "Missing build tool: $command" >&2; exit 1; }
done
"$PYTHON" -c 'import sys, venv; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
pkg-config --exists gtk+-3.0 libusb-1.0
"$FLUTTER" --version
if [[ "$check_only" == 1 ]]; then
  echo 'Build environment check passed.'
else
  exec bash tool/package_linux.sh "$@"
fi
BUILD
CHROOT
}

command -v flock >/dev/null || die 'Missing build tool: flock (util-linux).'
mkdir -p "$project_root/build/logs"
exec 8>"$project_root/build/linux-release.lock"
flock -n 8 || die 'Another release build is running for this checkout.'
log_file="$project_root/build/logs/linux-release-$(date +%Y%m%d-%H%M%S)-$$.log"
echo "Build log: $log_file"
trap 'result=$?; if (( result != 0 )); then echo "Release build failed (exit $result). Log: $log_file" >&2; fi' EXIT
run_build 2>&1 | tee "$log_file"
if (( ! check_only )); then
  if (( native )); then
    echo "Release files: ${TAL_OUTPUT_DIR:-$project_root/build/releases}"
  else
    echo "Release files: $project_root/build/releases"
  fi
fi
