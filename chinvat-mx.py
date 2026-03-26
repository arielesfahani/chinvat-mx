#!/usr/bin/env python3
"""
chinvat-mx - DNS Multiplexing Proxy
Part of the Chinvat project for high-censorship environments.
Version: 1.0.0

Key insight: dnstt-server ALWAYS responds with answer records (ANCOUNT > 0)
because that's where tunnel data is encoded. Non-working resolvers return
SERVFAIL or empty NOERROR (ANCOUNT = 0) due to MTU truncation or response
modification. Using ANCOUNT > 0 as a filter automatically separates working
resolvers from non-working ones.

How it works:
    1. Fan out query to resolvers (all in bootstrap, or proven + discovery)
    2. Accept ONLY responses with NOERROR + ANCOUNT > 0
       - SERVFAIL from non-working resolvers -> rejected (RCODE filter)
       - Empty NOERROR from truncated responses -> rejected (ANCOUNT filter)
       - Valid tunnel NOERROR with answer data -> accepted
    3. Track which resolvers provide accepted responses -> auto-promoted
    4. Future queries prioritize promoted resolvers

    In normal conditions (all resolvers work):
       All responses have NOERROR + ANCOUNT > 0, first one wins -> same as v1

    In mixed pools (few working, many non-working):
       ANCOUNT filter catches truncated responses, working resolvers win

Resolver hierarchy (highest to lowest priority):
    PRIMARY  - manually set by user (guaranteed working, set-primary command)
    PROVEN   - auto-discovered (won races with ANCOUNT > 0 recently)
    POOL     - all other healthy resolvers (used for discovery)
"""

import socket
import threading
import time
import sys
import os
import json
import signal
import struct
import random
import argparse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------

DEFAULT_PORT            = 2053
DEFAULT_TIMEOUT         = 3.0
DEFAULT_HEALTH_INTERVAL = 30
DEFAULT_WORKERS         = 64
CONFIG_PATH             = "/etc/chinvat/resolvers.json"
LOG_PATH                = "/var/log/chinvat-mx.log"
PID_PATH                = "/var/run/chinvat-mx.pid"
STATE_PATH              = "/var/lib/chinvat/state.json"

PROVEN_WINDOW           = 600    # 10 min - proven status expires
DISCOVERY_SAMPLE        = 3      # unproven resolvers to probe per query

# --------------------------------------------------------------------------
# Global State
# --------------------------------------------------------------------------

resolver_pool   = []
primary_set     = set()    # Manual: user-verified (set-primary command)
healthy         = []
healthy_lock    = threading.Lock()
shutdown_event  = threading.Event()

# Auto-discovery tracker
resolver_wins     = {}     # IP -> total win count
resolver_last_win = {}     # IP -> monotonic timestamp of last win
proven_lock       = threading.Lock()

stats      = {"total": 0, "answered": 0, "dropped": 0}
stats_lock = threading.Lock()

# --------------------------------------------------------------------------
# Logging
# --------------------------------------------------------------------------

_log_lock = threading.Lock()

def _log(level, msg):
    line = "[{}] [{}] {}".format(datetime.now().strftime('%Y-%m-%d %H:%M:%S'), level, msg)
    with _log_lock:
        print(line, flush=True)
        try:
            with open(LOG_PATH, "a") as f:
                f.write(line + "\n")
        except Exception:
            pass

def info(msg):  _log("INFO", msg)
def warn(msg):  _log("WARN", msg)
def error(msg): _log("ERR ", msg)

# --------------------------------------------------------------------------
# DNS Utilities
# --------------------------------------------------------------------------

def build_health_query():
    """Root NS query - minimal valid DNS query for health checking."""
    txid     = random.randint(1, 65535)
    header   = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    question = b'\x00\x00\x02\x00\x01'
    return header + question


def is_valid_dns_response(data):
    """QR bit check - for health probes (any response = alive)."""
    if len(data) < 12:
        return False
    flags = struct.unpack(">H", data[2:4])[0]
    return bool(flags & 0x8000)


def is_tunnel_response(data):
    """
    Accept response only if it looks like valid tunnel data:
      - QR bit set (is a response)
      - RCODE 0 (NOERROR)
      - ANCOUNT > 0 (has answer records containing tunnel data)

    Why ANCOUNT > 0 is the key:
      dnstt-server ALWAYS responds with answer records — that's where the
      encoded tunnel data lives (TXT records, A records, CNAME, etc).

      Non-working resolvers return either:
        SERVFAIL -> caught by RCODE filter
        NOERROR + ANCOUNT=0 -> empty response from MTU truncation,
          response modification, or cache miss. Looks valid on the surface
          but contains no tunnel data. ANCOUNT filter catches these.

      This single check effectively separates working from non-working
      resolvers at the DNS level without needing tunnel-layer validation.
    """
    if len(data) < 12:
        return False
    flags = struct.unpack(">H", data[2:4])[0]
    if not (flags & 0x8000):           # QR bit
        return False
    if (flags & 0x000F) != 0:          # RCODE != NOERROR
        return False
    ancount = struct.unpack(">H", data[6:8])[0]
    return ancount > 0

# --------------------------------------------------------------------------
# Auto-Discovery Tracker
# --------------------------------------------------------------------------

def record_win(ip):
    """Record that a resolver provided a valid tunnel response."""
    with proven_lock:
        resolver_wins[ip] = resolver_wins.get(ip, 0) + 1
        resolver_last_win[ip] = time.monotonic()


def get_proven():
    """Resolvers that won within the proven window (auto-discovered)."""
    now = time.monotonic()
    with proven_lock:
        return {ip for ip, ts in resolver_last_win.items()
                if now - ts < PROVEN_WINDOW}


def select_resolvers(healthy_list):
    """
    Resolver selection priority:
      1. PRIMARY (manual) - if set and healthy, use ONLY these
      2. PROVEN (auto) - if discovered, use all proven + discovery sample
      3. ALL healthy - bootstrap mode, discover everything

    In normal conditions (all resolvers work): returns all healthy.
    In mixed pools: returns proven + small discovery sample.
    """
    # Priority 1: Manual primary override
    if primary_set:
        primary_healthy = [ip for ip in healthy_list if ip in primary_set]
        if primary_healthy:
            return primary_healthy

    # Priority 2: Auto-discovered proven resolvers
    proven = get_proven()
    if proven:
        proven_healthy = [ip for ip in healthy_list if ip in proven]
        if proven_healthy:
            unproven = [ip for ip in healthy_list if ip not in proven]
            sample_n = min(DISCOVERY_SAMPLE, len(unproven))
            discovery = random.sample(unproven, sample_n) if sample_n > 0 else []
            return proven_healthy + discovery

    # Priority 3: Bootstrap - try everything
    return list(healthy_list)

# --------------------------------------------------------------------------
# Fanout
# --------------------------------------------------------------------------

def fanout(data, resolvers, timeout):
    """
    Thread-per-resolver race with NOERROR + ANCOUNT > 0 filter.

    In normal conditions: all responses qualify, first wins (v1 behavior).
    In mixed pools: SERVFAIL and empty NOERROR are rejected, system waits
    until a response with actual answer records arrives.
    """
    if not resolvers:
        return None, None

    winner    = [None]
    winner_ip = [None]
    done      = threading.Event()

    def race(resolver_ip):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.settimeout(timeout)
            sock.sendto(data, (resolver_ip, 53))
            response, _ = sock.recvfrom(4096)
            sock.close()

            # Only accept responses that look like valid tunnel data
            if is_tunnel_response(response) and not done.is_set():
                winner[0] = response
                winner_ip[0] = resolver_ip
                done.set()
        except Exception:
            pass

    threads = [
        threading.Thread(target=race, args=(r,), daemon=True)
        for r in resolvers
    ]
    for t in threads:
        t.start()

    done.wait(timeout=timeout + 0.5)
    return winner[0], winner_ip[0]

# --------------------------------------------------------------------------
# Health Checker
# --------------------------------------------------------------------------

def health_checker(interval):
    """
    Generic DNS reachability (QR bit only).
    Keeps resolvers in pool regardless of RCODE — the fanout filter
    handles quality selection. This ensures maximum resolver availability.
    """
    global healthy

    probe = build_health_query()
    info("Health checker started - interval: {}s".format(interval))

    while not shutdown_event.is_set():
        alive, dead = [], []

        for r in resolver_pool:
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.settimeout(2.0)
                sock.sendto(probe, (r, 53))
                data, _ = sock.recvfrom(512)
                sock.close()
                if is_valid_dns_response(data):
                    alive.append(r)
                else:
                    dead.append(r)
            except Exception:
                dead.append(r)

        with healthy_lock:
            if alive:
                healthy = alive
            else:
                healthy = list(resolver_pool)
                warn("All resolvers failed - retaining full pool")

        if dead:
            warn("Unreachable: {}".format(dead))

        proven = get_proven()
        primary_alive = [ip for ip in alive if ip in primary_set]
        info("Pool: {}/{} reachable | primary: {}/{} | proven: {}".format(
            len(alive), len(resolver_pool),
            len(primary_alive), len(primary_set),
            len(proven)))

        write_state(alive, proven)
        shutdown_event.wait(interval)


def write_state(alive_list, proven_set):
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        now = time.monotonic()
        with proven_lock:
            wins = dict(resolver_wins)
            ages = {ip: int(now - ts) for ip, ts in resolver_last_win.items()}

        state = {
            "primary":  list(primary_set),
            "proven":   list(proven_set),
            "healthy":  alive_list,
            "wins":     wins,
            "ages_sec": ages,
            "updated":  datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }
        with open(STATE_PATH, "w") as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass

# --------------------------------------------------------------------------
# Stats Reporter
# --------------------------------------------------------------------------

def stats_reporter():
    while not shutdown_event.is_set():
        shutdown_event.wait(60)
        with stats_lock:
            s = dict(stats)
        with healthy_lock:
            h = len(healthy)
        proven = get_proven()
        hit_rate = "{:.1f}%".format(s["answered"] / s["total"] * 100) if s["total"] > 0 else "n/a"

        mode = "PRIMARY" if primary_set else ("PROVEN" if proven else "BOOTSTRAP")
        info("Stats - queries: {} | answered: {} ({}) | dropped: {} | healthy: {}/{} | proven: {} | mode: {}".format(
            s["total"], s["answered"], hit_rate, s["dropped"],
            h, len(resolver_pool), len(proven), mode))

# --------------------------------------------------------------------------
# Per-Query Handler
# --------------------------------------------------------------------------

def handle(data, addr, sock, timeout):
    with stats_lock:
        stats["total"] += 1

    with healthy_lock:
        all_healthy = list(healthy)

    resolvers = select_resolvers(all_healthy)
    response, winner_ip = fanout(data, resolvers, timeout)

    if response:
        if winner_ip:
            record_win(winner_ip)
        try:
            sock.sendto(response, addr)
            with stats_lock:
                stats["answered"] += 1
        except Exception as e:
            error("Send failed to {}: {}".format(addr, e))
            with stats_lock:
                stats["dropped"] += 1
    else:
        with stats_lock:
            stats["dropped"] += 1

# --------------------------------------------------------------------------
# Main Server
# --------------------------------------------------------------------------

def run(port, health_interval, timeout, workers):
    global healthy

    if not resolver_pool:
        error("No resolvers configured. Exiting.")
        sys.exit(1)

    with healthy_lock:
        healthy = list(resolver_pool)

    threading.Thread(target=health_checker, args=(health_interval,), daemon=True).start()
    threading.Thread(target=stats_reporter, daemon=True).start()

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        error("Cannot bind to UDP port {}: {}".format(port, e))
        sys.exit(1)

    try:
        os.makedirs(os.path.dirname(PID_PATH), exist_ok=True)
        with open(PID_PATH, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

    if primary_set:
        mode = "PRIMARY ({} manual)".format(len(primary_set))
    else:
        mode = "BOOTSTRAP (auto-discovery, will find working resolvers)"

    info("=" * 62)
    info("  CHINVAT-MX v1.0.0")
    info("  Port             : UDP {}".format(port))
    info("  Resolvers        : {}".format(len(resolver_pool)))
    info("  Mode             : {}".format(mode))
    info("  Response filter  : NOERROR + ANCOUNT > 0")
    info("  Timeout          : {}s".format(timeout))
    info("  Health interval  : {}s".format(health_interval))
    info("  Proven window    : {}s".format(PROVEN_WINDOW))
    info("  Discovery sample : {}".format(DISCOVERY_SAMPLE))
    info("=" * 62)

    def _shutdown(sig, frame):
        info("Shutdown signal received.")
        shutdown_event.set()
        sock.close()
        try: os.remove(PID_PATH)
        except Exception: pass
        try: os.remove(STATE_PATH)
        except Exception: pass
        sys.exit(0)

    signal.signal(signal.SIGINT,  _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        while not shutdown_event.is_set():
            try:
                sock.settimeout(1.0)
                data, addr = sock.recvfrom(4096)
                pool.submit(handle, data, addr, sock, timeout)
            except socket.timeout:
                continue
            except OSError:
                break
            except Exception as e:
                error("Receive error: {}".format(e))

# --------------------------------------------------------------------------
# Config Loader
# --------------------------------------------------------------------------

def load_config(path):
    try:
        with open(path) as f:
            data = json.load(f)
        resolvers = data.get("resolvers", [])
        primary   = set(data.get("primary", []))
        port      = data.get("port", DEFAULT_PORT)
        return resolvers, primary, port
    except FileNotFoundError:
        return [], set(), DEFAULT_PORT
    except Exception as e:
        warn("Could not read config {}: {}".format(path, e))
        return [], set(), DEFAULT_PORT

# --------------------------------------------------------------------------
# Entry Point
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="chinvat-mx v1.0.0 - DNS multiplexing proxy with auto-discovery",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--port",            "-p", type=int,   default=None)
    parser.add_argument("--resolvers",       "-r", nargs="+",  metavar="IP")
    parser.add_argument("--primary",               nargs="+",  metavar="IP")
    parser.add_argument("--config",          "-c", default=CONFIG_PATH)
    parser.add_argument("--health-interval",       type=int,   default=DEFAULT_HEALTH_INTERVAL)
    parser.add_argument("--timeout",               type=float, default=DEFAULT_TIMEOUT)
    parser.add_argument("--workers",               type=int,   default=DEFAULT_WORKERS)

    args = parser.parse_args()

    global resolver_pool, primary_set

    if args.resolvers:
        resolver_pool = args.resolvers
        primary_set   = set(args.primary) if args.primary else set()
        port = args.port or DEFAULT_PORT
    else:
        resolver_pool, primary_set, config_port = load_config(args.config)
        port = args.port or config_port
        if args.primary:
            primary_set = set(args.primary)

    if not resolver_pool:
        print("Error: No resolvers provided.")
        print()
        print("  python3 chinvat-mx.py --resolvers 10.0.0.1 10.0.0.2 10.0.0.3")
        print()
        print("  Or add via config: sudo ./chinvat-mx.sh add-resolver <IP>")
        sys.exit(1)

    if os.geteuid() != 0 and port < 1024:
        print("Warning: Port {} requires root.".format(port))

    run(port, args.health_interval, args.timeout, args.workers)


if __name__ == "__main__":
    main()
