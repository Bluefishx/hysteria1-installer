#!/usr/bin/env bash
# ============================================================
#  Hysteria v1 UDP Server Installer
#  Port-hopping · OBFS · Multi-user Auth · BBR · Kernel Tuning
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HYSTERIA_VERSION="v1.3.5"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_FILE="$CONFIG_DIR/users.json"
AUTH_SERVER="$CONFIG_DIR/auth_server.py"
AUTH_SERVICE="/etc/systemd/system/hysteria-auth.service"
SERVICE_FILE="/etc/systemd/system/hysteria.service"
LOG_FILE="/var/log/hysteria.log"
AUTH_LOG="/var/log/hysteria-auth.log"
CERT_DIR="$CONFIG_DIR/certs"
HYSTERIA_BIN="$INSTALL_DIR/hysteria"
AUTH_PORT=9527

DEFAULT_PORT_START=10000
DEFAULT_PORT_END=50000
DEFAULT_UP_MBPS=100
DEFAULT_DOWN_MBPS=200

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }

require_root() { [[ $EUID -eq 0 ]] || error "Run as root (sudo)."; }

detect_os() {
  if   [[ -f /etc/debian_version ]]; then OS="debian"
  elif [[ -f /etc/redhat-release ]];  then OS="rhel"
  elif [[ -f /etc/arch-release ]];    then OS="arch"
  else error "Unsupported OS."; fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm"   ;;
    armv6l)  ARCH="arm"   ;;
    *)       error "Unsupported arch: $(uname -m)" ;;
  esac
}

gen_password() { openssl rand -base64 18 | tr -d '=+/' | head -c 18; }
gen_obfs()     { openssl rand -hex 12; }

# --- Dependencies ----------------------------------------------------
install_deps() {
  section "Installing dependencies"
  case $OS in
    debian) apt-get update -qq && apt-get install -y -qq curl openssl ca-certificates iptables python3 ;;
    rhel)   yum install -y -q  curl openssl ca-certificates iptables python3 ;;
    arch)   pacman -Sy --noconfirm curl openssl iptables python ;;
  esac
}

# --- BBR -------------------------------------------------------------
enable_bbr() {
  section "Enabling BBR"
  local major minor
  major=$(uname -r | cut -d. -f1)
  minor=$(uname -r | cut -d. -f2)
  if (( major > 4 )) || (( major == 4 && minor >= 9 )); then
    modprobe tcp_bbr 2>/dev/null || true
    grep -qx "tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null || \
      echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
    [[ "$cc" == "bbr" ]] && info "BBR active." || warn "BBR not active (got: $cc)"
  else
    warn "Kernel too old for BBR ($(uname -r)), skipping."
  fi
}

# --- Kernel / UDP tuning ---------------------------------------------
tune_kernel() {
  section "Kernel & UDP tuning"
  cat > /etc/sysctl.d/99-hysteria.conf <<'EOF'
net.core.rmem_max            = 16777216
net.core.wmem_max            = 16777216
net.core.rmem_default        = 1048576
net.core.wmem_default        = 1048576
net.core.optmem_max          = 65536
net.core.netdev_max_backlog  = 250000
net.core.somaxconn           = 65535
net.ipv4.tcp_rmem            = 4096 1048576 16777216
net.ipv4.tcp_wmem            = 4096 1048576 16777216
net.ipv4.udp_rmem_min        = 8192
net.ipv4.udp_wmem_min        = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen        = 3
net.ipv4.tcp_mtu_probing     = 1
fs.file-max                  = 1048576
EOF
  sysctl -p /etc/sysctl.d/99-hysteria.conf >/dev/null 2>&1 || true
  grep -qF "* soft nofile" /etc/security/limits.conf || \
    printf "\n* soft nofile 1048576\n* hard nofile 1048576\n" >> /etc/security/limits.conf
  info "Tuning applied."
}

# --- Binary ----------------------------------------------------------
# Official repo: apernet/hysteria
# v1.x asset names: hysteria-linux-amd64 / arm64 / arm
download_hysteria() {
  section "Downloading Hysteria $HYSTERIA_VERSION"
  local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}"
  info "URL: $url"
  if ! curl -fsSL "$url" -o "$HYSTERIA_BIN"; then
    error "Download failed.\nURL: $url"
  fi
  chmod +x "$HYSTERIA_BIN"
  "$HYSTERIA_BIN" --version 2>/dev/null || true
  info "Binary installed: $HYSTERIA_BIN"
}

# --- TLS cert --------------------------------------------------------
generate_cert() {
  section "Generating self-signed TLS certificate"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
    -subj "/CN=${SERVER_HOST}/O=Hysteria/C=US" \
    -addext "subjectAltName=IP:${SERVER_HOST},DNS:${SERVER_HOST}" 2>/dev/null
  chmod 600 "$CERT_DIR/server.key"
  info "Cert saved to $CERT_DIR"
}

# --- Users file ------------------------------------------------------
init_users_file() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$USERS_FILE" ]]; then
    echo '{}' > "$USERS_FILE"
    chmod 600 "$USERS_FILE"
  fi
}

user_add() {
  local username="$1" password="$2"
  python3 - "$USERS_FILE" "$username" "$password" <<'PYEOF'
import json, sys
f, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(f))
except: data = {}
data[user] = pw
json.dump(data, open(f,'w'), indent=2)
print(f"  Added user: {user}")
PYEOF
}

user_delete() {
  local username="$1"
  python3 - "$USERS_FILE" "$username" <<'PYEOF'
import json, sys
f, user = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(f))
except: data = {}
if user in data:
    del data[user]
    json.dump(data, open(f,'w'), indent=2)
    print(f"  Deleted user: {user}")
else:
    print(f"  User not found: {user}")
PYEOF
}

user_list() {
  python3 - "$USERS_FILE" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except: data = {}
if not data:
    print("  (no users)")
else:
    print(f"  {'#':<4} {'Username':<24} {'Password'}")
    print(f"  {'-'*4} {'-'*24} {'-'*24}")
    for i,(u,p) in enumerate(data.items(),1):
        print(f"  {i:<4} {u:<24} {p}")
PYEOF
}

user_edit_password() {
  local username="$1" new_password="$2"
  user_add "$username" "$new_password"
  echo "  Password updated for: $username"
}

# --- Python auth server ----------------------------------------------
write_auth_server() {
  section "Writing multi-user auth server"
  cat > "$AUTH_SERVER" <<'PYEOF'
#!/usr/bin/env python3
"""
Hysteria v1 external auth server.
Reads /etc/hysteria/users.json  {username: password, ...}
Any client whose auth_str matches a password in the file is allowed.
"""
import json, logging
from http.server import BaseHTTPRequestHandler, HTTPServer

USERS_FILE  = "/etc/hysteria/users.json"
LOG_FILE    = "/var/log/hysteria-auth.log"
LISTEN_PORT = 9527

logging.basicConfig(
    filename=LOG_FILE, level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def load_passwords():
    try:
        with open(USERS_FILE) as f:
            return set(json.load(f).values())
    except Exception as e:
        logging.error(f"Cannot read users file: {e}")
        return set()

class AuthHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length  = int(self.headers.get("Content-Length", 0))
        body    = self.rfile.read(length)
        allowed = False
        try:
            data     = json.loads(body)
            auth_str = data.get("auth", "")
            addr     = data.get("addr", "?")
            allowed  = auth_str in load_passwords()
            logging.info(f"{'ALLOW' if allowed else 'DENY'} addr={addr} auth={auth_str[:4]}***")
        except Exception as e:
            logging.error(f"Bad request: {e}")

        resp = json.dumps({"ok": allowed}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", LISTEN_PORT), AuthHandler)
    logging.info(f"Auth server listening on 127.0.0.1:{LISTEN_PORT}")
    server.serve_forever()
PYEOF
  chmod +x "$AUTH_SERVER"
}

# --- Auth server systemd service -------------------------------------
setup_auth_service() {
  cat > "$AUTH_SERVICE" <<EOF
[Unit]
Description=Hysteria v1 Multi-user Auth Server
After=network.target
Before=hysteria.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${AUTH_SERVER}
Restart=on-failure
RestartSec=3
StandardOutput=append:${AUTH_LOG}
StandardError=append:${AUTH_LOG}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hysteria-auth
  systemctl restart hysteria-auth
  info "Auth server started on 127.0.0.1:${AUTH_PORT}"
}

# --- Hysteria v1 server config ---------------------------------------
# v1 config rules:
#   - cert and key are TOP-LEVEL fields (NOT nested under "tls")
#   - "resolver" field is NOT supported (causes "invalid syntax" error)
#   - "disable_mtu_discovery" is NOT a valid v1 field, omit it
write_server_config() {
  section "Writing server configuration"
  cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":${PORT_START}",
  "cert": "${CERT_DIR}/server.crt",
  "key":  "${CERT_DIR}/server.key",
  "obfs": "${OBFS_KEY}",
  "auth": {
    "mode": "external",
    "config": {
      "addr": "http://127.0.0.1:${AUTH_PORT}/"
    }
  },
  "up_mbps":   ${SERVER_UP},
  "down_mbps": ${SERVER_DOWN},
  "recv_window_conn":   524288,
  "recv_window_client": 2097152,
  "max_conn_client": 4096,
  "handshake_timeout": 10,
  "idle_timeout": 60
}
EOF
  info "Config written: $CONFIG_FILE"
}

# --- Port-hopping ----------------------------------------------------
setup_port_hopping() {
  section "Port-hopping (${PORT_START}-${PORT_END} UDP)"
  iptables -t nat -D PREROUTING -p udp \
    --dport "${PORT_START}:${PORT_END}" \
    -j REDIRECT --to-port "${PORT_START}" 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp \
    --dport "${PORT_START}:${PORT_END}" \
    -j REDIRECT --to-port "${PORT_START}"
  case $OS in
    debian)
      apt-get install -y -qq iptables-persistent 2>/dev/null || true
      netfilter-persistent save 2>/dev/null || true ;;
    rhel)
      service iptables save 2>/dev/null || true ;;
    arch)
      iptables-save > /etc/iptables/iptables.rules 2>/dev/null || true ;;
  esac
  info "Port-hopping active."
}

# --- Hysteria systemd service ----------------------------------------
setup_service() {
  section "Setting up Hysteria service"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria v1 UDP Server
After=network.target hysteria-auth.service
Requires=hysteria-auth.service

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hysteria
  systemctl restart hysteria
  info "Hysteria service started."
}

# --- Print client config ---------------------------------------------
print_client_config() {
  local username="$1" password="$2"
  echo -e "\n${BOLD}Client config for user: ${CYAN}${username}${NC}"
  cat <<EOF
{
  "server":   "${SERVER_HOST}:${PORT_START}-${PORT_END}",
  "obfs":     "${OBFS_KEY}",
  "auth_str": "${password}",
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
EOF
}

# --- Server info banner ----------------------------------------------
print_server_info() {
  local obfs; obfs=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['obfs'])")
  local port; port=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['listen'].lstrip(':'))")
  local ip;   ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo '?')
  echo -e "${YELLOW}╔══════════════════════════════════════════════╗"
  echo -e "║         HYSTERIA v1  –  SERVER INFO          ║"
  echo -e "╠══════════════════════════════════════════════╣"
  echo -e "║  IP         : $ip"
  echo -e "║  Port range : ${port}-${DEFAULT_PORT_END} UDP"
  echo -e "║  OBFS       : $obfs"
  echo -e "║  Auth mode  : multi-user (external)"
  echo -e "╚══════════════════════════════════════════════╝${NC}"
}

# --- Interactive setup -----------------------------------------------
prompt_config() {
  section "Server Configuration"
  local detected_ip; detected_ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo "")
  read -rp "$(echo -e "${CYAN}Server IP / domain${NC} [${detected_ip}]: ")" SERVER_HOST
  SERVER_HOST="${SERVER_HOST:-$detected_ip}"
  [[ -n "$SERVER_HOST" ]] || error "IP/domain required."

  read -rp "$(echo -e "${CYAN}Port range start${NC} [$DEFAULT_PORT_START]: ")" PORT_START
  PORT_START="${PORT_START:-$DEFAULT_PORT_START}"

  read -rp "$(echo -e "${CYAN}Port range end${NC}   [$DEFAULT_PORT_END]: ")" PORT_END
  PORT_END="${PORT_END:-$DEFAULT_PORT_END}"

  read -rp "$(echo -e "${CYAN}Upload bandwidth Mbps${NC}   [$DEFAULT_UP_MBPS]: ")" SERVER_UP
  SERVER_UP="${SERVER_UP:-$DEFAULT_UP_MBPS}"

  read -rp "$(echo -e "${CYAN}Download bandwidth Mbps${NC} [$DEFAULT_DOWN_MBPS]: ")" SERVER_DOWN
  SERVER_DOWN="${SERVER_DOWN:-$DEFAULT_DOWN_MBPS}"

  local default_obfs; default_obfs=$(gen_obfs)
  read -rp "$(echo -e "${CYAN}OBFS key${NC} [auto: ${default_obfs}]: ")" OBFS_KEY
  OBFS_KEY="${OBFS_KEY:-$default_obfs}"
}

# --- User management menu --------------------------------------------
user_menu() {
  while true; do
    echo -e "\n${BOLD}${CYAN}-- User Management ------------------------------------${NC}"
    echo "  1) List all users"
    echo "  2) Add user"
    echo "  3) Edit user password"
    echo "  4) Delete user"
    echo "  5) Show client config for a user"
    echo "  0) Back"
    read -rp "Choose: " choice
    case $choice in
      1)
        section "Users"
        user_list ;;
      2)
        read -rp "  Username: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        local auto_pw; auto_pw=$(gen_password)
        read -rp "  Password [auto: ${auto_pw}]: " upw
        upw="${upw:-$auto_pw}"
        user_add "$uname" "$upw"
        systemctl restart hysteria-auth 2>/dev/null || true
        info "User added. Auth server reloaded." ;;
      3)
        read -rp "  Username to edit: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        local auto_pw; auto_pw=$(gen_password)
        read -rp "  New password [auto: ${auto_pw}]: " upw
        upw="${upw:-$auto_pw}"
        user_edit_password "$uname" "$upw"
        systemctl restart hysteria-auth 2>/dev/null || true
        info "Password updated. Auth server reloaded." ;;
      4)
        read -rp "  Username to delete: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        read -rp "  Confirm delete '${uname}'? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; continue; }
        user_delete "$uname"
        systemctl restart hysteria-auth 2>/dev/null || true
        info "User deleted. Auth server reloaded." ;;
      5)
        read -rp "  Username: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        local pw
        pw=$(python3 - "$USERS_FILE" "$uname" <<'PYEOF'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get(sys.argv[2], ""))
except: print("")
PYEOF
        )
        if [[ -z "$pw" ]]; then
          warn "User '$uname' not found."
        else
          local obfs; obfs=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['obfs'])")
          local port_start; port_start=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d['listen'].lstrip(':'))")
          SERVER_HOST=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo "?")
          OBFS_KEY="$obfs"
          PORT_START="$port_start"
          PORT_END="${DEFAULT_PORT_END}"
          print_client_config "$uname" "$pw"
        fi ;;
      0) break ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

# --- Main management menu --------------------------------------------
manage_menu() {
  while true; do
    echo -e "\n${BOLD}${CYAN}-- Hysteria Management --------------------------------${NC}"
    echo "  1) Start services"
    echo "  2) Stop services"
    echo "  3) Restart services"
    echo "  4) Status"
    echo "  5) View Hysteria log"
    echo "  6) View Auth log"
    echo "  7) Server info"
    echo "  8) User management  <--"
    echo "  9) Uninstall"
    echo "  0) Exit"
    read -rp "Choose: " choice
    case $choice in
      1) systemctl start hysteria-auth hysteria; info "Started." ;;
      2) systemctl stop hysteria hysteria-auth;  info "Stopped." ;;
      3) systemctl restart hysteria-auth; sleep 1; systemctl restart hysteria; info "Restarted." ;;
      4) systemctl status hysteria hysteria-auth --no-pager ;;
      5) tail -n 60 "$LOG_FILE" ;;
      6) tail -n 60 "$AUTH_LOG" ;;
      7) print_server_info ;;
      8) user_menu ;;
      9)
        read -rp "  Confirm full uninstall? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; continue; }
        systemctl stop hysteria hysteria-auth 2>/dev/null || true
        systemctl disable hysteria hysteria-auth 2>/dev/null || true
        rm -f "$SERVICE_FILE" "$AUTH_SERVICE" "$HYSTERIA_BIN"
        rm -rf "$CONFIG_DIR"
        iptables -t nat -D PREROUTING -p udp \
          --dport "${DEFAULT_PORT_START}:${DEFAULT_PORT_END}" \
          -j REDIRECT --to-port "${DEFAULT_PORT_START}" 2>/dev/null || true
        systemctl daemon-reload
        info "Uninstalled." ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

# --- Entry point -----------------------------------------------------
main() {
  echo -e "${CYAN}${BOLD}"
  echo "  ██╗  ██╗██╗   ██╗███████╗████████╗███████╗██████╗ ██╗ █████╗ "
  echo "  ██║  ██║╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║██╔══██╗"
  echo "  ███████║ ╚████╔╝ ███████╗   ██║   █████╗  ██████╔╝██║███████║"
  echo "  ██╔══██║  ╚██╔╝  ╚════██║   ██║   ██╔══╝  ██╔══██╗██║██╔══██║"
  echo "  ██║  ██║   ██║   ███████║   ██║   ███████╗██║  ██║██║██║  ██║"
  echo "  ╚═╝  ╚═╝   ╚═╝   ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝"
  echo -e "  v1 · Port-hopping · OBFS · Multi-user Auth · BBR${NC}\n"

  require_root
  detect_os
  detect_arch

  if [[ -f "$HYSTERIA_BIN" ]]; then
    warn "Hysteria already installed."
    manage_menu
    exit 0
  fi

  prompt_config
  install_deps
  enable_bbr
  tune_kernel
  download_hysteria
  generate_cert
  init_users_file
  write_auth_server
  setup_auth_service

  section "Create first user"
  local first_user first_pw
  read -rp "  First username: " first_user
  first_user="${first_user:-admin}"
  local auto_pw; auto_pw=$(gen_password)
  read -rp "  Password [auto: ${auto_pw}]: " first_pw
  first_pw="${first_pw:-$auto_pw}"
  user_add "$first_user" "$first_pw"

  write_server_config
  setup_port_hopping
  setup_service
  print_client_config "$first_user" "$first_pw"

  section "Installation complete! Run script again to manage."
}

main "$@"
