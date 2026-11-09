#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV="$ROOT/.venv/hyperliquid"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi
if ! cmp -s "$SCRIPT_DIR/requirements.txt" "$VENV/.requirements-installed"; then
  "$VENV/bin/python" -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
  cp "$SCRIPT_DIR/requirements.txt" "$VENV/.requirements-installed"
fi
exec "$VENV/bin/python" "$SCRIPT_DIR/big_blocks.py" "$@"
