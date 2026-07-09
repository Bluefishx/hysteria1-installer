#!/usr/bin/env bash
# ============================================================
#  Hysteria v1 UDP Server Installer
#  Port-hopping · OBFS · Multi-user Auth · BBR · Kernel Tuning
#
#  Auth: passwords mode  →  auth_str = "username:password"
#  Users stored in /etc/hysteria/users.json {user: pass}
#  Config rebuilt from users.json on every add/edit/delete
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

HYSTERIA_VERSION="v1.3.5"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.json"
USERS_FILE="$CONFIG_DIR/users.json"
SERVICE_FILE="/etc/systemd/system/hysteria.service"
LOG_FILE="/var/log/hysteria.log"
CERT_DIR="$CONFIG_DIR/certs"
HYSTERIA_BIN="$INSTALL_DIR/hysteria"

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
    'i386'|'i686')                          ARCH='386'    ;;
    'amd64'|'x86_64')                       ARCH='amd64'  ;;
    'armv5tel'|'armv6l'|'armv7'|'armv7l')  ARCH='arm'    ;;
    'armv8'|'aarch64')                      ARCH='arm64'  ;;
    'mips'|'mipsle'|'mips64'|'mips64le')   ARCH='mipsle' ;;
    's390x')                                ARCH='s390x'  ;;
    *) error "Unsupported arch: $(uname -m)" ;;
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
# v1.x binary: hysteria-linux-{arch}
# v1 CLI:  hysteria -config config.json server
download_hysteria() {
  section "Downloading Hysteria $HYSTERIA_VERSION"
  local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}"
  info "URL: $url"
  if ! curl -fsSL "$url" -o "$HYSTERIA_BIN"; then
    error "Download failed.\nURL: $url"
  fi
  chmod +x "$HYSTERIA_BIN"
  "$HYSTERIA_BIN" -v 2>/dev/null || true
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
# Format: { "username": "password", ... }
# auth_str sent by client = "username:password"
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
print(f"  Added: {user}")
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
    print(f"  Deleted: {user}")
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
    print(f"  {'#':<4} {'Username':<24} {'Password':<24} {'auth_str (user:pass)'}")
    print(f"  {'-'*4} {'-'*24} {'-'*24} {'-'*30}")
    for i,(u,p) in enumerate(data.items(),1):
        print(f"  {i:<4} {u:<24} {p:<24} {u}:{p}")
PYEOF
}

user_edit_password() {
  local username="$1" new_password="$2"
  user_add "$username" "$new_password"
}

# --- Build passwords array from users.json and write config ----------
# Hysteria v1 passwords mode:
#   auth.mode = "passwords"
#   auth.config = ["user1:pass1", "user2:pass2", ...]
#   client sends auth_str = "username:password"
rebuild_config() {
  local obfs; obfs=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('obfs',''))" 2>/dev/null || echo "$OBFS_KEY")
  local listen; listen=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('listen',':$DEFAULT_PORT_START'))" 2>/dev/null || echo ":$DEFAULT_PORT_START")
  local up; up=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('up_mbps',$DEFAULT_UP_MBPS))" 2>/dev/null || echo "$DEFAULT_UP_MBPS")
  local down; down=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('down_mbps',$DEFAULT_DOWN_MBPS))" 2>/dev/null || echo "$DEFAULT_DOWN_MBPS")

  python3 - "$USERS_FILE" "$CONFIG_FILE" "$obfs" "$listen" "$up" "$down" \
    "${CERT_DIR}/server.crt" "${CERT_DIR}/server.key" <<'PYEOF'
import json, sys
users_file, config_file = sys.argv[1], sys.argv[2]
obfs, listen, up, down = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
cert, key = sys.argv[7], sys.argv[8]

try:
    users = json.load(open(users_file))
except: users = {}

# Build passwords list: ["user:pass", ...]
passwords = [f"{u}:{p}" for u,p in users.items()]

config = {
    "listen": listen,
    "cert":   cert,
    "key":    key,
    "obfs":   obfs,
    "auth": {
        "mode":   "passwords",
        "config": passwords
    },
    "up_mbps":            int(up),
    "down_mbps":          int(down),
    "recv_window_conn":   524288,
    "recv_window_client": 2097152,
    "max_conn_client":    4096,
    "handshake_timeout":  10,
    "idle_timeout":       60
}
json.dump(config, open(config_file,'w'), indent=2)
print(f"  Config rebuilt with {len(passwords)} user(s).")
PYEOF
}

# --- Write initial server config -------------------------------------
# Called only on first install (uses shell vars from prompt_config)
write_server_config() {
  section "Writing server configuration"

  # Build initial passwords list from users.json
  local passwords_json
  passwords_json=$(python3 - "$USERS_FILE" <<'PYEOF'
import json, sys
try:
    users = json.load(open(sys.argv[1]))
except: users = {}
passwords = [f"{u}:{p}" for u,p in users.items()]
print(json.dumps(passwords))
PYEOF
  )

  cat > "$CONFIG_FILE" <<EOF
{
  "listen": ":${PORT_START}",
  "cert": "${CERT_DIR}/server.crt",
  "key":  "${CERT_DIR}/server.key",
  "obfs": "${OBFS_KEY}",
  "auth": {
    "mode":   "passwords",
    "config": ${passwords_json}
  },
  "up_mbps":            ${SERVER_UP},
  "down_mbps":          ${SERVER_DOWN},
  "recv_window_conn":   524288,
  "recv_window_client": 2097152,
  "max_conn_client":    4096,
  "handshake_timeout":  10,
  "idle_timeout":       60
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
    rhel)  service iptables save 2>/dev/null || true ;;
    arch)  iptables-save > /etc/iptables/iptables.rules 2>/dev/null || true ;;
  esac
  info "Port-hopping active."
}

# --- Hysteria systemd service ----------------------------------------
# v1 CLI: hysteria -config <file> server
setup_service() {
  section "Setting up Hysteria service"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria v1 UDP Server
After=network.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} -config ${CONFIG_FILE} server
WorkingDirectory=${CONFIG_DIR}
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
  local server_ip; server_ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo "?")
  local obfs; obfs=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('obfs',''))" 2>/dev/null || echo "")
  local port; port=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('listen',':$DEFAULT_PORT_START').lstrip(':'))" 2>/dev/null || echo "$DEFAULT_PORT_START")

  echo -e "\n${BOLD}Client config for user: ${CYAN}${username}${NC}"
  cat <<EOF
{
  "server":   "${server_ip}:${port}-${DEFAULT_PORT_END}",
  "obfs":     "${obfs}",
  "auth_str": "${username}:${password}",
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
  local obfs; obfs=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('obfs',''))")
  local port; port=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('listen','').lstrip(':'))")
  local ip;   ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || echo '?')
  local users; users=$(python3 -c "import json; d=json.load(open('$USERS_FILE')); print(len(d))" 2>/dev/null || echo '?')
  echo -e "${YELLOW}╔══════════════════════════════════════════════╗"
  echo -e "║         HYSTERIA v1  –  SERVER INFO          ║"
  echo -e "╠══════════════════════════════════════════════╣"
  echo -e "║  IP         : $ip"
  echo -e "║  Port range : ${port}-${DEFAULT_PORT_END} UDP"
  echo -e "║  OBFS       : $obfs"
  echo -e "║  Auth mode  : passwords (user:pass)"
  echo -e "║  Users      : $users"
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
        section "Users  (auth_str = username:password)"
        user_list ;;
      2)
        read -rp "  Username: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        local auto_pw; auto_pw=$(gen_password)
        read -rp "  Password [auto: ${auto_pw}]: " upw
        upw="${upw:-$auto_pw}"
        user_add "$uname" "$upw"
        rebuild_config
        systemctl restart hysteria 2>/dev/null || true
        info "User added. Hysteria restarted with new passwords." ;;
      3)
        read -rp "  Username to edit: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        local auto_pw; auto_pw=$(gen_password)
        read -rp "  New password [auto: ${auto_pw}]: " upw
        upw="${upw:-$auto_pw}"
        user_edit_password "$uname" "$upw"
        rebuild_config
        systemctl restart hysteria 2>/dev/null || true
        info "Password updated. Hysteria restarted." ;;
      4)
        read -rp "  Username to delete: " uname
        [[ -z "$uname" ]] && warn "Username cannot be empty." && continue
        read -rp "  Confirm delete '${uname}'? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; continue; }
        user_delete "$uname"
        rebuild_config
        systemctl restart hysteria 2>/dev/null || true
        info "User deleted. Hysteria restarted." ;;
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
    echo "  1) Start"
    echo "  2) Stop"
    echo "  3) Restart"
    echo "  4) Status"
    echo "  5) View log"
    echo "  6) Server info"
    echo "  7) User management  <--"
    echo "  8) Uninstall"
    echo "  0) Exit"
    read -rp "Choose: " choice
    case $choice in
      1) systemctl start hysteria; info "Started." ;;
      2) systemctl stop hysteria;  info "Stopped." ;;
      3) systemctl restart hysteria; info "Restarted." ;;
      4) systemctl status hysteria --no-pager ;;
      5) tail -n 60 "$LOG_FILE" ;;
      6) print_server_info ;;
      7) user_menu ;;
      8)
        read -rp "  Confirm full uninstall? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; continue; }
        systemctl stop hysteria 2>/dev/null || true
        systemctl disable hysteria 2>/dev/null || true
        rm -f "$SERVICE_FILE" "$HYSTERIA_BIN"
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
  echo -e "  v1 · Port-hopping · OBFS · passwords auth · BBR${NC}\n"

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

  section "Create first user"
  local first_user first_pw
  read -rp "  Username: " first_user
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
