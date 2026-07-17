# Troubleshooting

You are here if something failed during deployment, the server won't start, or clients cannot reach the download URL.

For the standard setup order, see [setup.md](setup.md).

---

## Common errors

### `./start.sh` exits immediately

Copy the full terminal output. Common causes:

- Missing or non-executable bundled Python
- Port 18200 already in use
- `certs/` directory missing (create it or check `TAK_CERTS_DIR`)
- `TAK_CERTS_DIR` points outside the package without `TAK_CERTS_ALLOW_EXTERNAL_DIR=1`

Run the [diagnostics checklist](#diagnostics-checklist) below.

---

### Port bind / firewall

**Port in use:**

```bash
ss -lntp | grep 18200
```

Stop the conflicting process or change `TAK_CERTS_PORT` in `config.env`.

**Firewall blocking clients (RHEL):**

```bash
sudo firewall-cmd --list-ports
sudo firewall-cmd --permanent --add-port=18200/tcp
sudo firewall-cmd --reload
```

Remember: restrict port 18200 to **trusted clients only** on your zero-trust network.

---

### Clients cannot download

1. Service running? `sudo systemctl status tak-certs-http`
2. Local HTTP works? `curl -v http://127.0.0.1:18200/` (on the server)
3. Firewall open for client subnet?
4. Client using correct host/IP and port?
5. Files present in `certs/`? `ls -la /opt/tak_certs_http/certs/`

---

### QR handout shows wrong URL

Auto-detection may pick the wrong interface on multi-homed hosts. Set a fixed URL:

```bash
# config.env
TAK_CERTS_PUBLIC_URL=http://10.1.2.3:18200/
```

Or override at generation time: `./create-qr.sh --url http://10.1.2.3:18200/`

See [qr-handouts.md](qr-handouts.md).

---

## Diagnostics checklist

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

## Logs

### Foreground smoke test (`./start.sh`)

Messages stay in that terminal. Optional capture:

```bash
./start.sh 2>&1 | tee /tmp/tak-certs.log
```

### Production (systemd)

```bash
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -f
sudo journalctl -u tak-certs-http -n 100 --no-pager
```

---

## Two scripts — common confusion

| Script | What it does | What it does **not** do |
|--------|----------------|-------------------------|
| **`./start.sh`** | Starts the HTTP server in the **foreground** (terminal stays busy). | Does **not** install software, does **not** create a systemd unit, does **not** exit on success. |
| **`./install-service.sh`** | Registers a **systemd service** — the **final production install**. | Does **not** require `/tmp`. Does **not** re-copy the tree if already at the install path. |

Leaving `./start.sh` running is a smoke test, not production. Always complete [systemd install](systemd-service.md) for deployment.

---

## Related guides

- [setup.md](setup.md) — standard deployment order
- [systemd-service.md](systemd-service.md) — final install and uninstall
- [configuration.md](configuration.md) — all settings
