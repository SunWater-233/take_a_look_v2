#!/usr/bin/env bash
set -euo pipefail
app_root="$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")"
if (( EUID != 0 )); then exec sudo -- bash "$app_root/install-udev.sh" "$@"; fi
if ! command -v udevadm >/dev/null 2>&1; then
  echo 'udevadm is required. USB forwarding into WSL/containers must be set up on the host.' >&2
  exit 1
fi
install -Dm644 "$app_root/60-take-a-look-probes.rules" /etc/udev/rules.d/60-take-a-look-probes.rules
udevadm control --reload-rules
echo 'Probe rules installed. Unplug and reconnect the probe in your active desktop session.'
