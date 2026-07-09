# Hysteria v1 UDP Installer

> One-script installer for a high-performance Hysteria v1 server with port-hopping, OBFS, multi-user auth, BBR, and full kernel tuning.

## Features

| Feature | Detail |
|---|---|
| **Hysteria v1** | Stable `v1.3.5` binary |
| **Port-hopping** | UDP range `10000–50000` via `iptables REDIRECT` |
| **OBFS** | Configurable key (default: auto-generated) |
| **Multi-user auth** | External Python auth server — unlimited users |
| **BBR** | Auto-enabled on kernel ≥ 4.9 |
| **Kernel tuning** | UDP buffers 16 MB, backlog 250k, FD limit 1M |
| **systemd** | Both `hysteria` and `hysteria-auth` services |
| **Management menu** | Start / stop / restart / logs / user CRUD |

---

## Quick Install (one-liner)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Bluefishx/hysteria1-installer/main/install.sh)
```

> Must be run as **root**.

---

## What gets installed

```
/usr/local/bin/hysteria          <- Hysteria v1 binary
/etc/hysteria/
  config.json                    <- Server config
  users.json                     <- { "username": "password", ... }
  auth_server.py                 <- Multi-user auth HTTP server
  certs/
    server.crt
    server.key
/etc/systemd/system/
  hysteria.service
  hysteria-auth.service
/var/log/hysteria.log
/var/log/hysteria-auth.log
```

---

## Install on Server

### Option A — One-liner (recommended)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Bluefishx/hysteria1-installer/main/install.sh)
```

### Option B — Download then run
```bash
wget -O install.sh https://raw.githubusercontent.com/Bluefishx/hysteria1-installer/main/install.sh
chmod +x install.sh
bash install.sh
```

---

## Management

Run the script again at any time:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Bluefishx/hysteria1-installer/main/install.sh)
```

Menu options:

```
1) Start services
2) Stop services
3) Restart services
4) Status
5) View Hysteria log
6) View Auth log
7) Server info
8) User management
9) Uninstall
```

### User Management (option 8)

```
1) List all users
2) Add user
3) Edit user password
4) Delete user
5) Show client config for a user
```

Each user gets their own `auth_str`. The OBFS key and server address are shared.

---

## Client Config

Paste into your Hysteria v1 app:

```json
{
  "server":   "YOUR_SERVER_IP:10000-50000",
  "obfs":     "YOUR_OBFS_KEY",
  "auth_str": "USER_PASSWORD",
  "up_mbps":  1,
  "down_mbps": 2,
  "retry": 3,
  "retry_interval": 1,
  "socks5": { "listen": "127.0.0.1:1080" },
  "http":   { "listen": "127.0.0.1:8989" },
  "insecure": true,
  "lazy_start": false,
  "handshake_timeout": 10,
  "ca": "",
  "recv_window_conn": 196608,
  "recv_window": 491520
}
```

> Use option `8 → 5` in the management menu to auto-generate the config for any user.

---

## How Auth Works

```
Client --auth_str-->  Hysteria server
                            |
                  HTTP POST | {"auth": "password", ...}
                            v
                   auth_server.py :9527
                            |
                   reads users.json
                            |
                   {"ok": true/false}
```

The auth server runs on `127.0.0.1:9527` (localhost only).  
Changes to `users.json` take effect after `systemctl restart hysteria-auth`.

---

## Supported OS

- Debian / Ubuntu
- CentOS / RHEL
- Arch Linux

## Architecture

- `x86_64` (amd64)
- `aarch64` (arm64)
- `armv7l` (arm)

---

## License

MIT
