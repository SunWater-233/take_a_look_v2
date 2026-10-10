#!/usr/bin/env bash
set -euo pipefail
app_root="$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")"
prefix="${HOME}/.local"
install_deps=1
install_udev=0
while (( $# )); do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || exit 2; prefix="$2"; shift 2 ;;
    --system) prefix=/usr/local; shift ;;
    --no-deps) install_deps=0; shift ;;
    --udev) install_udev=1; shift ;;
    --help|-h)
      echo 'Usage: ./install.sh [--prefix DIR | --system] [--no-deps] [--udev]'
      echo 'Default: install for the current user in ~/.local; install missing OS dependencies.'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
prefix="$(realpath -m -- "$prefix")"
destination="$prefix/lib/take-a-look"
desktop_dir="$prefix/share/applications"

"$app_root/take-a-look" --check-platform
if ! "$app_root/take-a-look" --check-libs; then
  if (( install_deps )); then "$app_root/install-deps.sh"; fi
  "$app_root/take-a-look" --check-libs
fi
"$app_root/take-a-look" --doctor

if [[ "$app_root" != "$destination" ]]; then
  if [[ -e "$destination" && ! -f "$destination/.take-a-look-package" ]]; then
    echo "Refusing to replace an unrecognized directory: $destination" >&2; exit 1
  fi
  if [[ -e "$prefix/bin/take-a-look" || -L "$prefix/bin/take-a-look" ]]; then
    if [[ ! -L "$prefix/bin/take-a-look" ]] ||
       [[ "$(readlink -f -- "$prefix/bin/take-a-look")" != "$destination/take-a-look" ]]; then
      echo "An unrelated command already exists: $prefix/bin/take-a-look" >&2; exit 1
    fi
  fi
  mkdir -p "$prefix/lib" "$prefix/bin" "$desktop_dir"
  stage="$(mktemp -d "$prefix/lib/.take-a-look-install.XXXXXX")"
  trap '[[ -z "${stage:-}" ]] || rm -rf -- "$stage"' EXIT
  cp -a "$app_root/." "$stage/"
  # Only replace this application's marked installation, after the copy succeeds.
  if [[ -e "$destination" ]]; then
    backup="$(mktemp -d "$prefix/lib/.take-a-look-backup.XXXXXX")"
    rmdir "$backup"
    mv -- "$destination" "$backup"
    if ! mv -- "$stage" "$destination"; then
      mv -- "$backup" "$destination"
      exit 1
    fi
    rm -rf -- "$backup"
  else
    mv -- "$stage" "$destination"
  fi
  stage=''
  ln -sfn -- "$destination/take-a-look" "$prefix/bin/take-a-look"
fi

# Desktop Exec uses its own quoting rules, not shell quoting; escape twice where
# required by the desktop-entry specification (including literal % field codes).
desktop_exec="$destination/take-a-look"
desktop_exec="${desktop_exec//\\/\\\\\\\\}"
desktop_exec="${desktop_exec//\"/\\\\\"}"
desktop_exec="${desktop_exec//\$/\\\\\$}"
desktop_exec="${desktop_exec//\`/\\\\\`}"
desktop_exec="${desktop_exec//%/%%}"
icon_path="${destination//\\/\\\\}/take-a-look.png"
mkdir -p "$desktop_dir"
cat > "$desktop_dir/com.example.take_a_look_v2.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Take A Look V2
Comment=Embedded real-time tuning workstation
Exec="$desktop_exec"
Icon=$icon_path
Terminal=false
Categories=Development;Electronics;
StartupWMClass=com.example.take_a_look_v2
EOF
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$desktop_dir" || true
fi
if (( install_udev )); then "$destination/install-udev.sh"; fi
printf '\nInstalled: %s\nLaunch from the application menu or run: %s\n' "$destination" "$prefix/bin/take-a-look"
printf 'Uninstall: %s/uninstall.sh\n' "$destination"
