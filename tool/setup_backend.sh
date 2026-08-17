#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_root="$project_root/backend"
python_command="${PYTHON:-python3}"

"$python_command" -m venv "$backend_root/.venv"
"$backend_root/.venv/bin/python" -m pip install --upgrade pip
"$backend_root/.venv/bin/python" -m pip install -e "$backend_root[dev]"
"$backend_root/.venv/bin/python" -m pytest -q "$backend_root"

echo "Backend environment ready: $backend_root/.venv/bin/python"
