# Final production install (systemd)

You are here for the **last step of every standard deployment** — registering the server as a systemd service so it survives logout and reboot.

**Prerequisite:** Foreground smoke test passed ([setup.md](setup.md) step 5) and firewall configured. Do not skip validation with `./start.sh` first.

`./start.sh` is for smoke testing only. `install-service.sh` **is the production end state.**

---

## Run the installer

```bash
cd /opt/tak_certs_http
sudo ./install-service.sh        # defaults: /opt/tak_certs_http $SUDO_USER
sudo ./install-service.sh [INSTALL_PATH] [RUN_USER]
```

**Examples:**

```bash
sudo ./install-service.sh        # defaults: /opt/tak_certs_http, $SUDO_USER
sudo ./install-service.sh /opt/tak_certs_http admin1

```



### Arguments


| Arg            | Meaning                                                                           | Example               |
| -------------- | --------------------------------------------------------------------------------- | --------------------- |
| `INSTALL_PATH` | Absolute path of the package tree (must be under `/opt` or `/srv`, unless forced) | `/opt/tak_certs_http` |
| `RUN_USER`     | Existing Linux user that runs the service                                         | `admin1`, `tak`, …    |


- Default path: `/opt/tak_certs_http`
- Default user: `$SUDO_USER` or `tak`
- Run user must exist (`useradd -r -s /sbin/nologin tak` if needed)

---



## Expected success output

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

Verify:

```bash
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -n 50 --no-pager
```

**Installation complete** when status shows `active (running)`.

---



## Service hardening

The unit template ([systemd/tak-certs-http.service](../systemd/tak-certs-http.service)) includes RHEL 8 / systemd 239 compatible hardening:


| Directive                 | Effect                                                   |
| ------------------------- | -------------------------------------------------------- |
| `NoNewPrivileges`         | Prevents privilege escalation                            |
| `PrivateTmp`              | Isolated `/tmp`                                          |
| `ProtectSystem=strict`    | Read-only system directories                             |
| `ProtectHome`             | No access to user home dirs                              |
| `RestrictAddressFamilies` | IPv4, IPv6, Unix only                                    |
| `ReadOnlyPaths`           | Package tree read-only                                   |
| `ReadWritePaths`          | Only `certs/` writable (plus external dir if configured) |


If `TAK_CERTS_ALLOW_EXTERNAL_DIR=1` points outside the package, `install-service.sh` appends that path to `ReadWritePaths`.

---



## Logs

```bash
sudo systemctl status tak-certs-http
sudo journalctl -u tak-certs-http -f
sudo journalctl -u tak-certs-http -n 100 --no-pager
```

For smoke-test logs (foreground only), output stays in the terminal. See [troubleshooting.md](troubleshooting.md).

---



## Stop the service

```bash
sudo systemctl stop tak-certs-http
```

To run temporarily without systemd (smoke test only):

```bash
./start.sh
# Ctrl+C to stop
```

---



## Uninstall the service

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

To deploy again, re-run `sudo ./install-service.sh /opt/tak_certs_http <user>`.

---

## Related guides

- [setup.md](setup.md) — full deployment walkthrough
- [configuration.md](configuration.md) — `config.env` and external certs dir
- [troubleshooting.md](troubleshooting.md) — installer errors

