#!/usr/bin/env bash
set -euo pipefail
app_root="$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")"
prefix="$(dirname "$(dirname "$app_root")")"
if [[ "$app_root" != "$prefix/lib/take-a-look" || ! -f "$app_root/.take-a-look-package" ]]; then
  echo 'Run uninstall.sh from the installed prefix/lib/take-a-look directory.' >&2
  exit 1
fi
# Keep journals created by portable/older releases outside the removable tree.
saved_recordings=''
for recordings in recordings backend/runtime/take_a_look_backend/recordings; do
  if [[ -d "$app_root/$recordings" ]]; then
    if [[ -z "$saved_recordings" ]]; then
      mkdir -p "$prefix/share/take-a-look"
      saved_recordings="$(mktemp -d "$prefix/share/take-a-look/saved-recordings.XXXXXX")"
    fi
    mkdir -p "$saved_recordings/$recordings"
    cp -a "$app_root/$recordings/." "$saved_recordings/$recordings/"
  fi
done
if [[ -L "$prefix/bin/take-a-look" ]] &&
   [[ "$(readlink -f -- "$prefix/bin/take-a-look")" == "$app_root/take-a-look" ]]; then
  rm -- "$prefix/bin/take-a-look"
fi
desktop_file="$prefix/share/applications/com.example.take_a_look_v2.desktop"
if [[ -f "$desktop_file" ]] && grep -Fq 'Name=Take A Look V2' "$desktop_file"; then
  rm -- "$desktop_file"
fi
rm -rf -- "$app_root"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$prefix/share/applications" || true
fi
echo 'Application removed. Your workspace data and shared probe udev rules have been kept.'
if [[ -n "$saved_recordings" ]]; then printf 'Recordings saved to: %s\n' "$saved_recordings"; fi
