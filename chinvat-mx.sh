#!/bin/bash
# ---------------------------------------------------------------------------
# chinvat-mx.sh - Management CLI for Chinvat Multiplexer v1.0.0
# ---------------------------------------------------------------------------
# Usage: sudo ./chinvat-mx.sh <command> [options]
#
# Commands:
#   install                Install as a systemd service
#   uninstall              Remove everything
#   start                  Start the multiplexer
#   stop                   Stop the multiplexer
#   restart                Restart the multiplexer
#   status                 Show status, resolver health, recent logs
#   add-resolver <IP>      Add a resolver to the pool
#   remove-resolver <IP>   Remove a resolver from the pool
#   set-primary <IP>       Mark a resolver as primary (tunnel-verified)
#   unset-primary <IP>     Remove primary status from a resolver
#   list-resolvers         List all configured resolvers
#   logs                   Tail the live log
#   help                   Show this help
# ---------------------------------------------------------------------------

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/chinvat-mx.py"
CONFIG_DIR="/etc/chinvat"
CONFIG_FILE="$CONFIG_DIR/resolvers.json"
PID_FILE="/var/run/chinvat-mx.pid"
LOG_FILE="/var/log/chinvat-mx.log"
STATE_FILE="/var/lib/chinvat/state.json"
SERVICE_NAME="chinvat-mx"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

get_saved_port() {
    python3 - "$CONFIG_FILE" 2>/dev/null <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        val = json.load(f).get("port", "")
        if val: print(val)
except Exception: pass
PY
}
_saved_port="$( [[ -f "$CONFIG_FILE" ]] && get_saved_port || true )"
LISTEN_PORT="${CHINVAT_PORT:-${_saved_port:-2053}}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
err()  { echo -e "${RED}[!!]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "    $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || { err "This command requires root. Run: sudo $0 $*"; exit 1; }
}
check_python() { python3 --version &>/dev/null || { err "Python3 not found."; exit 1; }; }
check_script() { [[ -f "$PY_SCRIPT" ]] || { err "chinvat-mx.py not found at $PY_SCRIPT"; exit 1; }; }
ensure_config() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] || echo '{"resolvers": [], "primary": []}' > "$CONFIG_FILE"
}
get_pid() { [[ -f "$PID_FILE" ]] && cat "$PID_FILE" 2>/dev/null || echo ""; }
is_running() { local pid; pid=$(get_pid); [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }

get_resolver_list() {
    python3 - "$CONFIG_FILE" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        for r in json.load(f).get("resolvers", []): print(r)
except Exception: pass
PY
}

get_primary_list() {
    python3 - "$CONFIG_FILE" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        for r in json.load(f).get("primary", []): print(r)
except Exception: pass
PY
}

# ---------------------------------------------------------------------------
# Resolver Probe - QR bit only
# ---------------------------------------------------------------------------

probe_resolver() {
    local ip="$1"
    python3 - "$ip" <<'PY' 2>/dev/null
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
PY
}

get_proven_list_live() {
    [[ -f "$STATE_FILE" ]] || return
    python3 - "$STATE_FILE" <<'PY' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1]) as f:
        for r in json.load(f).get("proven", []): print(r)
except Exception: pass
PY
}

get_win_info() {
    [[ -f "$STATE_FILE" ]] || return
    python3 - "$STATE_FILE" <<'PY' 2>/dev/null
import sys, json
try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
    wins = state.get("wins", {})
    ages = state.get("ages_sec", {})
    for ip, w in wins.items():
        a = ages.get(ip, 0)
        age_str = "{}s ago".format(a) if a < 60 else "{}m ago".format(a // 60)
        print("{}|{}|{}".format(ip, w, age_str))
except Exception: pass
PY
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_install() {
    require_root; check_python; check_script; ensure_config

    echo ""
    echo -e "  ${CYAN}+--------------------------------------+${NC}"
    echo -e "  ${CYAN}|     CHINVAT-MX v1.0.0 SETUP     |${NC}"
    echo -e "  ${CYAN}+--------------------------------------+${NC}"
    echo ""

    echo -e "  ${YELLOW}Which port should chinvat-mx listen on?${NC}"
    echo ""
    echo "    [1] 2053  - recommended"
    echo "    [2] 443   - looks like HTTPS"
    echo "    [3] 8443  - alternative stealth"
    echo "    [4] 2083  - alternative stealth"
    echo "    [5] custom"
    echo ""
    read -rp "  Enter choice [1-5] (default: 1): " port_choice

    case "${port_choice:-1}" in
        1) LISTEN_PORT=2053 ;; 2) LISTEN_PORT=443 ;; 3) LISTEN_PORT=8443 ;;
        4) LISTEN_PORT=2083 ;;
        5) read -rp "  Enter port: " custom_port
           if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || (( custom_port < 1 || custom_port > 65535 )); then
               err "Invalid port"; exit 1; fi
           LISTEN_PORT=$custom_port ;;
        *) LISTEN_PORT=2053 ;;
    esac

    python3 - "$CONFIG_FILE" "$LISTEN_PORT" <<'PY'
import sys, json
path, port = sys.argv[1], int(sys.argv[2])
with open(path) as f: data = json.load(f)
data["port"] = port
if "primary" not in data: data["primary"] = []
with open(path, "w") as f: json.dump(data, f, indent=2)
PY

    echo ""
    ok "Port: $LISTEN_PORT"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Chinvat DNS Multiplexer v1.0.0
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
    ok "Service installed."
    echo ""
    warn "Next steps:"
    info "1. Add resolvers:      sudo $0 add-resolver <IP>"
    info "2. Set primary:        sudo $0 set-primary <IP>  (optional)"
    info "   (System auto-discovers working resolvers, but you can set primary)"
    info "3. Start:              sudo $0 start"
    info "4. Status:             sudo $0 status"
    echo ""
}

cmd_uninstall() {
    require_root
    echo ""
    warn "This will remove everything (config, logs, service)."
    read -rp "  Are you sure? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
    echo ""

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME" && ok "Stopped."
    elif is_running; then
        kill "$(get_pid)" 2>/dev/null && ok "Stopped."
    fi

    if systemctl list-unit-files "$SERVICE_NAME.service" &>/dev/null 2>&1; then
        systemctl disable "$SERVICE_NAME" &>/dev/null
        rm -f "$SERVICE_FILE"; systemctl daemon-reload
        ok "Service removed."
    fi

    [[ -d "$CONFIG_DIR" ]] && rm -rf "$CONFIG_DIR"
    [[ -f "$LOG_FILE" ]]   && rm -f "$LOG_FILE"
    [[ -f "$STATE_FILE" ]] && rm -f "$STATE_FILE"
    rm -f "$PID_FILE"
    ok "Fully uninstalled."
    echo ""
}

cmd_start() {
    require_root; check_python; check_script; ensure_config

    if is_running; then warn "Already running (PID $(get_pid))"; return; fi

    local resolvers; resolvers=$(get_resolver_list 2>/dev/null || true)
    if [[ -z "$resolvers" ]]; then
        err "No resolvers configured. Add at least one:"
        info "sudo $0 add-resolver <IP>"; exit 1
    fi

    if systemctl list-unit-files "$SERVICE_NAME.service" &>/dev/null; then
        systemctl start "$SERVICE_NAME"; sleep 1
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            ok "Started via systemd on UDP port $LISTEN_PORT."
            return
        fi
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    nohup python3 "$PY_SCRIPT" --port "$LISTEN_PORT" --config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"; sleep 1
    if is_running; then ok "Started (PID $(get_pid)) on UDP $LISTEN_PORT"
    else err "Failed. Check: sudo $0 logs"; exit 1; fi
}

cmd_stop() {
    require_root
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"; ok "Stopped."; return; fi
    local pid; pid=$(get_pid)
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then warn "Not running."; return; fi
    kill "$pid"; rm -f "$PID_FILE"; ok "Stopped (PID $pid)."
}

cmd_restart() { cmd_stop; sleep 1; cmd_start; }

cmd_status() {
    echo ""
    echo -e "  ${CYAN}+--------------------------------------+${NC}"
    echo -e "  ${CYAN}|   CHINVAT-MX v1.0.0 STATUS      |${NC}"
    echo -e "  ${CYAN}+--------------------------------------+${NC}"
    echo ""

    if is_running; then echo -e "  Process  : ${GREEN}Running${NC} (PID $(get_pid))"
    elif systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  Process  : ${GREEN}Running${NC} (systemd)"
    else echo -e "  Process  : ${RED}Not running${NC}"; fi

    echo "  Port     : UDP $LISTEN_PORT"
    echo "  Filter   : NOERROR + ANCOUNT > 0 (tunnel data check)"
    echo ""

    # Build win info lookup
    # Build proven (auto-discovered) lookup
    declare -A is_proven
    local proven_live; proven_live=$(get_proven_list_live 2>/dev/null || true)
    if [[ -n "$proven_live" ]]; then
        while IFS= read -r p; do is_proven["$p"]=1; done <<< "$proven_live"
    fi

    declare -A win_counts win_ages
    local win_info; win_info=$(get_win_info 2>/dev/null || true)
    if [[ -n "$win_info" ]]; then
        while IFS='|' read -r wip wcount wage; do
            win_counts["$wip"]="$wcount"
            win_ages["$wip"]="$wage"
        done <<< "$win_info"
    fi

    # Build primary lookup
    declare -A is_primary
    local primaries; primaries=$(get_primary_list 2>/dev/null || true)
    if [[ -n "$primaries" ]]; then
        while IFS= read -r p; do is_primary["$p"]=1; done <<< "$primaries"
    fi

    # Show resolvers
    local resolvers; resolvers=$(get_resolver_list 2>/dev/null || true)

    if [[ -z "$resolvers" ]]; then
        warn "  No resolvers configured."
        info "  sudo $0 add-resolver <IP>"
    else
        local cp=0 ch=0 cd=0

        # Primary resolvers first
        local has_primary=false
        while IFS= read -r r; do
            [[ -n "${is_primary[$r]+x}" ]] && has_primary=true
        done <<< "$resolvers"

        if [[ "$has_primary" == "true" ]]; then
            echo -e "  ${BOLD}Primary (tunnel traffic):${NC}"
            echo ""
            while IFS= read -r r; do
                [[ -z "${is_primary[$r]+x}" ]] && continue
                local status; status=$(probe_resolver "$r")
                local extra=""
                [[ -n "${win_counts[$r]+x}" ]] && extra="  ${CYAN}${win_counts[$r]} wins, last ${win_ages[$r]}${NC}"
                if [[ "$status" == "alive" ]]; then
                    echo -e "    ${GREEN}*${NC} $r  ${GREEN}responding${NC}$extra"
                    ((cp++)) || true
                else
                    echo -e "    ${RED}*${NC} $r  ${RED}not responding${NC}"
                    ((cd++)) || true
                fi
            done <<< "$resolvers"
            echo ""
        fi

        # Pool resolvers
        local has_pool=false
        while IFS= read -r r; do
            [[ -z "${is_primary[$r]+x}" ]] && has_pool=true
        done <<< "$resolvers"

        if [[ "$has_pool" == "true" ]]; then
            # Proven resolvers (auto-discovered)
        local has_proven=false
        while IFS= read -r r; do
            [[ -n "${is_primary[$r]+x}" ]] && continue
            [[ -n "${is_proven[$r]+x}" ]] && has_proven=true
        done <<< "$resolvers"

        if [[ "$has_proven" == "true" ]]; then
            echo -e "  ${BOLD}Proven (auto-discovered, carrying traffic):${NC}"
            echo ""
            while IFS= read -r r; do
                [[ -n "${is_primary[$r]+x}" ]] && continue
                [[ -z "${is_proven[$r]+x}" ]] && continue
                local status; status=$(probe_resolver "$r")
                local extra=""
                [[ -n "${win_counts[$r]+x}" ]] && extra="  ${CYAN}${win_counts[$r]} wins, last ${win_ages[$r]}${NC}"
                if [[ "$status" == "alive" ]]; then
                    echo -e "    ${GREEN}*${NC} $r  ${GREEN}responding${NC}$extra"
                    ((ch++)) || true
                else
                    echo -e "    ${RED}*${NC} $r  ${RED}not responding${NC}"
                    ((cd++)) || true
                fi
            done <<< "$resolvers"
            echo ""
        fi

        echo -e "  ${BOLD}Pool (health-checked, discovery):${NC}"
            echo ""
            while IFS= read -r r; do
                [[ -n "${is_primary[$r]+x}" ]] && continue
                [[ -n "${is_proven[$r]+x}" ]] && continue
                local status; status=$(probe_resolver "$r")
                if [[ "$status" == "alive" ]]; then
                    echo -e "    ${GREEN}*${NC} $r  ${GREEN}responding${NC}"
                    ((ch++)) || true
                else
                    echo -e "    ${RED}*${NC} $r  ${RED}not responding${NC}"
                    ((cd++)) || true
                fi
            done <<< "$resolvers"
            echo ""
        fi

        echo -e "  ${BOLD}Summary:${NC} ${CYAN}$cp primary${NC} + ${GREEN}$ch pool${NC} + ${RED}$cd dead${NC}"
        if [[ $cp -eq 0 ]] && [[ "$has_primary" == "false" ]] && [[ "$has_proven" == "false" ]]; then
            echo -e "  ${YELLOW}Bootstrap mode: discovering which resolvers carry tunnel traffic${NC}"
        fi
    fi

    echo ""
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

    python3 - "$CONFIG_FILE" "$ip" <<'PY'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
if ip in data.get("resolvers", []):
    print("  Already in pool: {}".format(ip)); sys.exit(0)
data.setdefault("resolvers", []).append(ip)
with open(path, "w") as f: json.dump(data, f, indent=2)
print("  Added: {}".format(ip))
PY
    ok "Added: $ip"
    warn "Restart to apply: sudo $0 restart"
}

cmd_remove_resolver() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage: sudo $0 remove-resolver <IP>"; exit 1; }
    ensure_config

    python3 - "$CONFIG_FILE" "$ip" <<'PY'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["resolvers"] = [r for r in data.get("resolvers", []) if r != ip]
data["primary"] = [r for r in data.get("primary", []) if r != ip]
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
    ok "Removed: $ip"
    warn "Restart to apply: sudo $0 restart"
}

cmd_set_primary() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage: sudo $0 set-primary <IP>"; exit 1; }
    ensure_config

    python3 - "$CONFIG_FILE" "$ip" <<'PY'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
if ip not in data.get("resolvers", []):
    print("  Error: {} is not in the resolver pool. Add it first.".format(ip))
    sys.exit(1)
primary = data.get("primary", [])
if ip in primary:
    print("  Already primary: {}".format(ip)); sys.exit(0)
primary.append(ip)
data["primary"] = primary
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
    ok "Set as primary: $ip"
    info "This resolver will be used for tunnel traffic."
    warn "Restart to apply: sudo $0 restart"
}

cmd_unset_primary() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { err "Usage: sudo $0 unset-primary <IP>"; exit 1; }
    ensure_config

    python3 - "$CONFIG_FILE" "$ip" <<'PY'
import sys, json
path, ip = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["primary"] = [r for r in data.get("primary", []) if r != ip]
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
    ok "Removed primary: $ip"
    warn "Restart to apply: sudo $0 restart"
}

cmd_list_resolvers() {
    ensure_config
    local primaries; primaries=$(get_primary_list 2>/dev/null || true)
    declare -A is_primary
    if [[ -n "$primaries" ]]; then
        while IFS= read -r p; do is_primary["$p"]=1; done <<< "$primaries"
    fi

    echo ""
    echo "  Configured Resolvers:"
    echo ""
    local resolvers; resolvers=$(get_resolver_list 2>/dev/null || true)
    if [[ -z "$resolvers" ]]; then
        warn "  None."
    else
        while IFS= read -r r; do
            if [[ -n "${is_primary[$r]+x}" ]]; then
                info "${GREEN}[PRIMARY]${NC} $r"
            else
                info "          $r"
            fi
        done <<< "$resolvers"
    fi
    echo ""
}

cmd_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${CYAN}Tailing $LOG_FILE - Ctrl+C to stop${NC}"; echo ""
        tail -f "$LOG_FILE"
    else warn "No log file - has the proxy been started?"; fi
}

cmd_help() {
    echo ""
    echo -e "  ${CYAN}Chinvat-MX v1.0.0 - Management CLI${NC}"
    echo ""
    echo "  Usage: sudo $0 <command> [args]"
    echo ""
    echo "  Setup:"
    echo "    install                  Install as a systemd service"
    echo "    uninstall                Remove everything"
    echo "    add-resolver <IP>        Add a resolver to the pool"
    echo "    remove-resolver <IP>     Remove a resolver"
    echo "    set-primary <IP>         Mark as primary (tunnel-verified)"
    echo "    unset-primary <IP>       Remove primary status"
    echo "    list-resolvers           List all resolvers"
    echo ""
    echo "  Control:"
    echo "    start / stop / restart"
    echo ""
    echo "  Observe:"
    echo "    status                   Health + which resolvers carry traffic"
    echo "    logs                     Tail live log"
    echo ""
    echo "  Primary = manually verified. System also auto-discovers working ones."
    echo "  When set, ONLY primary resolvers handle tunnel queries."
    echo "  Pool resolvers stay health-checked as backup."
    echo ""
}

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

case "${1:-help}" in
    install)          cmd_install ;;
    uninstall)        cmd_uninstall ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    restart)          cmd_restart ;;
    status)           cmd_status ;;
    add-resolver)     cmd_add_resolver "${2:-}" ;;
    remove-resolver)  cmd_remove_resolver "${2:-}" ;;
    set-primary)      cmd_set_primary "${2:-}" ;;
    unset-primary)    cmd_unset_primary "${2:-}" ;;
    list-resolvers)   cmd_list_resolvers ;;
    logs)             cmd_logs ;;
    help|--help|-h)   cmd_help ;;
    *)                err "Unknown command: $1"; cmd_help; exit 1 ;;
esac
