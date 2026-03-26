# chinvat-mx

DNS multiplexing proxy for high-censorship environments. Part of the [Chinvat](https://github.com/arielesfahani/chinvat) project.

Fan out DNS tunnel queries to a pool of resolvers simultaneously. The system automatically discovers which resolvers carry tunnel traffic and prioritizes them.

## How It Works

```
Client (dnstt / SlipNet)
    │ DNS tunnel query
    ▼
chinvat-mx
    ├──► Resolver 1 ──┐
    ├──► Resolver 2 ──┼──► first valid response wins ──► Client
    └──► Resolver N ──┘
         (SERVFAIL and empty responses discarded)
```

### Auto-Discovery

The key insight: **dnstt-server always responds with answer records** (`ANCOUNT > 0`) — that's where encoded tunnel data lives. Non-working resolvers return either `SERVFAIL` or empty `NOERROR` with `ANCOUNT = 0` (from MTU truncation or response modification).

Using `ANCOUNT > 0` as a filter automatically separates working from non-working resolvers at the DNS level:

1. **Bootstrap** — tries all resolvers. Only responses with `NOERROR + ANCOUNT > 0` accepted. Working resolvers win the race, get auto-promoted to "proven."
2. **Proven** — future queries use only proven resolvers + small discovery sample of unproven ones.
3. **Primary** (optional) — manually verified resolvers via `set-primary`. When set, only these handle traffic.

In normal conditions where all resolvers work, every response qualifies and the first one wins — same behavior as a simple DNS proxy.

## Quick Start

```bash
# Install
sudo ./chinvat-mx.sh install

# Add resolvers (as many as you want — system will discover which ones work)
sudo ./chinvat-mx.sh add-resolver 2.188.21.90
sudo ./chinvat-mx.sh add-resolver 2.188.21.100
sudo ./chinvat-mx.sh add-resolver 194.53.122.123
# ... add more

# Optional: mark known-working resolvers as primary
sudo ./chinvat-mx.sh set-primary 2.188.21.90

# Start
sudo ./chinvat-mx.sh start

# Check status (shows which resolvers are carrying traffic)
sudo ./chinvat-mx.sh status
```

## Commands

| Command | Description |
|---|---|
| `install` | Install as systemd service |
| `uninstall` | Remove everything |
| `start` / `stop` / `restart` | Service control |
| `status` | Health, proven resolvers, recent logs |
| `add-resolver <IP>` | Add a resolver to the pool |
| `remove-resolver <IP>` | Remove a resolver |
| `set-primary <IP>` | Mark as primary (tunnel-verified) |
| `unset-primary <IP>` | Remove primary status |
| `list-resolvers` | List all configured resolvers |
| `logs` | Tail live log |

## Resolver Hierarchy

| Tier | Source | Used for |
|---|---|---|
| **Primary** | Manual (`set-primary`) | All tunnel traffic when set |
| **Proven** | Auto-discovered (won races) | Preferred + discovery sample |
| **Pool** | All configured resolvers | Health-checked, discovery |

## Status Output

```
Primary (tunnel traffic):
  * 2.188.21.90   responding  47 wins, last 3s ago
  * 2.188.21.100  responding  221 wins, last 5s ago

Proven (auto-discovered, carrying traffic):
  * 194.53.122.20  responding  430 wins, last 1s ago

Pool (health-checked, discovery):
  * 5.160.139.18   responding
  * 77.237.87.189  not responding

Summary: 2 primary + 1 proven + 1 healthy + 1 dead
```

## Architecture

- **Health check**: Generic DNS probe (QR bit only). Keeps all DNS-reachable resolvers in pool regardless of RCODE.
- **Fanout filter**: `NOERROR + ANCOUNT > 0`. Rejects SERVFAIL and empty responses. Waits for a response with actual tunnel data.
- **Concurrency**: `ThreadPoolExecutor` with thread-per-resolver race. First qualifying response wins.
- **Auto-promotion**: Resolvers that win races are tracked. After accumulating wins, they're promoted to "proven" and prioritized.
- **Proven window**: 10 minutes. Resolvers must keep winning to stay proven. If a resolver stops working, it's demoted after the window expires.
- **Discovery sample**: 3 unproven resolvers included per query when in proven mode, ensuring new working resolvers are discovered.

## Configuration

Config file: `/etc/chinvat/resolvers.json`

```json
{
  "resolvers": ["2.188.21.90", "2.188.21.100", "194.53.122.123"],
  "primary": ["2.188.21.90"],
  "port": 2053
}
```

## Requirements

- Python 3.6+
- Linux (systemd for service management)
- No external dependencies — pure stdlib

## License

[MIT](LICENSE)
