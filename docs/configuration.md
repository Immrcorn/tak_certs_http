# Configuration reference

You are here if you need to change how the server binds, where it serves files from, or how QR handouts resolve the public URL.

Settings live in [config.env](../config.env) at the package root. Both `start.sh` and systemd load this file.

**Dialect note:** Keep every value a simple **unquoted token** (`KEY=value`). This file is `source`d by shell (`start.sh`) and read by systemd `EnvironmentFile=` — both dialects must agree.

---

## Environment variables


| Variable                        | Default   | Description                                                                                                                                                               |
| ------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TAK_CERTS_HOST`                | `0.0.0.0` | Bind address. `0.0.0.0` = all interfaces.                                                                                                                                 |
| `TAK_CERTS_PORT`                | `18200`   | TCP listen port.                                                                                                                                                          |
| `TAK_CERTS_DIR`                 | `certs`   | Directory to serve. Relative paths stay under the package root. Subfolders are supported.                                                                                 |
| `TAK_CERTS_PYTHON`              | *(auto)*  | Override path to bundled interpreter. Normally leave unset — `start.sh` picks `python/linux-$(uname -m)/python/bin/python3`.                                              |
| `TAK_CERTS_ALLOW_SYSTEM_PYTHON` | off       | Set to `1` to allow system `python3` if ≥ 3.7. **Do not enable on RHEL 8.1** (stock Python is 3.6). Lab/testing only.                                                     |
| `TAK_CERTS_PUBLIC_URL`          | *(auto)*  | Fixed download URL for QR handouts (e.g. `http://10.1.2.3:18200/`). When unset, `gen_qr.py` auto-detects a routable IP.                                                   |
| `TAK_CERTS_ALLOW_EXTERNAL_DIR`  | off       | Set to `1` to serve an absolute `TAK_CERTS_DIR` **outside** the package tree. Requires intentional setup; `install-service.sh` adds the path to systemd `ReadWritePaths`. |
| `TAK_CERTS_INSTALL_FORCE`       | off       | Set to `1` when running `install-service.sh` to allow install paths outside `/opt` or `/srv`. Not recommended for production.                                             |




### `TAK_CERTS_DIR` — relative vs absolute

- **Relative** (default `certs`): resolved under the package root. Safe default.
- **Absolute** outside the package: blocked unless `TAK_CERTS_ALLOW_EXTERNAL_DIR=1`. A warning is printed at startup when serving externally.



### `TAK_CERTS_PUBLIC_URL` — when to set

Auto-detection works when `TAK_CERTS_HOST=0.0.0.0` and the host has a single routable interface. Set a fixed URL when:

- The host has multiple interfaces and auto-detect picks the wrong one
- Users reach the server via a specific VIP or DNS name
- You need QR handouts before the service is running

---

## Examples

**Change listen port:**

```bash
# config.env
TAK_CERTS_PORT=8080
```

**Fixed URL for QR handouts on a multi-homed host:**

```bash
# config.env
TAK_CERTS_PUBLIC_URL=http://10.1.2.3:18200/
```

**Serve certs from an external directory:**

```bash
# config.env
TAK_CERTS_DIR=/srv/tak-certs
TAK_CERTS_ALLOW_EXTERNAL_DIR=1
```

## Then re-run `install-service.sh` so systemd `ReadWritePaths` includes the external path.



## Supported file types

Files in `certs/` are served with `Content-Disposition: attachment` (forced download). Recognized extensions:

`.zip`, `.p12`, `.pfx`, `.pem`, `.crt`, `.cer`, `.key`, `.jks`, `.bks`, `.apk`, `.tar`, `.gz`, `.tgz`

Other file types are still served if present; these get explicit octet-stream handling.

---



## Security behaviors

The server is designed for **trusted internal networks**, not the public internet.


| Behavior         | Detail                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------ |
| Plain HTTP       | No TLS — intentional on private zero-trust VLANs                                           |
| Path containment | Requests cannot escape the certs root                                                      |
| No symlinks      | Symbolic links are not followed or served                                                  |
| No dotfiles      | Hidden files (`.foo`) are not listed or served                                             |
| `O_NOFOLLOW`     | Opens refuse to follow symlinks                                                            |
| Forced download  | `Content-Disposition: attachment` on served files                                          |
| systemd sandbox  | See [systemd-service.md](systemd-service.md) — read-only package tree, write only `certs/` |


---

## Related guides

- [setup.md](setup.md) — deployment walkthrough
- [qr-handouts.md](qr-handouts.md) — QR generation and URL detection
- [systemd-service.md](systemd-service.md) — service install and hardening

