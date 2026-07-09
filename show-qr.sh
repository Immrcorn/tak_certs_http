#!/usr/bin/env bash
# Generate a QR code for the active TAK cert download URL.
# Uses bundled Python (same as start.sh). Prompts for format(s) or use --html/--png/--svg.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$ROOT/config.env"
  set +a
fi

PY="$(./start.sh --version 2>/dev/null | sed -n 's/^Python: \([^ ]*\) (.*/\1/p' || true)"
if [[ -z "$PY" ]]; then
  echo "ERROR: bundled Python not found (run from the full offline package)." >&2
  echo "  Try: ./start.sh --version" >&2
  echo "  Lab only: TAK_CERTS_ALLOW_SYSTEM_PYTHON=1 ./show-qr.sh" >&2
  exit 1
fi

exec "$PY" "$ROOT/gen_qr.py" --terminal "$@"
