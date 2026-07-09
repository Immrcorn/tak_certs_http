#!/usr/bin/env bash
# Install as a systemd service on Linux TAK hosts.
# Usage (as root):
#   ./install-service.sh [/opt/tak_certs_http] [user]
#
# Defaults: install path /opt/tak_certs_http, run as current SUDO_USER or tak.
#
# DEST safety is fail-closed: path is always canonicalized (realpath or pure
# bash); never use an unnormalized string for allowlist / blacklist decisions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_RAW="${1:-/opt/tak_certs_http}"
RUN_USER="${2:-${SUDO_USER:-tak}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root (sudo ./install-service.sh)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found — use start.sh instead on non-systemd hosts." >&2
  exit 1
fi

# --- charset gates (also protects sed unit rewrite) ---
if [[ ! "$RUN_USER" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERROR: run user must match ^[A-Za-z0-9_-]+$ (got: $RUN_USER)" >&2
  exit 1
fi

if [[ ! "$DEST_RAW" =~ ^[A-Za-z0-9/_.-]+$ ]]; then
  echo "ERROR: install path has disallowed characters (use A-Za-z0-9 / _ . - only)." >&2
  echo "  got: $DEST_RAW" >&2
  exit 1
fi

if [[ "$DEST_RAW" != /* ]]; then
  echo "ERROR: install path must be absolute (got: $DEST_RAW)" >&2
  exit 1
fi

# Refuse ".." in the operator-supplied string (fail closed even if a broken
# realpath ignored it). Single "." is collapsed by canonicalize.
_reject_dotdot_segments() {
  local p="$1" seg
  while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  local _ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2206
  local -a _segs=(${p#/})
  IFS="$_ifs"
  for seg in "${_segs[@]}"; do
    if [[ "$seg" == ".." ]]; then
      echo "ERROR: install path must not contain '..' segments: $1" >&2
      return 1
    fi
  done
  return 0
}

# Pure-bash absolute path normalize: collapse //, ., and .. without following
# symlinks. Fails if .. would escape above /. Always rebuilds from segments
# (never returns the unnormalized input as a "success" fallback).
_bash_canonicalize_abs() {
  local raw="$1"
  local -a out=()
  local seg
  if [[ "$raw" != /* ]]; then
    echo "ERROR: path must be absolute: $raw" >&2
    return 1
  fi
  while [[ "$raw" == */ && "$raw" != / ]]; do raw="${raw%/}"; done
  if [[ "$raw" == / ]]; then
    printf '%s\n' "/"
    return 0
  fi
  local _ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2206
  local -a _parts=(${raw#/})
  IFS="$_ifs"
  for seg in "${_parts[@]}"; do
    if [[ -z "$seg" || "$seg" == "." ]]; then
      continue
    fi
    if [[ "$seg" == ".." ]]; then
      if [[ ${#out[@]} -eq 0 ]]; then
        echo "ERROR: path escapes filesystem root: $1" >&2
        return 1
      fi
      out=("${out[@]:0:$((${#out[@]} - 1))}")
      continue
    fi
    out+=("$seg")
  done
  if [[ ${#out[@]} -eq 0 ]]; then
    printf '%s\n' "/"
  else
    local IFS=/
    printf '/%s\n' "${out[*]}"
  fi
}

# Mandatory canonicalize for safety decisions. Prefer realpath -m (GNU/RHEL);
# else pure bash. Never fall back to the unnormalized string.
canonicalize_dest() {
  local raw="$1"
  local out=""
  if command -v realpath >/dev/null 2>&1; then
    # -m: path may not exist yet (pre-mkdir)
    if out="$(realpath -m -- "$raw" 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
    if out="$(realpath -- "$raw" 2>/dev/null)"; then
      printf '%s\n' "$out"
      return 0
    fi
    # realpath present but failed — do not fail open to raw string
    echo "ERROR: realpath failed for: $raw" >&2
    echo "  Refusing to continue without a canonical path." >&2
    return 1
  fi
  _bash_canonicalize_abs "$raw"
}

# Shared allow/deny policy for a *canonical* absolute path.
assert_dest_safe() {
  local dest="$1"
  local phase="$2" # e.g. pre-copy / pre-chown

  if [[ "$dest" != /* ]]; then
    echo "ERROR: ($phase) path is not absolute after canonicalize: $dest" >&2
    exit 1
  fi

  # Exact system roots / well-known trees (not subdirs of /opt/foo)
  case "$dest" in
    /|/boot|/bin|/sbin|/lib|/lib64|/usr|/usr/bin|/usr/sbin|/usr/lib|/usr/lib64|\
    /etc|/var|/var/log|/home|/root|/dev|/proc|/sys|/run|/tmp|/opt|/srv)
      echo "ERROR: ($phase) refusing dangerous install destination: $dest" >&2
      echo "  Use a dedicated directory such as /opt/tak_certs_http" >&2
      exit 1
      ;;
  esac

  # Must live under /opt/ or /srv/ (not merely string-prefix of unnormalized input)
  case "$dest" in
    /opt/*|/srv/*) ;;
    *)
      if [[ "${TAK_CERTS_INSTALL_FORCE:-}" != "1" ]]; then
        echo "ERROR: ($phase) install path must be under /opt or /srv (got: $dest)" >&2
        echo "  Example: sudo ./install-service.sh /opt/tak_certs_http tak" >&2
        echo "  Override only if intentional: TAK_CERTS_INSTALL_FORCE=1" >&2
        exit 1
      fi
      # FORCE still requires a canonical path free of tricks; warn loudly
      echo "WARNING: ($phase) installing outside /opt|/srv (TAK_CERTS_INSTALL_FORCE=1): $dest" >&2
      ;;
  esac
}

# Input must not rely on ".." to sneak past string allowlists before normalize
if ! _reject_dotdot_segments "$DEST_RAW"; then
  exit 1
fi

DEST="$(canonicalize_dest "$DEST_RAW")" || exit 1
assert_dest_safe "$DEST" "pre-copy"

if ! getent passwd "$RUN_USER" >/dev/null 2>&1; then
  echo "ERROR: run user '$RUN_USER' does not exist." >&2
  echo "  Create a system user first, e.g.:" >&2
  echo "    useradd -r -m -d /opt/tak_certs_http -s /sbin/nologin tak" >&2
  echo "  then re-run: sudo ./install-service.sh $DEST $RUN_USER" >&2
  exit 1
fi

# Canonicalize source too so "already at DEST" is detected even with
# trailing slashes, symlinks, or differing string forms of the same path.
ROOT_CANON="$(canonicalize_dest "$ROOT")" || ROOT_CANON="$ROOT"

echo "Installing systemd service"
echo "  Package source : $ROOT_CANON"
echo "  Install target : $DEST"
echo "  Run as user    : $RUN_USER"

mkdir -p "$DEST"

# Already-in-place: scp/extract put the tree at DEST and you run
# install-service.sh from that same directory. Never cp/rsync onto self
# (cp errors with "are the same file"; that is NOT a fatal host problem).
if [[ "$ROOT_CANON" == "$DEST" ]]; then
  echo "  Mode: in-place (no file copy — package is already here)."
else
  echo "  Mode: copy $ROOT_CANON -> $DEST"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude '.DS_Store' "$ROOT_CANON/" "$DEST/"
  else
    # Guard again in case paths compare unequal as strings but are same inode
    if [[ -e "$ROOT_CANON" && -e "$DEST" ]] \
      && [[ "$(stat -c '%d:%i' "$ROOT_CANON" 2>/dev/null || stat -f '%d:%i' "$ROOT_CANON")" \
         == "$(stat -c '%d:%i' "$DEST" 2>/dev/null || stat -f '%d:%i' "$DEST")" ]]; then
      echo "  Mode: in-place (same inode; skipping copy)."
    else
      cp -a "$ROOT_CANON/." "$DEST/"
    fi
  fi
fi

mkdir -p "$DEST/certs"

# Verify package markers before recursive chown (fail closed)
if [[ ! -f "$DEST/serve.py" || ! -f "$DEST/start.sh" ]]; then
  echo "ERROR: $DEST does not look like tak_certs_http (missing serve.py and/or start.sh)." >&2
  echo "  Refusing chown -R. Check copy failed or DEST is wrong." >&2
  exit 1
fi

# Offline package must include portable Python for at least one Linux arch
if [[ ! -x "$DEST/python/linux-x86_64/python/bin/python3" \
   && ! -x "$DEST/python/linux-aarch64/python/bin/python3" ]]; then
  echo "ERROR: offline portable Python missing under $DEST/python/linux-*/python/bin/python3" >&2
  echo "  This package is offline-only; re-copy the full tree (do not strip python/)." >&2
  exit 1
fi
# Ensure interpreter bits survived rsync/cp
find "$DEST/python" -type f \( -name 'python3*' -o -name 'python' \) -exec chmod a+x {} \; 2>/dev/null || true

# Re-canonicalize after copy (resolves symlinks if DEST itself was replaced)
DEST="$(canonicalize_dest "$DEST")" || exit 1
assert_dest_safe "$DEST" "pre-chown"

chown -R "$RUN_USER:" "$DEST" 2>/dev/null || chown -R "$RUN_USER" "$DEST"
chmod +x "$DEST/start.sh" "$DEST/serve.py" "$DEST/install-service.sh" "$DEST/show-qr.sh" "$DEST/gen_qr.py" 2>/dev/null || true

UNIT_SRC="$DEST/systemd/tak-certs-http.service"
UNIT_DST="/etc/systemd/system/tak-certs-http.service"

if [[ ! -f "$UNIT_SRC" ]]; then
  echo "ERROR: unit template missing: $UNIT_SRC" >&2
  exit 1
fi

# Escape sed replacement metacharacters (& and \)
_sed_repl_escape() {
  printf '%s' "$1" | sed -e 's/[&\\]/\\&/g'
}

DEST_SED="$(_sed_repl_escape "$DEST")"
USER_SED="$(_sed_repl_escape "$RUN_USER")"

# Optional external certs dir for systemd path sandbox
RW_PATHS="${DEST}/certs"
CFG="$DEST/config.env"
if [[ -f "$CFG" ]]; then
  _allow="$(grep -E '^TAK_CERTS_ALLOW_EXTERNAL_DIR=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  _cdir="$(grep -E '^TAK_CERTS_DIR=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  if [[ "${_allow,,}" == "1" || "${_allow,,}" == "true" || "${_allow,,}" == "yes" || "${_allow,,}" == "on" ]]; then
    if [[ -n "$_cdir" && "$_cdir" == /* ]]; then
      if [[ "$_cdir" =~ ^[A-Za-z0-9/_.-]+$ ]]; then
        _cdir_canon="$(canonicalize_dest "$_cdir" 2>/dev/null || true)"
        if [[ -n "$_cdir_canon" && "$_cdir_canon" != "$DEST" && "$_cdir_canon" != "$DEST"/* ]]; then
          RW_PATHS="${DEST}/certs ${_cdir_canon}"
          echo "NOTE: external TAK_CERTS_DIR=$_cdir_canon — adding ReadWritePaths for systemd sandbox." >&2
        fi
      fi
    fi
  fi
fi
RW_SED="$(_sed_repl_escape "$RW_PATHS")"

# Rewrite WorkingDirectory / EnvironmentFile / ExecStart / User / path hardening
sed \
  -e "s|^User=.*|User=${USER_SED}|" \
  -e "s|^WorkingDirectory=.*|WorkingDirectory=${DEST_SED}|" \
  -e "s|^EnvironmentFile=.*|EnvironmentFile=-${DEST_SED}/config.env|" \
  -e "s|^ExecStart=.*|ExecStart=${DEST_SED}/start.sh|" \
  -e "s|^ReadOnlyPaths=.*|ReadOnlyPaths=${DEST_SED}|" \
  -e "s|^ReadWritePaths=.*|ReadWritePaths=${RW_SED}|" \
  "$UNIT_SRC" > "$UNIT_DST"

systemctl daemon-reload
systemctl enable tak-certs-http.service
systemctl restart tak-certs-http.service

if ! systemctl is-active --quiet tak-certs-http.service; then
  echo "ERROR: tak-certs-http.service failed to become active." >&2
  systemctl --no-pager --full status tak-certs-http.service || true
  echo >&2
  echo "Recent logs:" >&2
  journalctl -u tak-certs-http.service -n 50 --no-pager || true
  echo >&2
  echo "Common causes: missing bundled python/ tree, bad config.env, port in use, SELinux." >&2
  echo "  Smoke-test as the service user: sudo -u $RUN_USER $DEST/start.sh --version" >&2
  echo "  If journal mentions memory protection / W^X, see README (MDWE not enabled by default)." >&2
  exit 1
fi

systemctl --no-pager --full status tak-certs-http.service || true

PORT="$(grep -E '^TAK_CERTS_PORT=' "$DEST/config.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)"
PORT="${PORT:-18200}"
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
  PORT=18200
fi

echo
echo "Done. Drop cert packages into: $DEST/certs/"
echo "Service: systemctl status tak-certs-http"
echo "URL:     http://<this-host>:${PORT}/"
