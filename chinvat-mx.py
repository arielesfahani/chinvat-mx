#!/usr/bin/env python3
"""
chinvat-mx — DNS Multiplexing Proxy
Part of the Chinvat project for high-censorship environments.
Version: 1.0

Fans out incoming DNS queries to a pool of resolvers simultaneously,
returning the first valid response. Dead resolvers are automatically
removed via background health checking.

Architecture:
    Client Device
        │ DNS tunnel query (any stealth port)
        ▼
    chinvat-mx (this script)
        ├──► Resolver 1 ──┐
        ├──► Resolver 2 ──┼──► first response wins ──► Client
        └──► Resolver N ──┘
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

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────

DEFAULT_PORT            = 2053
DEFAULT_TIMEOUT         = 2.0
DEFAULT_HEALTH_INTERVAL = 30
CONFIG_PATH             = "/etc/chinvat/resolvers.json"
LOG_PATH                = "/var/log/chinvat-mx.log"
PID_PATH                = "/var/run/chinvat-mx.pid"

# ──────────────────────────────────────────────────────────────────────────────
# Global State
# ──────────────────────────────────────────────────────────────────────────────

resolver_pool   = []   # All configured resolvers
healthy         = []   # Currently alive resolvers
healthy_lock    = threading.Lock()
shutdown_event  = threading.Event()

stats      = {"total": 0, "answered": 0, "dropped": 0}
stats_lock = threading.Lock()

# ──────────────────────────────────────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────────────────────────────────────

_log_lock = threading.Lock()

def _log(level, msg):
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{level}] {msg}"
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

# ──────────────────────────────────────────────────────────────────────────────
# DNS Utilities
# ──────────────────────────────────────────────────────────────────────────────

def build_health_query():
    """
    Build a minimal valid DNS query (root NS record).
    This is the smallest possible valid DNS query — 17 bytes.
    """
    txid     = random.randint(1, 65535)
    header   = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    question = b'\x00\x00\x02\x00\x01'   # "." NS IN
    return header + question

def is_valid_dns_response(data):
    """
    Check if data looks like a real DNS response.
    We only check the QR bit in the flags — enough to reject garbage.
    """
    if len(data) < 12:
        return False
    flags = struct.unpack(">H", data[2:4])[0]
    return bool(flags & 0x8000)   # QR bit set = response

# ──────────────────────────────────────────────────────────────────────────────
# Resolver Query
# ──────────────────────────────────────────────────────────────────────────────

def query_one(data, resolver_ip, timeout):
    """
    Send a DNS query to a single resolver on port 53.
    Returns the response bytes, or None on failure/timeout.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        sock.sendto(data, (resolver_ip, 53))
        response, _ = sock.recvfrom(4096)
        sock.close()
        return response if is_valid_dns_response(response) else None
    except Exception:
        return None


def fanout(data, resolvers, timeout):
    """
    Send the same DNS query to all resolvers simultaneously.
    Returns the first valid response received.
    All threads are daemon threads — they die when the main process dies.

    Uses a threading.Event so we stop waiting the moment one resolver answers,
    rather than waiting for all of them.
    """
    if not resolvers:
        return None

    winner = [None]
    done   = threading.Event()

    def race(resolver_ip):
        response = query_one(data, resolver_ip, timeout)
        if response and not done.is_set():
            winner[0] = response
            done.set()

    threads = [
        threading.Thread(target=race, args=(r,), daemon=True)
        for r in resolvers
    ]
    for t in threads:
        t.start()

    # Wait at most timeout + a small buffer for the first winner
    done.wait(timeout=timeout + 0.5)
    return winner[0]

# ──────────────────────────────────────────────────────────────────────────────
# Health Checker (background thread)
# ──────────────────────────────────────────────────────────────────────────────

def health_checker(interval):
    """
    Periodically probes every resolver in the pool.
    Updates the global `healthy` list with only the responding ones.
    If ALL resolvers die (transient), falls back to the full pool so
    the proxy keeps running rather than silently dropping everything.
    """
    global healthy
    probe = build_health_query()
    info(f"Health checker started — interval: {interval}s")

    while not shutdown_event.is_set():
        alive, dead = [], []

        for r in resolver_pool:
            if query_one(probe, r, timeout=2.0):
                alive.append(r)
            else:
                dead.append(r)

        with healthy_lock:
            if alive:
                healthy = alive
            else:
                # All resolvers failed — use full pool as a desperate fallback
                healthy = list(resolver_pool)
                warn("All resolvers failed health check — retaining full pool as fallback")

        if dead:
            warn(f"Dead resolvers: {dead}")
        info(f"Alive: {alive if alive else 'none (fallback active)'}")

        shutdown_event.wait(interval)

# ──────────────────────────────────────────────────────────────────────────────
# Stats Reporter (background thread)
# ──────────────────────────────────────────────────────────────────────────────

def stats_reporter():
    """Log a stats summary every 60 seconds."""
    while not shutdown_event.is_set():
        shutdown_event.wait(60)
        with stats_lock:
            s = dict(stats)
        with healthy_lock:
            h = len(healthy)
        info(
            f"Stats — queries: {s['total']} | "
            f"answered: {s['answered']} | "
            f"dropped: {s['dropped']} | "
            f"healthy: {h}/{len(resolver_pool)}"
        )

# ──────────────────────────────────────────────────────────────────────────────
# Per-Query Handler
# ──────────────────────────────────────────────────────────────────────────────

def handle(data, addr, sock, timeout):
    """
    Handle a single incoming DNS query.
    Called in a daemon thread for each received packet.
    """
    with stats_lock:
        stats["total"] += 1

    with healthy_lock:
        resolvers = list(healthy)

    response = fanout(data, resolvers, timeout)

    if response:
        try:
            sock.sendto(response, addr)
            with stats_lock:
                stats["answered"] += 1
        except Exception as e:
            error(f"Send failed to {addr}: {e}")
            with stats_lock:
                stats["dropped"] += 1
    else:
        warn(f"No resolver answered query from {addr[0]}:{addr[1]}")
        with stats_lock:
            stats["dropped"] += 1

# ──────────────────────────────────────────────────────────────────────────────
# Main Server
# ──────────────────────────────────────────────────────────────────────────────

def run(port, health_interval, timeout):
    global healthy

    if not resolver_pool:
        error("No resolvers configured. Exiting.")
        sys.exit(1)

    # Seed healthy pool before first health check runs
    with healthy_lock:
        healthy = list(resolver_pool)

    # Start background threads
    threading.Thread(
        target=health_checker, args=(health_interval,), daemon=True
    ).start()
    threading.Thread(
        target=stats_reporter, daemon=True
    ).start()

    # Bind UDP socket
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", port))
    except OSError as e:
        error(f"Cannot bind to UDP port {port}: {e}")
        sys.exit(1)

    # Write PID file
    try:
        os.makedirs(os.path.dirname(PID_PATH), exist_ok=True)
        with open(PID_PATH, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

    info("=" * 54)
    info("  CHINVAT MULTIPLEXER STARTED")
    info(f"  Listen port      : UDP {port}")
    info(f"  Resolver pool    : {resolver_pool}")
    info(f"  Health interval  : {health_interval}s")
    info(f"  Per-query timeout: {timeout}s")
    info("=" * 54)

    # Graceful shutdown on SIGINT / SIGTERM
    def _shutdown(sig, frame):
        info("Shutdown signal received.")
        shutdown_event.set()
        sock.close()
        try:
            os.remove(PID_PATH)
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGINT,  _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    # Main receive loop — one daemon thread per incoming query
    while not shutdown_event.is_set():
        try:
            sock.settimeout(1.0)
            data, addr = sock.recvfrom(4096)
            threading.Thread(
                target=handle,
                args=(data, addr, sock, timeout),
                daemon=True
            ).start()
        except socket.timeout:
            continue
        except OSError:
            break
        except Exception as e:
            error(f"Receive error: {e}")

# ──────────────────────────────────────────────────────────────────────────────
# Config Loader
# ──────────────────────────────────────────────────────────────────────────────

def load_config(path):
    try:
        with open(path) as f:
            return json.load(f).get("resolvers", [])
    except FileNotFoundError:
        return []
    except Exception as e:
        warn(f"Could not read config {path}: {e}")
        return []

# ──────────────────────────────────────────────────────────────────────────────
# Entry Point
# ──────────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="chinvat-mx — DNS multiplexing proxy for high-censorship environments",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  # inline resolvers
  python3 chinvat-mx.py --port 2053 --resolvers 10.0.0.1 10.0.0.2 10.0.0.3

  # from config file
  python3 chinvat-mx.py --port 2053 --config /etc/chinvat/resolvers.json

  # custom timeout and health interval
  python3 chinvat-mx.py --port 443 --resolvers 10.0.0.1 --timeout 3 --health-interval 60
        """
    )
    parser.add_argument(
        "--port", "-p",
        type=int, default=DEFAULT_PORT,
        help=f"UDP port to listen on (default: {DEFAULT_PORT})"
    )
    parser.add_argument(
        "--resolvers", "-r",
        nargs="+", metavar="IP",
        help="Resolver IPs to use — overrides config file"
    )
    parser.add_argument(
        "--config", "-c",
        default=CONFIG_PATH,
        help=f"Path to resolver config JSON (default: {CONFIG_PATH})"
    )
    parser.add_argument(
        "--health-interval",
        type=int, default=DEFAULT_HEALTH_INTERVAL,
        help=f"Seconds between health checks (default: {DEFAULT_HEALTH_INTERVAL})"
    )
    parser.add_argument(
        "--timeout",
        type=float, default=DEFAULT_TIMEOUT,
        help=f"Per-resolver query timeout in seconds (default: {DEFAULT_TIMEOUT})"
    )

    args = parser.parse_args()

    global resolver_pool
    resolver_pool = args.resolvers if args.resolvers else load_config(args.config)

    if not resolver_pool:
        print("Error: No resolvers provided.")
        print()
        print("  Option 1 — inline:")
        print("    python3 chinvat-mx.py --port 2053 --resolvers 10.0.0.1 10.0.0.2")
        print()
        print("  Option 2 — config file:")
        print('    echo \'{"resolvers": ["10.0.0.1", "10.0.0.2"]}\' > /etc/chinvat/resolvers.json')
        print("    python3 chinvat-mx.py --port 2053")
        sys.exit(1)

    if os.geteuid() != 0 and args.port < 1024:
        print(f"Warning: Port {args.port} requires root. Run with sudo.")

    run(args.port, args.health_interval, args.timeout)


if __name__ == "__main__":
    main()
