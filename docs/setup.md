# Setup guide

Only deploy the TAK Certificate HTTP Server on a Linux host in a **private zero-trust or air-gapped network**.

This guide assumes the canonical install path `/opt/tak_certs_http`. All steps after `cd` into that directory are the same regardless of how the package arrived on the host.

---

## Prerequisites

- **OS:** RHEL 8.1+ or any glibc Linux distro (not Alpine/musl)
- **Network:** TCP port **18200** reachable only by authorized clients on your trusted network
- **Package:** Full offline tree including `python/` (see [troubleshooting](troubleshooting.md) if missing)
- **Root/sudo:** Required for firewall, final install, and copying certs into `certs/`

---



## Getting the package

**From GitHub:** clone or download this repository / release tarball. Transfer the **entire tree** to the Linux host and place it at `/opt/tak_certs_http`.

```bash
# scp the tarball to the host and extract into /opt
scp tak_certs_http.tgz user@host:~/
sudo tar xzf ~/tak_certs_http.tgz -C /opt
cd /opt/tak_certs_http
```

---



## Standard setup



### Step 1 — Permissions

```bash
cd /opt/tak_certs_http
# This command gives you appropriate permissions to run the scripts
sudo chmod +x start.sh serve.py install-service.sh create-qr.sh gen_qr.py
# This command gives the bundled interpreter permission to run
sudo chmod a+x python/linux-*/python/bin/python3.12
```



### Step 2 — Configure

Edit `config.env` if you need a non-default port, bind address, or public URL for QR handouts:

```bash
sudo vi config.env
```

RECOMMENDED: Full reference: [configuration.md](configuration.md).

### Step 3 — Add cert packages

Copy pre-built user packages into `certs/`. No server restart is needed when adding files later.

```bash
sudo cp /path/to/*.zip /opt/tak_certs_http/certs/
```

Supported types include `.zip`, `.p12`, `.pfx`, `.pem`, `.crt`, and others — see [configuration.md](configuration.md).

Clients will browse: `http://<host>:18200/`

### Step 4 — Validate (foreground smoke test)

Start the server in the **foreground** to confirm everything works:

```bash
./start.sh
```

Expected output:

```text
Using Python: /opt/tak_certs_http/python/linux-x86_64/python/bin/python3.12 (Python 3.12.x)
NOTE: start.sh only RUNS the download server...
=== TAK Certificate HTTP Server ===
  Serving : /opt/tak_certs_http/certs
  Listen  : 0.0.0.0:18200
  URL     : http://...:18200/
  Stop    : Ctrl+C
```

The process **keeps running** — that means it is working. In **another terminal**:

```bash
curl -I http://127.0.0.1:18200/
```

Or from a browser with access to host IP:

```
http://<host.ip.addr.ess:port/
```

If the process **exits immediately**, something failed — copy the full terminal output and see [troubleshooting](troubleshooting.md).

When satisfied, return to the server terminal and press **Ctrl+C**. This stops the smoke test.

### Step 5 — Final install (required)

Register the systemd service. This is the **production deployment step**:

```bash
sudo ./install-service.sh /opt/tak_certs_http admin1
```

Replace `admin1` with your run user. Full detail: [systemd-service.md](systemd-service.md).

Expected output includes:

```text
Installing systemd service
  ...
  Mode: in-place (no file copy — package is already here).
...
Done. Drop cert packages into: /opt/tak_certs_http/certs/
Service: systemctl status tak-certs-http
URL:     http://<this-host>:18200/
```

Verify:

```bash
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -n 50 --no-pager
```

**Installation complete** when `systemctl status` shows `active (running)`.

### Step 6 — Optional: user handouts

After the service is running, generate QR codes or printable handouts:

```bash
./create-qr.sh --png
```

See [qr-handouts.md](qr-handouts.md).

---



## Success criteria


| Milestone             | How you know                                                                       |
| --------------------- | ---------------------------------------------------------------------------------- |
| Smoke test passed     | `./start.sh` stays running; `curl -I http://127.0.0.1:18200/` returns HTTP headers |
| Installation complete | `sudo systemctl status tak-certs-http` shows **active (running)**                  |
| Users can download    | Browser or ATAK client reaches `http://<host>:18200/` from the trusted network     |


---



## Ops checklist

1. Deploy **full** package to `/opt/tak_certs_http` (name with **s**).
2. `./start.sh --version` → bundled 3.12 under `python/linux-…`.
3. Drop user packages into `certs/`.
4. Smoke test: `./start.sh` → `curl -I` → **Ctrl+C**.
5. Final install: `sudo ./install-service.sh /opt/tak_certs_http <user>`.
6. Expect **in-place** if already under `/opt` (no self-`cp`).
7. Open TCP **18200** for zero-trust / private clients only.
8. Logs: `journalctl -u tak-certs-http` (production) or terminal (smoke test only).

---



## Related guides

- [systemd-service.md](systemd-service.md) — final install details, stop, uninstall
- [configuration.md](configuration.md) — all settings
- [qr-handouts.md](qr-handouts.md) — end-user download links
- [troubleshooting.md](troubleshooting.md) — errors and diagnostics

