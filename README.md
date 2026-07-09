# TAK Certificate HTTP Server (offline package)

**Single offline package** for TAK cert downloads on air-gapped hosts (RHEL 8.1).

**Canonical install path:** `/opt/tak_certs_http`  
(spelling: **`tak_certs_http`** — with **s** in `certs`. Paths like `/opt/tak_cert_http` are wrong and create a second empty tree.)

---

## Two different scripts (read this first)

| Script | What it does | What it does **not** do |
|--------|----------------|-------------------------|
| **`./start.sh`** | Starts the **HTTP download server** in the **foreground** (terminal stays busy). | Does **not** install software, does **not** create a systemd unit, does **not** exit on success. |
| **`./install-service.sh`** | Registers a **systemd service** so the server survives logout/reboot. Optional. | Does **not** require `/tmp`. Does **not** re-copy the tree if it is already at the install path. |

### `start.sh` success (foreground)

```text
Using Python: /opt/tak_certs_http/python/linux-x86_64/python/bin/python3 (Python 3.12.x)
NOTE: start.sh only RUNS the download server...
=== TAK Certificate HTTP Server ===
  Serving : /opt/tak_certs_http/certs
  Listen  : 0.0.0.0:18200
  URL     : http://...:18200/
  Stop    : Ctrl+C
```

The process **keeps running** — that means it is working. Open the URL from a client. Stop with **Ctrl+C**.  
If the process **exits immediately**, something failed — copy the full terminal output.

### `install-service.sh` success (systemd)

```text
Installing systemd service
  Package source : /opt/tak_certs_http
  Install target : /opt/tak_certs_http
  Run as user    : admin1
  Mode: in-place (no file copy — package is already here).
...
Done. Drop cert packages into: /opt/tak_certs_http/certs/
Service: systemctl status tak-certs-http
URL:     http://<this-host>:18200/
```

**In-place** is normal when you already `scp`’d or extracted the package under `/opt`. The installer only wires systemd + permissions.

---

## Common error: `cp: ... are the same file`

```text
Installing package -> /opt/tak_certs_http (user: admin1)
cp: '/opt/tak_certs_http/.' and '/opt/tak_certs_http/.' are the same file
```

| Fact | Detail |
|------|--------|
| Cause | Package is **already** at the install path; an **old** installer still tried to `cp` the folder onto itself. |
| Is the host broken? | **No.** |
| Is Python 3.6 the cause? | **No.** |
| Fixed package behavior | Detects same path/inode → **skips copy** → prints `Mode: in-place`. |
| What to do | Use a package with the updated `install-service.sh`, **or** finish with the [manual unit](#manual-systemd-unit-if-installer-is-old) below. |

Old installers printed `Installing package -> ...`.  
Current installers print `Installing systemd service` and `Mode: in-place` / `Mode: copy`.

---

## System Python 3.6 on RHEL 8.1

**Not a problem.** This package ships portable CPython 3.12 under `python/linux-*/`.  
`start.sh` uses that, **not** system `/usr/bin/python3`.

```bash
./start.sh --version
# must show .../python/linux-.../python/bin/python3
# NOT /usr/bin/python3
```

If `--version` errors about missing bundled Python, the `python/` tree was not copied (partial scp).

---

## Path A — Package already under `/opt` (scp or prior extract)

No `/tmp` step required. `/tmp` is only an optional place to stage a **tarball** before extract.

```bash
# Spelling: tak_certs_http (with "s")
cd /opt/tak_certs_http

# 1) Execute bits
sudo chmod +x start.sh serve.py install-service.sh
find python -type f \( -name 'python3*' -o -name 'python' \) -exec sudo chmod a+x {} \;

# 2) Confirm bundled Python (ignore system 3.6)
./start.sh --version

# 3) Edit config if needed
#    sudo vi config.env

# 4a) FOREGROUND test (server stays running — not an "install")
./start.sh
# other terminal:
#   curl -I http://127.0.0.1:18200/
# Ctrl+C to stop

# 4b) OPTIONAL: systemd service — path arg = where package ALREADY is
#    Run user must exist (e.g. admin1, or create: useradd -r -s /sbin/nologin tak)
sudo ./install-service.sh /opt/tak_certs_http admin1

# Expect: Mode: in-place (no file copy...)
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -n 50 --no-pager
```

### `install-service.sh` arguments

```bash
sudo ./install-service.sh [INSTALL_PATH] [RUN_USER]
```

| Arg | Meaning | Example |
|-----|---------|---------|
| `INSTALL_PATH` | Absolute path of the package tree (must be under `/opt` or `/srv`) | `/opt/tak_certs_http` |
| `RUN_USER` | Existing Linux user that runs the service | `admin1`, `tak`, … |

- Default path: `/opt/tak_certs_http`
- Default user: `$SUDO_USER` or `tak`
- If the script lives **inside** `INSTALL_PATH`, install is **in-place** (no `cp`/`rsync`).
- If the script lives **elsewhere** and `INSTALL_PATH` is empty/other, it **copies** the tree there, then enables the unit.

---

## Path B — Fresh extract from tarball

```bash
# optional stage:
# scp tak_certs_http-offline.tgz user@host:/tmp/

sudo tar xzf /tmp/tak_certs_http-offline.tgz -C /opt
cd /opt/tak_certs_http
sudo chmod +x start.sh serve.py install-service.sh
./start.sh --version

# Foreground:
./start.sh

# Or systemd (same as Path A):
sudo ./install-service.sh /opt/tak_certs_http admin1
```

---

## Manual systemd unit (if installer is old)

Use this when you see `cp: ... are the same file` and cannot refresh the package yet.

```bash
# Adjust User= and paths if needed
sudo tee /etc/systemd/system/tak-certs-http.service >/dev/null <<'EOF'
[Unit]
Description=TAK Certificate HTTP Download Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=admin1
WorkingDirectory=/opt/tak_certs_http
EnvironmentFile=-/opt/tak_certs_http/config.env
ExecStart=/opt/tak_certs_http/start.sh
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectHostname=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadOnlyPaths=/opt/tak_certs_http
ReadWritePaths=/opt/tak_certs_http/certs

[Install]
WantedBy=multi-user.target
EOF

sudo chown -R admin1:admin1 /opt/tak_certs_http
sudo chmod +x /opt/tak_certs_http/start.sh /opt/tak_certs_http/serve.py
find /opt/tak_certs_http/python -type f \( -name 'python3*' -o -name 'python' \) -exec sudo chmod a+x {} \;

sudo systemctl daemon-reload
sudo systemctl enable --now tak-certs-http
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -n 40 --no-pager
```

---

## Drop cert packages

```bash
sudo cp /path/to/*.zip /opt/tak_certs_http/certs/
```

No restart required for new files. Clients: `http://<host>:18200/`

---

## QR code for users

Generate a scannable download link (terminal QR + shareable files):

```bash
cd /opt/tak_certs_http
./show-qr.sh
```

When run interactively, you are prompted for which format(s) to write:

- `h` — html (browser handout)
- `p` — png (image for chat/print)
- `s` — svg (vector)

Enter one or more letters (`h`, `p`, `s`), comma-separated names, or `all`.

For scripts or non-interactive use, pass format flags (at least one required):

```bash
./show-qr.sh --png
./show-qr.sh --html --svg
```

**URL auto-detection** uses the server’s routable IP when `TAK_CERTS_HOST=0.0.0.0`.  
If auto-detect picks the wrong address, set a fixed URL in `config.env`:

```bash
TAK_CERTS_PUBLIC_URL=http://10.1.2.3:18200/
```

Or pass overrides:

```bash
./show-qr.sh --host 10.1.2.3
./show-qr.sh --url http://10.1.2.3:18200/
```

---

## Logs and diagnostics

### Foreground (`./start.sh`)

Messages stay in that terminal. Optional:

```bash
./start.sh 2>&1 | tee /tmp/tak-certs.log
```

### systemd

```bash
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -f
sudo journalctl -u tak-certs-http -n 100 --no-pager
```

### Checklist

```bash
cd /opt/tak_certs_http

# Tree complete?
ls -la start.sh serve.py config.env
ls -la python/linux-$(uname -m)/python/bin/python3

# Bundled interpreter (not system 3.6)?
./start.sh --version

# Port / firewall
ss -lntp | grep 18200 || true
sudo firewall-cmd --list-ports 2>/dev/null || true

# HTTP (while server running)
curl -v http://127.0.0.1:18200/
```

---

## config.env

| Variable | Default | Notes |
|----------|---------|--------|
| `TAK_CERTS_HOST` | `0.0.0.0` | Bind all interfaces |
| `TAK_CERTS_PORT` | `18200` | Listen port |
| `TAK_CERTS_DIR` | `certs` | Relative to package root |
| `TAK_CERTS_PYTHON` | (auto) | Override bundled interpreter only if needed |
| `TAK_CERTS_ALLOW_SYSTEM_PYTHON` | off | Do **not** enable on RHEL 8.1 (3.6 is too old) |

Keep values simple unquoted tokens (works for both `start.sh` and systemd `EnvironmentFile`).

---

## Package layout

```
tak_certs_http/
  start.sh                 # RUN server (foreground)
  show-qr.sh               # QR code + handout files for users
  install-service.sh       # INSTALL systemd unit (optional; supports in-place)
  serve.py
  gen_qr.py
  qrcodegen.py             # vendored MIT QR library (offline)
  config.env
  certs/                   # put ZIP/P12 here
  python/linux-x86_64/     # bundled CPython 3.12 (required)
  python/linux-aarch64/
  systemd/tak-certs-http.service
  README.md
  REQUIREMENTS.txt
```

Do **not** omit `python/` when scp’ing.

---

## Firewall (RHEL)

```bash
sudo firewall-cmd --permanent --add-port=18200/tcp
sudo firewall-cmd --reload
```

---

## Stop

- Foreground: **Ctrl+C**
- Service: `sudo systemctl stop tak-certs-http`

---

## Uninstall service

There is no uninstall script. To remove the systemd unit only (package files under `/opt/tak_certs_http` are left in place):

```bash
sudo systemctl stop tak-certs-http
sudo systemctl disable tak-certs-http
sudo rm /etc/systemd/system/tak-certs-http.service
sudo systemctl daemon-reload
```

Confirm removal:

```bash
systemctl status tak-certs-http
# should report "could not be found" or inactive/disabled
```

To run the server again without systemd, use `./start.sh` from the package directory.

---

## Ops checklist

1. Deploy **full** package to `/opt/tak_certs_http` (name with **s**).
2. `./start.sh --version` → bundled 3.12 under `python/linux-…`.
3. Drop user packages into `certs/`.
4. Test: `./start.sh` **or** `sudo ./install-service.sh /opt/tak_certs_http <user>`.
5. Expect **in-place** if already under `/opt` (no self-`cp`).
6. Open TCP **18200** for Zero Trust / private clients only.
7. Logs: terminal (foreground) or `journalctl -u tak-certs-http` (service).

---

## Portable Python source

Bundled from [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone)  
`cpython-3.12.13+20260623-*-unknown-linux-gnu-install_only_stripped`  
glibc builds — RHEL 8.1 (glibc 2.28) OK. Not Alpine/musl.
