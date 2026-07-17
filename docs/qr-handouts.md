# QR handouts

You are here if the server is **installed and running** and you need scannable download links or printable handouts for end users.

This is an **optional** step after the standard deployment in [setup.md](setup.md). The primary workflow is a plain URL: `http://<host>:18200/`.

---

## When to use QR handouts


| Situation                            | Recommendation                         |
| ------------------------------------ | -------------------------------------- |
| Users on phones/tablets in the field | QR code — scan to open download page   |
| Briefing slide or printed ops sheet  | `--html` or `--png` handout            |
| Chat / email on the internal network | Share PNG or the URL directly          |
| Headless server, scripted deploy     | `--png --html` flags (non-interactive) |


If users can bookmark the URL, QR generation is optional.

---

## Quick usage

```bash
cd /opt/tak_certs_http
./create-qr.sh
```

When run interactively, you are prompted for output format(s):


| Key | Format | Use                                            |
| --- | ------ | ---------------------------------------------- |
| `h` | HTML   | Browser handout (`certs/download-qr.html`)     |
| `p` | PNG    | Image for chat/print (`certs/download-qr.png`) |
| `s` | SVG    | Vector image (`certs/download-qr.svg`)         |


Enter one or more letters (`h`, `p`, `s`), comma-separated names, or `all`.

The script also prints an ASCII QR code in the terminal.

---

## Non-interactive use

For scripts or SSH sessions without a TTY, pass format flags (at least one required):

```bash
./create-qr.sh --png
./create-qr.sh --html --svg
./create-qr.sh --terminal --no-files    # terminal QR only, no files
```

---

## URL auto-detection

By default, the download URL is built from:

1. `TAK_CERTS_PUBLIC_URL` in [config.env](../config.env) (if set), else
2. Auto-detected routable IP when `TAK_CERTS_HOST=0.0.0.0`, else
3. The configured bind host

Auto-detection probes outbound routing, `hostname -I`, and DNS resolution.

### Fix wrong auto-detected address

**Option A — config.env (persistent):**

```bash
TAK_CERTS_PUBLIC_URL=http://10.1.2.3:18200/
```

**Option B — command-line override:**

```bash
./create-qr.sh --host 10.1.2.3
./create-qr.sh --url http://10.1.2.3:18200/
```

See [configuration.md](configuration.md) for all URL-related settings.

---

## Output files

Files are written to `certs/` by default (same directory the server lists):

```
certs/download-qr.html
certs/download-qr.png
certs/download-qr.svg
```

These files are served by the HTTP server like any other file in `certs/`. Users can also open the HTML file locally.

Override output directory:

```bash
./create-qr.sh --png --out-dir /tmp/handouts
# or via gen_qr.py directly:
python3 gen_qr.py --png --out-dir /tmp/handouts
```

---

## Direct `gen_qr.py` usage

`create-qr.sh` wraps `gen_qr.py` with bundled Python and loads `config.env`. For advanced use:

```bash
PY="$(./start.sh --version 2>/dev/null | sed -n 's/^Python: \([^ ]*\) (.*/\1/p')"
"$PY" gen_qr.py --terminal --html --png --url http://10.1.2.3:18200/
```

Full flag reference: [configuration.md](configuration.md#gen_qrpy-cli).

---

## Related guides

- [setup.md](setup.md) — deploy the server first
- [configuration.md](configuration.md) — `TAK_CERTS_PUBLIC_URL` and CLI flags
- [troubleshooting.md](troubleshooting.md) — bundled Python missing

