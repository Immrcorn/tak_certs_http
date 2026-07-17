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

# #region agent log
_agent_debug_log() {
  local hypothesis_id="$1" message="$2" data_json="$3"
  local log_file="${TAK_CERTS_DEBUG_LOG:-$ROOT/.cursor/debug-aed43a.log}"
  local ts
  ts="$(date +%s)000" 2>/dev/null || ts=0
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  [[ -n "$data_json" ]] || data_json='{}'
  printf '{"sessionId":"aed43a","runId":"%s","hypothesisId":"%s","location":"start.sh","message":"%s","data":%s,"timestamp":%s}\n' \
    "${TAK_CERTS_DEBUG_RUN:-pre-fix}" "$hypothesis_id" "$message" "$data_json" "$ts" >>"$log_file" 2>/dev/null || true
  # Also mirror to workspace path when present (Cursor debug ingest)
  if [[ "$log_file" != "/Users/corn/Projects/tak_certs_http/.cursor/debug-aed43a.log" ]]; then
    printf '{"sessionId":"aed43a","runId":"%s","hypothesisId":"%s","location":"start.sh","message":"%s","data":%s,"timestamp":%s}\n' \
      "${TAK_CERTS_DEBUG_RUN:-pre-fix}" "$hypothesis_id" "$message" "$data_json" "$ts" \
      >>"/Users/corn/Projects/tak_certs_http/.cursor/debug-aed43a.log" 2>/dev/null || true
  fi
}
# #endregion

python_version_ok() {
  local bin="$1"
  local probe_err rc=0
  # #region agent log
  local exists=0 executable=0
  [[ -e "$bin" ]] && exists=1
  [[ -x "$bin" ]] && executable=1
  # #endregion
  [[ -x "$bin" ]] || {
    # #region agent log
    _agent_debug_log "A" "python_version_ok not executable" "{\"bin\":\"$bin\",\"exists\":$exists,\"executable\":$executable}"
    # #endregion
    return 1
  }
  # Capture probe failure reason (normally discarded)
  probe_err="$("$bin" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 7) else 1)' 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    # #region agent log
    probe_err="${probe_err//$'\n'/; }"
    probe_err="${probe_err//\"/\'}"
    _agent_debug_log "B_E" "python_version_ok probe failed" "{\"bin\":\"$bin\",\"rc\":$rc,\"err\":\"$probe_err\",\"ld\":\"${LD_LIBRARY_PATH:-}\"}"
    # #endregion
    return 1
  fi
  # #region agent log
  _agent_debug_log "A" "python_version_ok ok" "{\"bin\":\"$bin\"}"
  # #endregion
  return 0
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
  local home py with_ld_err with_ld_rc
  # #region agent log
  _agent_debug_log "C_D" "pick_python start" "{\"root\":\"$ROOT\",\"arch\":\"$(uname -m)\",\"uname_s\":\"$(uname -s)\",\"x86_tree\":$([ -d "$ROOT/python/linux-x86_64/python/bin" ] && echo 1 || echo 0),\"aarch_tree\":$([ -d "$ROOT/python/linux-aarch64/python/bin" ] && echo 1 || echo 0)}"
  # #endregion
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

  # Offline default: the bundled portable CPython binary for this arch.
  # The package ships only the real interpreter (python3.12) — no python/python3
  # symlinks — so this is the single source of truth.
  if home="$(bundled_python_home 2>/dev/null)"; then
    py="$home/bin/python3.12"
    # #region agent log
    with_ld_rc=0
    if [[ -x "$py" ]]; then
      with_ld_err="$(LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$py" -c 'import sys; print(sys.version)' 2>&1)" || with_ld_rc=$?
      with_ld_err="${with_ld_err//$'\n'/; }"
      with_ld_err="${with_ld_err//\"/\'}"
      _agent_debug_log "B" "probe with LD_LIBRARY_PATH" "{\"py\":\"$py\",\"rc\":$with_ld_rc,\"out\":\"$with_ld_err\"}"
    fi
    # #endregion
    if python_version_ok "$py"; then
      export LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      echo "$py"
      return 0
    fi
  else
    # #region agent log
    _agent_debug_log "C" "bundled_python_home failed" "{\"arch\":\"$(uname -m)\"}"
    # #endregion
  fi

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
  # #region agent log
  _agent_debug_log "A_E" "pick_python exhausted" "{\"allow_system\":\"${TAK_CERTS_ALLOW_SYSTEM_PYTHON:-}\"}"
  # #endregion
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
  # #region agent log
  _agent_debug_log "A_E" "version cmd not found" "{}"
  # #endregion
  exit 1
fi

if ! PY="$(pick_python)"; then
  # #region agent log
  _agent_debug_log "A_E" "start failed no python" "{}"
  # #endregion
  echo "ERROR: need the bundled portable Python ≥ 3.7 (offline package)." >&2
  echo "  Expected one of:" >&2
  echo "    $ROOT/python/linux-x86_64/python/bin/python3.12" >&2
  echo "    $ROOT/python/linux-aarch64/python/bin/python3.12" >&2
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
