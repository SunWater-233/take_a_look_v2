#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_root="$project_root/backend"
backend_python="${PYTHON:-$backend_root/.venv/bin/python}"
dist_root="$backend_root/runtime"
work_root="$project_root/build/backend_pyinstaller"

if [[ ! -x "$backend_python" ]]; then
  echo "Backend Python was not found at $backend_python. Run tool/setup_backend.sh first." >&2
  exit 1
fi

"$backend_python" "$project_root/tool/prepare_bundled_packs.py"

"$backend_python" -m PyInstaller \
  --clean \
  --noconfirm \
  --onedir \
  --name take_a_look_backend \
  --distpath "$dist_root" \
  --workpath "$work_root" \
  --specpath "$work_root" \
  --paths "$backend_root" \
  --additional-hooks-dir "$backend_root/pyinstaller_hooks" \
  --collect-all pyocd \
  --collect-all cmsis_pack_manager \
  --collect-all elftools \
  --collect-submodules pylink \
  --collect-all zeroconf \
  "$backend_root/take_a_look_backend/stdio.py"

cp -a "$backend_root/bundled_packs" "$dist_root/take_a_look_backend/"

echo "Packaged backend: $dist_root/take_a_look_backend"
