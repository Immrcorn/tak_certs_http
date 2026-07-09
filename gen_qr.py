#!/usr/bin/env python3
"""
Generate a QR code for the TAK cert download URL.

Offline-safe: uses vendored qrcodegen.py (MIT) + stdlib only.
Reads TAK_CERTS_* from the environment (config.env via show-qr.sh / start.sh).
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import subprocess
import sys
import zlib
from pathlib import Path

from qrcodegen import QrCode

PACKAGE_ROOT = Path(__file__).resolve().parent
DEFAULT_PORT = 18200


def env_or(key: str, default: str) -> str:
    val = os.environ.get(key)
    return val if val not in (None, "") else default


def parse_port(raw: str, default: str = str(DEFAULT_PORT)) -> int:
    text = (raw if raw not in (None, "") else default).strip()
    try:
        port = int(text, 10)
    except (TypeError, ValueError):
        raise SystemExit(
            f"ERROR: invalid TAK_CERTS_PORT {raw!r} (expected integer 1–65535)."
        ) from None
    if not 1 <= port <= 65535:
        raise SystemExit(f"ERROR: port {port} out of range (valid: 1–65535).")
    return port


def _udp_route_ipv4() -> str | None:
    """Pick the IPv4 address the kernel would use for outbound traffic."""
    for probe in ("8.8.8.8", "1.1.1.1", "10.255.255.255"):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect((probe, 80))
                ip = sock.getsockname()[0]
                if ip and not ip.startswith("127."):
                    return ip
        except OSError:
            continue
    return None


def _hostname_i_first() -> str | None:
    try:
        out = subprocess.check_output(
            ["hostname", "-I"],
            text=True,
            timeout=3,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None
    for ip in out.split():
        if ip and not ip.startswith("127."):
            return ip
    return None


def _hostname_resolve() -> str | None:
    try:
        name = socket.gethostname()
        for info in socket.getaddrinfo(name, None, socket.AF_INET):
            ip = info[4][0]
            if ip and not ip.startswith("127."):
                return ip
    except OSError:
        pass
    return None


def detect_public_host(bind_host: str) -> str:
    """Best-effort routable host for user-facing URLs when bound to all interfaces."""
    if bind_host not in ("0.0.0.0", "::", ""):
        return bind_host.strip("[]")
    for fn in (_udp_route_ipv4, _hostname_i_first, _hostname_resolve):
        ip = fn()
        if ip:
            return ip
    try:
        return socket.gethostname()
    except OSError:
        return "SERVER_IP"


def build_download_url(host: str, port: int) -> str:
    host = host.strip()
    if not host:
        raise SystemExit("ERROR: empty host for download URL.")
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"http://{host}:{port}/"


def resolve_download_url(
    *,
    url_override: str | None = None,
    host_override: str | None = None,
    port_override: int | None = None,
) -> str:
    if url_override:
        url = url_override.strip()
        if not url.startswith(("http://", "https://")):
            url = f"http://{url}"
        return url if url.endswith("/") else f"{url}/"

    explicit = env_or("TAK_CERTS_PUBLIC_URL", "").strip()
    if explicit:
        return explicit if explicit.endswith("/") else f"{explicit}/"

    bind_host = host_override or env_or("TAK_CERTS_HOST", "0.0.0.0")
    port = port_override if port_override is not None else parse_port(
        env_or("TAK_CERTS_PORT", str(DEFAULT_PORT))
    )
    display_host = host_override or detect_public_host(bind_host)
    return build_download_url(display_host, port)


def to_svg_str(qr: QrCode, border: int, scale: int = 8) -> str:
    if border < 0 or scale < 1:
        raise ValueError("border >= 0 and scale >= 1 required")
    modules = qr.get_size() + border * 2
    px = modules * scale
    parts: list[str] = []
    for y in range(qr.get_size()):
        for x in range(qr.get_size()):
            if qr.get_module(x, y):
                px_x = (x + border) * scale
                px_y = (y + border) * scale
                parts.append(
                    f'<rect x="{px_x}" y="{px_y}" width="{scale}" height="{scale}" fill="#000"/>'
                )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {px} {px}" width="{px}" height="{px}">
  <rect width="100%" height="100%" fill="#FFFFFF"/>
  {''.join(parts)}
</svg>
"""


def print_terminal(qr: QrCode, border: int = 2) -> None:
    for y in range(-border, qr.get_size() + border):
        line = []
        for x in range(-border, qr.get_size() + border):
            dark = qr.get_module(x, y)
            line.append("\u2588\u2588" if dark else "  ")
        print("".join(line))


def write_png(path: Path, qr: QrCode, border: int = 4, scale: int = 10) -> None:
    """Write an RGB PNG using only stdlib (zlib + struct)."""
    modules = qr.get_size() + border * 2
    width = height = modules * scale
    raw = bytearray()
    for py in range(height):
        raw.append(0)  # filter type None
        my = py // scale - border
        for px in range(width):
            mx = px // scale - border
            if 0 <= mx < qr.get_size() and 0 <= my < qr.get_size():
                dark = qr.get_module(mx, my)
            else:
                dark = False
            color = b"\x00" if dark else b"\xff"
            raw.extend(color * 3)

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        crc = zlib.crc32(body) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + body + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def write_html(path: Path, url: str, svg: str) -> None:
    safe_url = (
        url.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
    path.write_text(
        f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>TAK Certificate Downloads</title>
  <style>
    body {{
      font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      max-width: 28rem;
      margin: 2rem auto;
      padding: 0 1rem;
      text-align: center;
      line-height: 1.45;
      color: #1a1a1a;
    }}
    h1 {{ font-size: 1.35rem; }}
    .qr {{ margin: 1.25rem auto; }}
    .url {{
      word-break: break-all;
      font-size: 0.95rem;
      padding: 0.75rem;
      background: #f4f6f8;
      border-radius: 6px;
    }}
    a {{ color: #0b5fff; text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    .hint {{ color: #555; font-size: 0.9rem; margin-top: 1rem; }}
  </style>
</head>
<body>
  <h1>TAK Certificate Downloads</h1>
  <p>Scan with your phone camera, then tap the link.</p>
  <div class="qr">{svg}</div>
  <p class="url"><a href="{safe_url}">{safe_url}</a></p>
  <p class="hint">Or open the link above in a browser on the same network as this server.</p>
</body>
</html>
""",
        encoding="utf-8",
    )


def default_output_dir() -> Path:
    raw = env_or("TAK_CERTS_DIR", "certs")
    p = Path(raw).expanduser()
    if not p.is_absolute():
        p = PACKAGE_ROOT / p
    p.mkdir(parents=True, exist_ok=True)
    return p


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a QR code for the TAK cert HTTP download URL."
    )
    parser.add_argument(
        "--url",
        help="Full download URL (overrides auto-detection)",
    )
    parser.add_argument(
        "--host",
        help="Host/IP for URL when not using --url (default: auto-detect)",
    )
    parser.add_argument(
        "--port",
        type=int,
        help=f"TCP port (default: {DEFAULT_PORT} or TAK_CERTS_PORT)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="Directory for SVG/PNG/HTML output (default: certs/)",
    )
    parser.add_argument(
        "--terminal",
        action="store_true",
        help="Print ASCII QR to the terminal",
    )
    parser.add_argument(
        "--no-files",
        action="store_true",
        help="Do not write SVG/PNG/HTML files",
    )
    parser.add_argument(
        "--open",
        action="store_true",
        help="Print paths only (no auto-open; safe on headless servers)",
    )
    args = parser.parse_args()

    url = resolve_download_url(
        url_override=args.url,
        host_override=args.host,
        port_override=args.port,
    )
    qr = QrCode.encode_text(url, QrCode.Ecc.MEDIUM)
    svg = to_svg_str(qr, border=4, scale=8)

    print("=== TAK Cert Download QR ===")
    print(f"  URL : {url}")
    print("  Scan with a phone on the same network, or share the files below.")
    print("============================")

    if args.terminal or args.no_files:
        print()
        print_terminal(qr)
        print()

    if not args.no_files:
        out_dir = args.out_dir or default_output_dir()
        out_dir.mkdir(parents=True, exist_ok=True)
        svg_path = out_dir / "download-qr.svg"
        png_path = out_dir / "download-qr.png"
        html_path = out_dir / "download-qr.html"
        svg_path.write_text(svg, encoding="utf-8")
        write_png(png_path, qr)
        write_html(html_path, url, svg)
        print(f"  SVG : {svg_path}")
        print(f"  PNG : {png_path}")
        print(f"  HTML: {html_path}")
        if args.open:
            print("  (Share HTML or PNG with users.)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
