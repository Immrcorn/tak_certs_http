# TAK Certificate HTTP Server

An **offline, self-contained HTTP file server** for distributing TAK certificate packages on **private zero-trust networks** — air-gapped hosts, disconnected VLANs, and environments where you cannot rely on the internet, package managers, or modern system Python.

Drop pre-built cert packages (ZIP, P12, etc.) into a folder; users download them from a browser at `http://<host>:18200/`. 

The package ships bundled CPython 3.12 and needs no pip, yum, or outbound connectivity.

**Canonical install path:** `/opt/tak_certs_http`

---

## Best used for

- Distributing **pre-built user cert packages** on air-gapped TAK Server networks
- **Field device onboarding** via browser download on a private VLAN
- Ops handoff when email, or one-off USB side loading does not scale
- RHEL 8.1+ hosts where stock Python is 3.6 and cannot run the server directly



## What this is not

- **Not** a Certificate Authority — certs are generated elsewhere (e.g. TAK Server CA)
- **Not** TAK enrollment or a cert-signing API
- **Not** TLS-terminated HTTPS — plain HTTP on a trusted internal network by design

Restrict port **18200** to authorized clients only (firewall / network segmentation).

---



## How it works

```text
  Operator                         End user (phone / ATAK)
     │                                      │
     │  1. Drop P12 into certs/             │
     │  2. Validate with ./start.sh         │
     │  3. Final install (systemd)          │
     │                                      │
     └──────── HTTP :18200 ────────────────►│ browser → download
```

1. Place cert packages in `certs/`
2. Edit the "TAK_CERTS_HOST=0.0.0.0" in config.env to your your cloud IP address. (e.g. TAK_CERTS_HOST=100.96.30.123)
3. **Validate** with `./start.sh` (foreground smoke test), then stop with Ctrl+C
4. **Final install** with `./install-service.sh` (systemd — survives logout/reboot)
5. Run show_qr.sh
6. Users browse or scan a QR code to download

See [docs/setup.md](docs/setup.md) for the full walkthrough.

---



## Getting the package

**From GitHub:** clone or download this repository / release tarball. Transfer the **entire tree** to the target host via scp, sneakernet, or internal file share.

Make sure you place the `tak_certs_http/` folder into the `/opt/` directory.

```bash
# Example: copy full tree to target host
scp -r tak_certs_http/ user@host:/opt/
```

---



## Choose your starting point


| You are…                                             | Go to                                                            |
| ---------------------------------------------------- | ---------------------------------------------------------------- |
| Browsing on GitHub, evaluating the tool              | Read this page, then [docs/setup.md](docs/setup.md)              |
| Package already on the host at `/opt/tak_certs_http` | [docs/setup.md#already-deployed](docs/setup.md#already-deployed) |
| Holding a `.tgz` on the host, not extracted yet      | [docs/setup.md#extract-tarball](docs/setup.md#extract-tarball)   |
| Install complete, need user handouts                 | [docs/qr-handouts.md](docs/qr-handouts.md)                       |
| Ready for the final systemd install step             | [docs/systemd-service.md](docs/systemd-service.md)               |
| Something failed                                     | [docs/troubleshooting.md](docs/troubleshooting.md)               |


---



## Quick start

Full detail: [docs/setup.md](docs/setup.md).

1. **Deploy** the full package to `/opt/tak_certs_http`
2. **Permissions** — `chmod +x` scripts; make bundled Python executable (see setup guide)
3. **Verify Python** — `./start.sh --version` must show bundled 3.12 under `python/linux-…`, not `/usr/bin/python3`
4. **Configure** — edit [config.env](config.env) if needed ([docs/configuration.md](docs/configuration.md))
5. **Add certs** — `sudo cp /path/to/*.zip /opt/tak_certs_http/certs/`
6. **Validate** — `./start.sh`, then in another terminal `curl -I http://127.0.0.1:18200/`; stop with **Ctrl+C** (smoke test only, not production)
7. **Firewall** — open TCP 18200 for trusted clients only
8. **Final install** — `sudo ./install-service.sh /opt/tak_certs_http <user>`

*Optional after install:* QR handouts for end users — [docs/qr-handouts.md](docs/qr-handouts.md)

---



## Scripts at a glance


| Script               | Role                                                                      |
| -------------------- | ------------------------------------------------------------------------- |
| `start.sh`           | Foreground smoke test / temporary run — **not** the production end state  |
| `install-service.sh` | **Final production install** — registers systemd service `tak-certs-http` |
| `create-qr.sh`       | Optional — generate scannable download links and handout files            |



| Module      | Role                                               |
| ----------- | -------------------------------------------------- |
| `serve.py`  | HTTP server (invoked by `start.sh`)                |
| `gen_qr.py` | QR / handout generator (invoked by `create-qr.sh`) |


---



## Documentation


| Guide                                              | Contents                          |
| -------------------------------------------------- | --------------------------------- |
| [docs/setup.md](docs/setup.md)                     | Full deployment walkthrough       |
| [docs/systemd-service.md](docs/systemd-service.md) | Final install, logging, uninstall |
| [docs/configuration.md](docs/configuration.md)     | `config.env` and CLI reference    |
| [docs/qr-handouts.md](docs/qr-handouts.md)         | QR codes and user handouts        |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common errors and diagnostics     |


---



## Package layout

```
tak_certs_http/
  start.sh                 # foreground smoke test
  install-service.sh       # final production install (systemd)
  create-qr.sh             # optional QR handouts
  serve.py
  gen_qr.py
  qrcodegen.py             # vendored MIT QR library (offline)
  config.env
  certs/                   # drop ZIP/P12 here
  docs/                    # guides (this README links here)
  python/linux-x86_64/     # bundled CPython 3.12 (required)
  python/linux-aarch64/
  systemd/tak-certs-http.service
  README.md
  REQUIREMENTS.txt
```

---



## Portable Python

Bundled from [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone)  
`cpython-3.12.13+20260623-*-unknown-linux-gnu-install_only_stripped`  
glibc builds — RHEL 8.1 (glibc 2.28) OK. Not Alpine/musl.