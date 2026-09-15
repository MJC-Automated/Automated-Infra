#!/usr/bin/env bash
# Shell wrapper for generating reproducible k8s aggregate inventory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || command -v python || true)"

if [ -z "${PYTHON_BIN}" ]; then
  echo "Error: Python 3 is required to run generate-k8s-inventory.py" >&2
  exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/generate-k8s-inventory.py" "$@"
