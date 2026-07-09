#!/usr/bin/env bash
# TAK cert HTTP server — offline-first launcher.
# Ships with portable CPython under python/linux-*/python/ (no package manager).
# Requires Python ≥ 3.7 (serve.py). Stock RHEL 8.1 python3 is 3.6 — use the
# bundled runtime (default).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  # config.env is sourced as shell (set -a). Keep simple KEY=value tokens so
  # systemd EnvironmentFile= works too.
  set -a
  source "$ROOT/config.env"
  set +a
fi

: "${TAK_CERTS_HOST:=0.0.0.0}"
: "${TAK_CERTS_PORT:=18200}"
: "${TAK_CERTS_DIR:=certs}"

CERTS_PATH="$TAK_CERTS_DIR"
if [[ "$CERTS_PATH" != /* ]]; then
  CERTS_PATH="$ROOT/$CERTS_PATH"
fi
mkdir -p "$CERTS_PATH"

export TAK_CERTS_HOST TAK_CERTS_PORT TAK_CERTS_DIR
export TAK_CERTS_ALLOW_EXTERNAL_DIR="${TAK_CERTS_ALLOW_EXTERNAL_DIR:-}"

python_version_ok() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  "$bin" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null
}

# Resolve arch-specific portable CPython shipped with this offline package.
bundled_python_home() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      printf '%s\n' "$ROOT/python/linux-x86_64/python"
      ;;
    aarch64|arm64)
      printf '%s\n' "$ROOT/python/linux-aarch64/python"
      ;;
    *)
      return 1
      ;;
  esac
}

pick_python() {
  local candidate home py
  # Explicit override always wins
  if [[ -n "${TAK_CERTS_PYTHON:-}" ]]; then
    if python_version_ok "$TAK_CERTS_PYTHON"; then
      # Best-effort lib path if override lives next to a portable tree
      if [[ -d "$(dirname "$TAK_CERTS_PYTHON")/../lib" ]]; then
        export LD_LIBRARY_PATH="$(cd "$(dirname "$TAK_CERTS_PYTHON")/.." && pwd)/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      fi
      echo "$TAK_CERTS_PYTHON"
      return 0
    fi
    echo "ERROR: TAK_CERTS_PYTHON=$TAK_CERTS_PYTHON is missing or is not Python ≥ 3.7." >&2
    return 1
  fi
  if [[ -n "${PYTHON:-}" ]] && python_version_ok "$PYTHON"; then
    echo "$PYTHON"
    return 0
  fi

  # Offline default: bundled portable CPython for this arch
  if home="$(bundled_python_home 2>/dev/null)"; then
    py="$home/bin/python3"
    if python_version_ok "$py"; then
      export LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      echo "$py"
      return 0
    fi
    # Common alternate layout (flat python/bin)
    py="$home/bin/python"
    if python_version_ok "$py"; then
      export LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      echo "$py"
      return 0
    fi
  fi

  # Legacy flat layouts under package root
  for candidate in \
    "$ROOT/python/bin/python3" \
    "$ROOT/runtime/bin/python3" \
    "$ROOT/cpython/bin/python3" \
    "$ROOT/portable-python/bin/python3"
  do
    if python_version_ok "$candidate"; then
      base="$(cd "$(dirname "$candidate")/.." && pwd)"
      if [[ -d "$base/lib" ]]; then
        export LD_LIBRARY_PATH="${base}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      fi
      echo "$candidate"
      return 0
    fi
  done

  # Offline package: do NOT silently fall back to system python3 (often 3.6 on RHEL 8.1).
  # Allow only if TAK_CERTS_ALLOW_SYSTEM_PYTHON=1 for lab use.
  if [[ "${TAK_CERTS_ALLOW_SYSTEM_PYTHON:-}" == "1" ]]; then
    if command -v python3 >/dev/null 2>&1 && python_version_ok "$(command -v python3)"; then
      command -v python3
      return 0
    fi
    if command -v python >/dev/null 2>&1 && python_version_ok "$(command -v python)"; then
      command -v python
      return 0
    fi
  fi
  return 1
}

if [[ "${1:-}" == "--version" ]]; then
  echo "Package root: $ROOT"
  echo "Arch: $(uname -m)"
  if PY="$(pick_python)"; then
    echo "Python: $PY ($("$PY" --version 2>&1))"
    exit 0
  fi
  echo "Python: (not found)"
  exit 1
fi

if ! PY="$(pick_python)"; then
  echo "ERROR: need the bundled portable Python ≥ 3.7 (offline package)." >&2
  echo "  Expected one of:" >&2
  echo "    $ROOT/python/linux-x86_64/python/bin/python3" >&2
  echo "    $ROOT/python/linux-aarch64/python/bin/python3" >&2
  echo "  Arch on this host: $(uname -m)" >&2
  echo "  Override: TAK_CERTS_PYTHON=/path/to/python3" >&2
  echo "  Lab only: TAK_CERTS_ALLOW_SYSTEM_PYTHON=1 (requires system Python ≥ 3.7)" >&2
  if command -v python3 >/dev/null 2>&1; then
    echo "  Found system: $(command -v python3) -> $($(command -v python3) --version 2>&1 || true)" >&2
  fi
  exit 1
fi

echo "Using Python: $PY ($("$PY" --version 2>&1))"
echo "NOTE: start.sh only RUNS the download server in the foreground."
echo "      It does NOT install a systemd service."
echo "      For a persistent service (after files are in place):"
echo "        sudo ./install-service.sh $ROOT \${USER:-tak}"
echo "      Stop foreground server: Ctrl+C"
echo

exec "$PY" "$ROOT/serve.py" \
  --host "$TAK_CERTS_HOST" \
  --port "$TAK_CERTS_PORT" \
  --certs-dir "$TAK_CERTS_DIR"
