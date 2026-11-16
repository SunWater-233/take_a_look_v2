#!/usr/bin/env bash
# Build from an isolated source copy, safe to invoke from a Windows checkout in WSL.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash tool/package_linux.sh [--mode release|debug] [--version <version>]

  --version  Override major.minor.patch[+build] for this build only.
             Defaults to pubspec.yaml; the source checkout is not changed.
  --mode     Build release (default) or debug packages.
  --help     Show this help.
HELP
}

die() { echo "ERROR: $*" >&2; exit 1; }
version=""
mode=release
while (( $# )); do
  case "$1" in
    --version)
      (( $# >= 2 )) || die '--version requires major.minor.patch[+build].'
      [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || die 'Invalid version; expected major.minor.patch[+build].'
      version=$2
      shift
      ;;
    --mode)
      (( $# >= 2 )) || die '--mode requires release or debug.'
      [[ "$2" == release || "$2" == debug ]] || die 'Invalid mode; expected release or debug.'
      mode=$2
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
  shift
done

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$version" ]]; then
  version="$(awk '/^version:/ {print $2; exit}' "$project_root/pubspec.yaml" | tr -d '\r')"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[0-9]+)?$ ]] || die 'Invalid package version in pubspec.yaml.'
echo "Build version: $version ($mode)"
flutter="${FLUTTER:-flutter}"
python="${PYTHON:-python3}"
output_dir="${TAL_OUTPUT_DIR:-$project_root/build/releases}/$version/linux"
source_revision="$(git -C "$project_root" rev-parse HEAD 2>/dev/null || echo unknown)"
for command in "$flutter" "$python" rsync cmake ninja clang++ pkg-config readelf tar gzip; do
  command -v "$command" >/dev/null || { echo "Missing build tool: $command" >&2; exit 1; }
done
[[ "$(uname -s)" == Linux ]] || { echo 'Build this package on Linux or in WSL.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) flutter_arch=x64 ;;
  aarch64) flutter_arch=arm64 ;;
  *) echo 'Supported native build architectures: x86_64, aarch64.' >&2; exit 1 ;;
esac
"$python" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
pkg-config --exists gtk+-3.0 libusb-1.0
mkdir -p "$output_dir"
output_dir="$(realpath "$output_dir")"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/take-a-look-build.XXXXXX")"
cleanup() {
  local result=$?
  if (( result != 0 )) || [[ "${TAL_KEEP_BUILD:-0}" == 1 ]]; then
    echo "Build files retained: $work_root"
  else
    rm -rf -- "$work_root"
  fi
}
trap cleanup EXIT
source_root="$work_root/source"
mkdir "$source_root"
rsync -a --exclude=.git --exclude=.dart_tool --exclude=.venv --exclude=build \
  --exclude=.flutter-plugins-dependencies --exclude=ephemeral --exclude=__pycache__ \
  --exclude=recordings --exclude='*.egg-info' \
  --exclude='backend/runtime/take_a_look_backend' --exclude='*.pyc' \
  "$project_root/" "$source_root/"
# Git on Windows can otherwise leave CRLF in shell scripts from older checkouts.
find "$source_root/tool" "$source_root/packaging" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
cd "$source_root"
# Keep Flutter's embedded version and the archive manifest in sync. Only this
# temporary source copy is changed, before pub get and the application build.
sed -i "s/^version:.*/version: $version/" pubspec.yaml
"$python" -m venv backend/.venv
backend_python="$source_root/backend/.venv/bin/python"
"$backend_python" -m pip install --disable-pip-version-check -e './backend[dev]'
# Flutter pins several SDK dependencies. Resolve only inside this isolated copy
# and ship the resulting lockfile; do not rewrite the Windows checkout's lock.
"$flutter" pub get
"$backend_python" -m pytest -q backend
"$flutter" analyze
"$flutter" test --reporter expanded
read -ra gtk_flags <<< "$(pkg-config --cflags --libs gtk+-3.0)"
clang++ -std=c++17 -Wall -Wextra tool/tests/linux_gpu_preference_test.cc \
  linux/runner/gpu_preference.cc "${gtk_flags[@]}" -o "$work_root/gpu-preference-test"
"$work_root/gpu-preference-test"
TAL_PACK_CACHE_DIR="$project_root/build/tools/cmsis-packs" PYTHON="$backend_python" bash tool/build_backend.sh
"$flutter" build linux "--$mode" --no-pub --target-platform "linux-$flutter_arch"
dart="$(dirname "$(readlink -f "$(command -v "$flutter")")")/dart"
"$dart" compile exe tool/update_helper.dart -o "build/linux/$flutter_arch/$mode/bundle/take_a_look_updater"
"build/linux/$flutter_arch/$mode/bundle/take_a_look_updater" --self-test

revision_tag=""
if [[ "$source_revision" != unknown ]]; then
  revision_tag="-git.${source_revision:0:7}"
fi
mode_suffix=""
if [[ "$mode" == debug ]]; then mode_suffix=-debug; fi
package_name="take-a-look-v2-$version$revision_tag-linux-$(uname -m)$mode_suffix"
package_root="$work_root/$package_name"
cp -a "build/linux/$flutter_arch/$mode/bundle" "$package_root"
cp packaging/linux/take-a-look packaging/linux/*.sh packaging/linux/*.rules "$package_root/"
cp docs/linux-install.md "$package_root/INSTALL.md"
cp docs/linux-wayland.md "$package_root/linux-wayland.md"
cp macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png "$package_root/take-a-look.png"
find "$package_root" -type d -exec chmod 755 {} +
find "$package_root" -type f -exec chmod 644 {} +
chmod 755 "$package_root/take-a-look" "$package_root/"*.sh "$package_root/take_a_look_v2" "$package_root/take_a_look_updater" \
  "$package_root/backend/runtime/take_a_look_backend/take_a_look_backend"
printf 'Take A Look V2 portable package\n' > "$package_root/.take-a-look-package"
# A frozen backend has its own ELF loader search path. Do not put its OpenSSL,
# libstdc++ or libusb libraries into the UI's LD_LIBRARY_PATH.
SOURCE_REVISION="$source_revision" \
  "$backend_python" tool/linux_package_manifest.py "$package_root" "$version" "$flutter" "$mode"
"$package_root/take-a-look" --doctor
"$backend_python" -m pip freeze --exclude-editable > "$package_root/PYTHON-PACKAGES.txt"
cp pubspec.lock "$package_root/FLUTTER-PACKAGES.lock"
"$dart" run tool/write_update_manifest.dart "$package_root" linux-archive "$version" "$flutter_arch"
archive="$output_dir/$package_name.tar.gz"
temporary_archive="$work_root/$package_name.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$temporary_archive" -C "$work_root" "$package_name"
"$backend_python" "$source_root/tool/verify_linux_package.py" "$temporary_archive"
# Publish only after the delivered archive passes its installation checks.
cp "$temporary_archive" "$archive.partial"
mv -f "$archive.partial" "$archive"
(cd "$output_dir" && sha256sum "$package_name.tar.gz" > "$package_name.tar.gz.sha256")
cp "$package_root/INSTALL.md" "$output_dir/INSTALL.md"
cp "$package_root/BUILD-INFO.json" "$output_dir/$package_name.BUILD-INFO.json"
echo "Release archive: $archive"
