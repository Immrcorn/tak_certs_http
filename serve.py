#!/usr/bin/env python3
"""
TAK certificate HTTP server — cookie-cutter file server for ops use.

Serves files from a certs directory so users can download dedicated
cert packages (e.g. user ZIPs / .p12) over plain HTTP.

Requires Python ≥ 3.7 (ThreadingHTTPServer, directory=, from __future__
annotations). On RHEL 8.1 stock python3 is 3.6 — use a portable CPython
or set TAK_CERTS_PYTHON (see start.sh).

Default: 0.0.0.0:18200  certs/ next to this script.
Override via env or config.env (loaded by start.sh).
"""

from __future__ import annotations

import argparse
import html
import io
import mimetypes
import os
import re
import socket
import stat
import sys
import urllib.parse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


# Common TAK / cert package types — Content-Type application/octet-stream
DOWNLOAD_EXTENSIONS = {
    ".zip",
    ".p12",
    ".pfx",
    ".pem",
    ".crt",
    ".cer",
    ".key",
    ".jks",
    ".bks",
    ".apk",
    ".tar",
    ".gz",
    ".tgz",
}

# Safe ASCII for Content-Disposition filename="..."
_SAFE_FILENAME_RE = re.compile(r"[^A-Za-z0-9._-]+")


def env_or(key: str, default: str) -> str:
    val = os.environ.get(key)
    return val if val not in (None, "") else default


def env_truthy(key: str) -> bool:
    return os.environ.get(key, "").strip().lower() in ("1", "true", "yes", "on")


def sanitize_content_disposition_filename(name: str) -> str:
    """Build a safe Content-Disposition filename token (no header injection)."""
    base = os.path.basename(name.replace("\\", "/"))
    # Strip CR/LF/controls and quotes before any further processing
    cleaned = "".join(
        ch for ch in base if ch.isprintable() and ch not in '"\\\r\n'
    ).strip()
    if not cleaned or cleaned in (".", ".."):
        return "download"
    # ASCII-safe fallback for the quoted filename= parameter
    ascii_safe = _SAFE_FILENAME_RE.sub("_", cleaned).strip("._") or "download"
    return ascii_safe[:200]


def content_disposition_header(path: str) -> str:
    """attachment with sanitized filename= and optional RFC 5987 filename*."""
    raw_base = os.path.basename(path.replace("\\", "/"))
    ascii_name = sanitize_content_disposition_filename(raw_base)
    # Prefer printable original (minus controls/quotes) for filename*
    utf8_name = "".join(
        ch for ch in raw_base if ch.isprintable() and ch not in '"\\\r\n'
    ).strip()
    if not utf8_name or utf8_name in (".", ".."):
        utf8_name = ascii_name
    header = f'attachment; filename="{ascii_name}"'
    try:
        utf8_name.encode("ascii")
        # Pure ASCII — quoted form is enough
        if utf8_name == ascii_name:
            return header
    except UnicodeEncodeError:
        pass
    # Non-ASCII or differs from sanitized form: add filename*
    encoded = urllib.parse.quote(utf8_name, safe="")
    header += f"; filename*=UTF-8''{encoded}"
    return header


def path_is_under(child: Path, parent: Path) -> bool:
    """True if child is parent or a descendant (after resolve). Uses relative_to."""
    try:
        child_r = child if child.is_absolute() else child.resolve()
        parent_r = parent if parent.is_absolute() else parent.resolve()
        # Prefer already-resolved absolute paths (caller may pass realpath results)
        child_r = Path(os.path.realpath(str(child_r)))
        parent_r = Path(os.path.realpath(str(parent_r)))
        child_r.relative_to(parent_r)
        return True
    except (ValueError, OSError):
        return False


def parse_port(raw: str, default: str = "18200") -> int:
    """Parse TCP port 1–65535; clear error instead of bare ValueError."""
    text = (raw if raw not in (None, "") else default).strip()
    try:
        port = int(text, 10)
    except (TypeError, ValueError):
        print(
            f"ERROR: invalid TAK_CERTS_PORT / --port value {raw!r} "
            f"(expected integer 1–65535).",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
    if not 1 <= port <= 65535:
        print(
            f"ERROR: port {port} out of range (valid: 1–65535).",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return port


class CertDownloadHandler(SimpleHTTPRequestHandler):
    """Directory listing + forced download for files under certs root."""

    server_version = "TAKCertHTTP/1.0"
    # Set by main() via partial; also used for containment checks
    certs_root: str = ""

    def __init__(self, *args, directory: str | None = None, **kwargs):
        if directory is not None:
            CertDownloadHandler.certs_root = os.path.realpath(directory)
        super().__init__(*args, directory=directory, **kwargs)

    def end_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def guess_type(self, path: str) -> str:
        ext = Path(path).suffix.lower()
        if ext in DOWNLOAD_EXTENSIONS:
            return "application/octet-stream"
        guessed, _ = mimetypes.guess_type(path)
        # Prefer octet-stream for unknown types to reduce inline execution risk
        return guessed or "application/octet-stream"

    def _url_has_dot_component(self) -> bool:
        """Reject path components that are '.'-prefixed (hidden) or '.' / '..' abuse."""
        # Use the URL path (not filesystem) so we catch /.hidden/foo and %2e tricks after unquote
        parts = urllib.parse.urlsplit(self.path)
        raw = urllib.parse.unquote(parts.path)
        for segment in raw.split("/"):
            if segment == "" or segment == ".":
                continue
            if segment == ".." or segment.startswith("."):
                return True
        return False

    def _resolved_under_root(self, path: str) -> str | None:
        """
        Resolve path and require it stays under certs_root.
        Returns real path string or None if outside / invalid.
        Uses path_is_under (Path.relative_to), not string startswith.
        """
        root = self.certs_root or (
            os.path.realpath(self.directory)
            if getattr(self, "directory", None)
            else None
        )
        if not root:
            return None
        try:
            real = os.path.realpath(path)
            root_real = os.path.realpath(root)
        except OSError:
            return None
        if not path_is_under(Path(real), Path(root_real)):
            return None
        return real

    def send_head(self):
        """send_head with containment, no symlinks, forced attachment downloads."""
        if self._url_has_dot_component():
            self.send_error(404, "File not found")
            return None

        # translate_path result — inspect with lstat BEFORE realpath follows links
        path = self.translate_path(self.path)
        try:
            st = os.lstat(path)
        except OSError:
            self.send_error(404, "File not found")
            return None

        # Refuse symlinks entirely (even if the target would be under certs/)
        if stat.S_ISLNK(st.st_mode):
            self.send_error(404, "File not found")
            return None

        # Containment: real path must stay under certs root
        real = self._resolved_under_root(path)
        if real is None:
            self.send_error(404, "File not found")
            return None
        path = real

        if stat.S_ISDIR(st.st_mode):
            parts = urllib.parse.urlsplit(self.path)
            if not parts.path.endswith("/"):
                self.send_response(301)
                new_parts = (
                    parts[0],
                    parts[1],
                    parts[2] + "/",
                    parts[3],
                    parts[4],
                )
                new_url = urllib.parse.urlunsplit(new_parts)
                self.send_header("Location", new_url)
                self.end_headers()
                return None
            for index in ("index.html", "index.htm"):
                index_path = os.path.join(path, index)
                try:
                    ist = os.lstat(index_path)
                except OSError:
                    continue
                if stat.S_ISLNK(ist.st_mode):
                    continue
                if stat.S_ISREG(ist.st_mode):
                    idx_real = self._resolved_under_root(index_path)
                    if idx_real is not None:
                        path = idx_real
                        break
            else:
                return self.list_directory(path)

        # Only serve regular files (re-lstat resolved path)
        try:
            st = os.lstat(path)
        except OSError:
            self.send_error(404, "File not found")
            return None
        if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
            self.send_error(404, "File not found")
            return None

        real = self._resolved_under_root(path)
        if real is None:
            self.send_error(404, "File not found")
            return None
        path = real

        ctype = self.guess_type(path)
        try:
            # O_NOFOLLOW when available — refuse opening through a race-replaced symlink
            flags = getattr(os, "O_RDONLY", 0)
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            if hasattr(os, "O_CLOEXEC"):
                flags |= os.O_CLOEXEC
            try:
                fd = os.open(path, flags)
            except OSError:
                self.send_error(404, "File not found")
                return None
            f = os.fdopen(fd, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None

        try:
            fs = os.fstat(f.fileno())
            if not stat.S_ISREG(fs.st_mode):
                f.close()
                self.send_error(404, "File not found")
                return None
            self.send_response(200)
            self.send_header("Content-type", ctype)
            self.send_header("Content-Length", str(fs.st_size))
            self.send_header(
                "Last-Modified", self.date_time_string(int(fs.st_mtime))
            )
            # Force download for all files (not only known extensions)
            self.send_header("Content-Disposition", content_disposition_header(path))
            self.end_headers()
            return f
        except Exception:
            f.close()
            raise

    def list_directory(self, path: str):
        """Clean directory index for operators / end users."""
        real = self._resolved_under_root(path)
        if real is None:
            self.send_error(404, "No permission to list directory")
            return None
        path = real

        try:
            names = os.listdir(path)
        except OSError:
            self.send_error(404, "No permission to list directory")
            return None

        names.sort(key=lambda a: a.lower())
        displaypath = html.escape(
            urllib.parse.unquote(self.path), quote=False
        )
        title = f"TAK Certificates — {displaypath}"

        rows = []
        if self.path not in ("/", ""):
            rows.append(
                '<tr><td colspan="2">'
                '<a href="../">../ (parent)</a></td></tr>'
            )

        for name in names:
            if name.startswith("."):
                continue
            full = os.path.join(path, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            # Do not list or link symlinks
            if stat.S_ISLNK(st.st_mode):
                continue
            is_dir = stat.S_ISDIR(st.st_mode)
            is_reg = stat.S_ISREG(st.st_mode)
            if not is_dir and not is_reg:
                continue
            # Ensure listing targets stay under root
            if self._resolved_under_root(full) is None:
                continue
            display_name = name + ("/" if is_dir else "")
            linkname = urllib.parse.quote(name, safe="/")
            if is_dir:
                linkname += "/"
            size = ""
            if is_reg:
                nbytes = st.st_size
                if nbytes < 1024:
                    size = f"{nbytes} B"
                elif nbytes < 1024 * 1024:
                    size = f"{nbytes / 1024:.1f} KB"
                else:
                    size = f"{nbytes / (1024 * 1024):.1f} MB"
            rows.append(
                "<tr>"
                f'<td><a href="{html.escape(linkname)}">'
                f"{html.escape(display_name)}</a></td>"
                f'<td style="text-align:right;color:#666">{html.escape(size)}</td>'
                "</tr>"
            )

        body = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>
    body {{
      font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      max-width: 52rem;
      margin: 2rem auto;
      padding: 0 1rem;
      line-height: 1.45;
      color: #1a1a1a;
    }}
    h1 {{ font-size: 1.35rem; margin-bottom: 0.25rem; }}
    .meta {{ color: #555; font-size: 0.9rem; margin-bottom: 1.25rem; }}
    table {{ width: 100%; border-collapse: collapse; }}
    td {{ padding: 0.45rem 0.35rem; border-bottom: 1px solid #e5e5e5; }}
    a {{ color: #0b5fff; text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    .hint {{
      margin-top: 1.5rem;
      padding: 0.75rem 1rem;
      background: #f4f6f8;
      border-radius: 6px;
      font-size: 0.9rem;
      color: #333;
    }}
  </style>
</head>
<body>
  <h1>TAK Certificate Downloads</h1>
  <p class="meta">Path: <code>{displaypath}</code></p>
  <table>
    <tbody>
      {"".join(rows) if rows else "<tr><td colspan='2'><em>No files yet. Drop cert packages into the certs folder.</em></td></tr>"}
    </tbody>
  </table>
  <div class="hint">
    Tap or click a file to download. Place each user’s package (ZIP / P12)
    in the server <code>certs/</code> directory. Subfolders are allowed.
    Dotfiles and symbolic links are not served.
  </div>
</body>
</html>
"""
        encoded = body.encode("utf-8", "surrogateescape")
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        return io.BytesIO(encoded)

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(
            "%s - - [%s] %s\n"
            % (self.address_string(), self.log_date_time_string(), fmt % args)
        )


def resolve_certs_dir(raw: str) -> Path:
    """
    Resolve certs directory.

    Relative paths stay under the package root (after resolve).
    Absolute paths, or relative paths that escape the package, require
    TAK_CERTS_ALLOW_EXTERNAL_DIR=1.
    """
    package_root = Path(__file__).resolve().parent
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = package_root / p
    resolved = p.resolve()

    allow_external = env_truthy("TAK_CERTS_ALLOW_EXTERNAL_DIR")
    try:
        resolved.relative_to(package_root)
        under_package = True
    except ValueError:
        under_package = False

    if not under_package and not allow_external:
        # Absolute path outside package, or relative path that escaped via ..
        print(
            f"ERROR: certs directory is outside the package root:\n"
            f"  resolved : {resolved}\n"
            f"  package  : {package_root}\n"
            f"Use a path under the package, or set TAK_CERTS_ALLOW_EXTERNAL_DIR=1\n"
            f"to serve an external directory intentionally.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    if not under_package:
        print(
            f"WARNING: serving certs outside package root (allowed by "
            f"TAK_CERTS_ALLOW_EXTERNAL_DIR): {resolved}",
            file=sys.stderr,
        )

    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Serve TAK cert packages over HTTP (cookie-cutter ops helper)."
    )
    parser.add_argument(
        "--host",
        default=env_or("TAK_CERTS_HOST", "0.0.0.0"),
        help="Bind address (default: 0.0.0.0 or TAK_CERTS_HOST)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="Listen port (default: 18200 or TAK_CERTS_PORT)",
    )
    parser.add_argument(
        "--certs-dir",
        default=env_or("TAK_CERTS_DIR", "certs"),
        help="Directory to serve (default: ./certs or TAK_CERTS_DIR)",
    )
    args = parser.parse_args()

    if sys.version_info < (3, 7):
        print(
            f"ERROR: Python ≥ 3.7 required (found {sys.version.split()[0]}). "
            "On RHEL 8.1 use portable CPython or set TAK_CERTS_PYTHON.",
            file=sys.stderr,
        )
        return 1

    # Port: CLI wins; else env; never bare int() traceback on bad env
    if args.port is not None:
        if not 1 <= args.port <= 65535:
            print(
                f"ERROR: port {args.port} out of range (valid: 1–65535).",
                file=sys.stderr,
            )
            return 1
        port = args.port
    else:
        port = parse_port(env_or("TAK_CERTS_PORT", "18200"))
    args.port = port

    certs_dir = resolve_certs_dir(args.certs_dir)
    if not certs_dir.is_dir():
        print(f"ERROR: certs directory does not exist: {certs_dir}", file=sys.stderr)
        print("Create it and drop user packages inside, then restart.", file=sys.stderr)
        return 1

    certs_real = str(certs_dir.resolve())
    CertDownloadHandler.certs_root = certs_real
    handler = partial(CertDownloadHandler, directory=certs_real)
    try:
        httpd = ThreadingHTTPServer((args.host, args.port), handler)
    except OSError as exc:
        print(f"ERROR: cannot bind {args.host}:{args.port}: {exc}", file=sys.stderr)
        return 1

    display_host = args.host
    if args.host in ("0.0.0.0", "::"):
        try:
            display_host = socket.gethostname()
        except OSError:
            display_host = "SERVER_IP"

    print("=== TAK Certificate HTTP Server ===")
    print(f"  Serving : {certs_real}")
    print(f"  Listen  : {args.host}:{args.port}")
    print(f"  URL     : http://{display_host}:{args.port}/")
    print("  Stop    : Ctrl+C")
    print("==================================")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
