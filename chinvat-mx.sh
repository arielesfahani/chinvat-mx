#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# chinvat-mx.sh — Management CLI for Chinvat Multiplexer
# ─────────────────────────────────────────────────────────────────────────────
# Usage: sudo ./chinvat-mx.sh <command> [options]
#
# Commands:
#   install                Install as a systemd service
#   start                  Start the multiplexer
#   stop                   Stop the multiplexer
#   restart                Restart the multiplexer
#   status                 Show status, resolver health, and recent logs
#   add-resolver <IP>      Add a resolver to the pool
#   remove-resolver <IP>   Remove a resolver from the pool
#   list-resolvers         List all configured resolvers
#   logs                   Tail the live log
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/chinvat-mx.py"
CONFIG_DIR="/etc/chinvat"
CONFIG_FILE="$CONFIG_DIR/resolvers.json"
PID_FILE="/var/run/chinvat-mx.pid"
LOG_FILE="/var/log/chinvat-mx.log"
SERVICE_NAME="chinvat-mx"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Listen port — reads from config file if set, overridden by CHINVAT_PORT env var
get_saved_port() {
    python3 - "$CONFIG_FILE" 2>/dev/null <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        val = json.load(f).get("port", "")
        if val:
            print(val)
except Exception:
    pass
PYEOF
}
_saved_port="$( [[ -f "$CONFIG_FILE" ]] && get_saved_port || true )"
LISTEN_PORT="${CHINVAT_PORT:-${_saved_port:-2053}}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "    $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || { err "This command requires root. Run: sudo $0 $*"; exit 1; }
}

check_python() {
    python3 --version &>/dev/null || { err "Python3 not found. Install it first."; exit 1; }
}

check_script() {
    [[ -f "$PY_SCRIPT" ]] || {
        err "chinvat-mx.py not found at $PY_SCRIPT"
        info "Make sure chinvat-mx.py is in the same directory as this script."
        exit 1
    }
}

ensure_config() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] || echo '{"resolvers": []}' > "$CONFIG_FILE"
}

get_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE" 2>/dev/null || echo ""
}

is_running() {
    local pid
    pid=$(get_pid)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

get_resolver_list() {
    python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, json
try:
    with open(sys.argv[1]) as f:
        resolvers = json.load(f).get("resolvers", [])
    for r in resolvers:
        print(r)
except Exception:
    pass
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolver Health Probe (inline Python — no external deps)
# ─────────────────────────────────────────────────────────────────────────────

probe_resolver() {
    local ip="$1"
    python3 - "$ip" <<'PYEOF' 2>/dev/null
import sys, socket, struct, random
ip = sys.argv[1]
txid = random.randint(1, 65535)
query = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0) + b'\x00\x00\x02\x00\x01'
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)
    s.sendto(query, (ip, 53))
    data, _ = s.recvfrom(512)
    s.close()
    if len(data) >= 12 and (struct.unpack(">H", data[2:4])[0] & 0x8000):
        print("alive")
    else:
        print("dead")
except Exception:
    print("dead")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

cmd_install() {
    require_root
    check_python
    check_script
    ensure_config

    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║     CHINVAT MULTIPLEXER SETUP        ║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    # ── Port selection ──────────────────────────────────────────────────────
    echo -e "  ${YELLOW}Which port should chinvat-mx listen on?${NC}"
    echo ""
    echo "    [1] 2053  — recommended, no conflicts, works on most VPS"
    echo "    [2] 443   — looks like HTTPS (avoid if running x-ui or Xray)"
    echo "    [3] 8443  — alternative stealth port"
    echo "    [4] 2083  — alternative stealth port"
    echo "    [5] custom"
    echo ""
    read -rp "  Enter choice [1-5] (default: 1): " port_choice

    case "${port_choice:-1}" in
        1) LISTEN_PORT=2053 ;;
        2) LISTEN_PORT=443  ;;
        3) LISTEN_PORT=8443 ;;
        4) LISTEN_PORT=2083 ;;
        5)
            read -rp "  Enter custom port number: " custom_port
            if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || (( custom_port < 1 || custom_port > 65535 )); then
                err "Invalid port number: $custom_port"
                exit 1
            fi
            LISTEN_PORT=$custom_port
            ;;
        *)
            warn "Invalid choice — using default port 2053"
            LISTEN_PORT=2053
            ;;
    esac

    # Save port to config so start/status can read it without re-asking
    python3 - "$CONFIG_FILE" "$LISTEN_PORT" <<'PYEOF'
import sys, json
path, port = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    data = json.load(f)
data["port"] = port
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    echo ""
    ok "Port set to: $LISTEN_PORT"
    echo ""
    ok "Installing as systemd service..."
    echo ""

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Chinvat DNS Multiplexer
Documentation=https://github.com/arielesfahani/chinvat
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${PY_SCRIPT} --port ${LISTEN_PORT} --config ${CONFIG_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" &>/dev/null

    ok "Service installed: $SERVICE_FILE"
    ok "Enabled at boot."
    echo ""
    warn "Next steps:"
    info "1. Add your resolvers:  sudo $0 add-resolver <IP>"
    info "2. Start the proxy:     sudo $0 start"
    info "3. Check status:        sudo $0 status"
    echo ""
}

cmd_start() {
    require_root
    check_python
    check_script
    ensure_config

    if is_running; then
        warn "Already running (PID $(get_pid))"
        return
    fi

    local resolvers
    resolvers=$(get_resolver_list)
    if [[ -z "$resolvers" ]]; then
        err "No resolvers configured. Add at least one first:"
        info "sudo $0 add-resolver <RESOLVER_IP>"
        exit 1
    fi

    # Use systemd if service is installed, otherwise run directly
    if systemctl list-unit-files "$SERVICE_NAME.service" &>/dev/null; then
        systemctl start "$SERVICE_NAME"
        sleep 1
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            ok "Started via systemd."
            return
        fi
    fi

    # Fallback: run directly in background
    mkdir -p "$(dirname "$LOG_FILE")"
    nohup python3 "$PY_SCRIPT" \
        --port "$LISTEN_PORT" \
        --config "$CONFIG_FILE" \
        >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"

    sleep 1
    if is_running; then
        ok "Started (PID $(get_pid)) on UDP port $LISTEN_PORT"
    else
        err "Failed to start. Check logs:"
        info "sudo $0 logs"
        exit 1
    fi
}

cmd_stop() {
    require_root

    # Try systemd first
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        ok "Stopped (systemd)."
        return
    fi

    local pid
    pid=$(get_pid)

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        warn "Not running."
        return
    fi

    kill "$pid"
    rm -f "$PID_FILE"
    ok "Stopped (PID $pid)."
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    echo ""
    echo -e "  ${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║     CHINVAT MULTIPLEXER STATUS       ║${NC}"
    echo -e "  ${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    # Process status
    if is_running; then
        echo -e "  Process  : ${GREEN}● Running${NC} (PID $(get_pid))"
    elif systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  Process  : ${GREEN}● Running${NC} (systemd)"
    else
        echo -e "  Process  : ${RED}● Not running${NC}"
    fi

    echo "  Port     : UDP $LISTEN_PORT"
    echo "  Config   : $CONFIG_FILE"
    echo "  Log      : $LOG_FILE"
    echo ""

    # Resolver health
    echo "  Resolver Pool:"
    echo ""

    local resolvers
    resolvers=$(get_resolver_list 2>/dev/null || true)

    if [[ -z "$resolvers" ]]; then
        warn "  No resolvers configured."
        info "  Add one: sudo $0 add-resolver <IP>"
    else
        while IFS= read -r r; do
            local status
            status=$(probe_resolver "$r")
            if [[ "$status" == "alive" ]]; then
                echo -e "    ${GREEN}●${NC} $r  ${GREEN}(responding)${NC}"
            else
                echo -e "    ${RED}●${NC} $r  ${RED}(not responding)${NC}"
            fi
        done <<< "$resolvers"
    fi

    echo ""

    # Recent logs
    if [[ -f "$LOG_FILE" ]]; then
        echo "  Recent Log:"
        echo ""
        tail -5 "$LOG_FILE" | sed 's/^/    /'
    fi

    echo ""
}

cmd_add_resolver() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage: sudo $0 add-resolver <IP>"; exit 1; }
    ensure_config

    python3 - "$CONFIG_FILE" "$ip" <<'PYEOF'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
if ip in data["resolvers"]:
    print(f"  {ip} is already in the pool.")
    sys.exit(0)
data["resolvers"].append(ip)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"  Added {ip}")
PYEOF

    ok "Resolver added: $ip"
    warn "Restart to apply: sudo $0 restart"
}

cmd_remove_resolver() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage: sudo $0 remove-resolver <IP>"; exit 1; }
    ensure_config

    python3 - "$CONFIG_FILE" "$ip" <<'PYEOF'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
before = len(data["resolvers"])
data["resolvers"] = [r for r in data["resolvers"] if r != ip]
with open(path, "w") as f:
    json.dump(data, f, indent=2)
removed = before - len(data["resolvers"])
print(f"  Removed {removed} entry/entries for {ip}")
PYEOF

    ok "Resolver removed: $ip"
    warn "Restart to apply: sudo $0 restart"
}

cmd_list_resolvers() {
    ensure_config
    echo ""
    echo "  Configured Resolvers:"
    echo ""
    local resolvers
    resolvers=$(get_resolver_list 2>/dev/null || true)
    if [[ -z "$resolvers" ]]; then
        warn "  None."
    else
        while IFS= read -r r; do
            info "• $r"
        done <<< "$resolvers"
    fi
    echo ""
}

cmd_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${CYAN}Tailing $LOG_FILE — Ctrl+C to stop${NC}"
        echo ""
        tail -f "$LOG_FILE"
    else
        warn "No log file found at $LOG_FILE"
        info "The proxy may not have been started yet."
    fi
}

cmd_help() {
    echo ""
    echo -e "  ${CYAN}Chinvat Multiplexer — Management CLI${NC}"
    echo ""
    echo "  Usage: sudo $0 <command> [args]"
    echo ""
    echo "  Setup:"
    echo "    install                  Install as a systemd service"
    echo "    add-resolver <IP>        Add a resolver to the pool"
    echo "    remove-resolver <IP>     Remove a resolver from the pool"
    echo "    list-resolvers           List all configured resolvers"
    echo ""
    echo "  Control:"
    echo "    start                    Start the multiplexer"
    echo "    stop                     Stop the multiplexer"
    echo "    restart                  Restart the multiplexer"
    echo ""
    echo "  Observe:"
    echo "    status                   Status, resolver health, recent logs"
    echo "    logs                     Tail the live log file"
    echo ""
    echo "  Environment:"
    echo "    CHINVAT_PORT=<port>      Override the default listen port (2053)"
    echo ""
    echo "  Examples:"
    echo "    sudo $0 install"
    echo "    sudo $0 add-resolver 10.0.0.1"
    echo "    sudo $0 add-resolver 185.55.225.25"
    echo "    sudo $0 start"
    echo "    sudo $0 status"
    echo "    sudo $0 uninstall"
    echo "    CHINVAT_PORT=443 sudo $0 start"
    echo ""
}

cmd_uninstall() {
    require_root

    echo ""
    warn "This will:"
    info "• Stop the running process (if any)"
    info "• Disable and remove the systemd service"
    info "• Delete the config directory  ($CONFIG_DIR)"
    info "• Delete the log file          ($LOG_FILE)"
    info "• Delete the PID file          ($PID_FILE)"
    info "• The script files themselves are NOT deleted"
    echo ""
    read -rp "  Are you sure? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
    echo ""

    # 1. Stop the process
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" && ok "Service stopped."
    elif is_running; then
        kill "$(get_pid)" 2>/dev/null && ok "Process stopped."
    else
        info "Process was not running."
    fi

    # 2. Disable and remove systemd service
    if systemctl list-unit-files "$SERVICE_NAME.service" &>/dev/null 2>&1; then
        systemctl disable "$SERVICE_NAME" &>/dev/null && ok "Service disabled."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        ok "Service file removed."
    else
        info "No systemd service found."
    fi

    # 3. Remove config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        ok "Config directory removed: $CONFIG_DIR"
    else
        info "No config directory found."
    fi

    # 4. Remove log file
    if [[ -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
        ok "Log file removed: $LOG_FILE"
    else
        info "No log file found."
    fi

    # 5. Remove PID file
    rm -f "$PID_FILE"

    echo ""
    ok "Chinvat Multiplexer fully uninstalled."
    info "Script files (chinvat-mx.py, chinvat-mx.sh) were left in place."
    info "You can safely delete them manually."
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Router
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
    install)          cmd_install ;;
    uninstall)        cmd_uninstall ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    restart)          cmd_restart ;;
    status)           cmd_status ;;
    add-resolver)     cmd_add_resolver "${2:-}" ;;
    remove-resolver)  cmd_remove_resolver "${2:-}" ;;
    list-resolvers)   cmd_list_resolvers ;;
    logs)             cmd_logs ;;
    help|--help|-h)   cmd_help ;;
    *)                err "Unknown command: $1"; cmd_help; exit 1 ;;
esac
