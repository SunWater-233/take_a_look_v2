#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
clang++ -std=c++14 -Wall -Werror \
  "$root/tool/tests/linux_window_input_test.cc" \
  "$root/plugins/tal_drag_preview/linux/window_input.cc" \
  $(pkg-config --cflags --libs gtk+-3.0) -o "$work/window-input-test"
# A window manager is required to exercise real activation and modal ownership.
xvfb-run -a -s '-screen 0 1280x800x24' bash -c '
  openbox > "$1/wm.log" 2>&1 &
  wm_pid=$!
  trap "kill $wm_pid 2>/dev/null || true" EXIT
  sleep 1
  GDK_BACKEND=x11 "$1/window-input-test"
' bash "$work"
