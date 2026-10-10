#!/usr/bin/env bash
set -euo pipefail

# Called explicitly, or by install.sh when the runtime's ldd check fails.
as_root() {
  if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
}

if command -v pacman >/dev/null 2>&1; then
  # Arch does not support partial upgrades: refresh and upgrade together.
  as_root pacman -Syu --needed gtk3 libglvnd libusb systemd-libs xdg-utils
elif command -v apt-get >/dev/null 2>&1; then
  as_root apt-get update
  gtk_package=libgtk-3-0
  if apt-cache show libgtk-3-0t64 >/dev/null 2>&1; then gtk_package=libgtk-3-0t64; fi
  as_root apt-get install -y "$gtk_package" libgl1 libegl1 libstdc++6 libusb-1.0-0 libudev1 xdg-utils
elif command -v dnf >/dev/null 2>&1; then
  as_root dnf install -y gtk3 libglvnd-glx libglvnd-egl libstdc++ libusb1 systemd-libs xdg-utils
elif command -v zypper >/dev/null 2>&1; then
  as_root zypper install -y libgtk-3-0 libGL1 libEGL1 libstdc++6 libusb-1_0-0 libudev1 xdg-utils
else
  echo 'Install GTK 3, GL/EGL, libstdc++, libusb 1.0, libudev and xdg-utils using your distribution package manager.' >&2
  exit 1
fi
echo 'For a Wayland desktop, also enable/install XWayland (Arch: xorg-xwayland).'
