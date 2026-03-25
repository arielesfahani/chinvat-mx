# chinvat-mx# 🔀 chinvat-mx

DNS Multiplexing Proxy — part of the [Chinvat](https://github.com/arielesfahani/chinvat) project.

Fans out incoming DNS queries to a **pool of resolvers simultaneously**, returning the first valid response. Dead resolvers are removed automatically via background health checking.

---

## Why Multiplexing?

The original Chinvat relay (iptables DNAT) solves the *client-side* problem: getting your DNS tunnel traffic off port 53 and through the datacenter backbone without ISP poisoning. But it has a single point of failure — one resolver, and if it dies, the tunnel dies with it.

During active blackouts, DPI systems eventually detect tunneling patterns even through the datacenter. The solution is **DNS multiplexing**:

> *"Datacenters have much fewer restrictions on DNS traffic compared to mobile ISPs. The idea is to send your DNS request to a datacenter which acts as a middle proxy that multiplexes the request over multiple servers simultaneously — all going through a single firewall that is far less restrictive than mobile ISP firewalls."*

What this achieves:

- **Redundancy** — if one resolver dies mid-session, another answers before your client even notices
- **DPI evasion** — a single resolver being hammered with DNSTT queries is a detectable pattern; traffic spread across 5–10 resolvers looks like normal datacenter DNS noise
- **Speed** — the first resolver to answer wins, so you get the fastest response from the pool on every query

---

## Architecture

```
Client Device
    │
    │  DNS tunnel packets (port 443, 2053, or any stealth port)
    │  Looks like normal traffic to ISP
    ▼
Iranian VPS  ←── chinvat-mx is running here
    │
    ├──► Iranian Resolver 1 (datacenter backbone) ──┐
    ├──► Iranian Resolver 2 (datacenter backbone) ──┼──► first response wins ──► Client
    ├──► Iranian Resolver 3 (datacenter backbone) ──┘
    └──► ... up to N resolvers
              │
              ▼
        t.yourdomain.com  (your DNSTT authoritative nameserver, foreign)
```

The VPS sits on the datacenter backbone network which has different routing rules than consumer ISP lines — it can reach resolvers and complete lookups that are completely blocked on your phone or home connection.

---

## Requirements

- Python 3 (standard library only — no pip, no apt, no external packages)
- Root access to bind low ports, or run on port 2053+

---

## Installation

### 1. Download

```bash
curl -O https://raw.githubusercontent.com/arielesfahani/chinvat/main/chinvat-mx.py
curl -O https://raw.githubusercontent.com/arielesfahani/chinvat/main/chinvat-mx.sh
chmod +x chinvat-mx.sh
```

### 2. Install as a systemd service

```bash
sudo ./chinvat-mx.sh install
```

### 3. Add your resolver pool

Add as many Iranian resolvers as you have. More resolvers = more redundancy and better DPI evasion.

```bash
sudo ./chinvat-mx.sh add-resolver 2.188.21.20
sudo ./chinvat-mx.sh add-resolver 185.55.225.25
sudo ./chinvat-mx.sh add-resolver 78.157.42.100
```

### 4. Start

```bash
sudo ./chinvat-mx.sh start
```

### 5. Configure your client

| Parameter       | Value                           |
|-----------------|---------------------------------|
| DNS Transport   | UDP                             |
| DNS Resolver IP | `YOUR_IRAN_VPS_IP`              |
| Resolver Port   | `2053` *(or your chosen port)*  |

---

## Usage

```
sudo ./chinvat-mx.sh <command>

  install                  Install as a systemd service
  start                    Start the multiplexer
  stop                     Stop the multiplexer
  restart                  Restart the multiplexer
  status                   Show status, resolver health, recent logs
  add-resolver <IP>        Add a resolver to the pool
  remove-resolver <IP>     Remove a resolver from the pool
  list-resolvers           List all configured resolvers
  logs                     Tail the live log
```

### Custom port

The default listen port is `2053`. To use a different port:

```bash
CHINVAT_PORT=443 sudo ./chinvat-mx.sh start
```

Or run the Python script directly with full control:

```bash
sudo python3 chinvat-mx.py \
  --port 2053 \
  --resolvers 2.188.21.20 185.55.225.25 78.157.42.100 \
  --timeout 2 \
  --health-interval 30
```

---

## Monitoring

### Status and resolver health

```bash
sudo ./chinvat-mx.sh status
```

This shows which resolvers are currently alive, which are dead, and recent log output.

### Live log

```bash
sudo ./chinvat-mx.sh logs
```

Stats are logged every 60 seconds:

```
[INFO] Stats — queries: 1204 | answered: 1198 | dropped: 6 | healthy: 4/5
```

### Health checker behavior

- Probes every resolver every 30 seconds (configurable)
- Dead resolvers are removed from the active pool automatically
- If **all** resolvers fail simultaneously (transient), the full pool is retained as a fallback rather than dropping all queries
- Logs clearly distinguish alive vs. dead resolvers after each probe cycle

---

## How It Works Internally

1. **Receive** — A UDP DNS query arrives from the client on the listen port
2. **Fanout** — The query is sent simultaneously to every healthy resolver in the pool, each in its own thread
3. **Race** — A `threading.Event` fires the moment any resolver returns a valid response
4. **Return** — The winning response is sent back to the client; remaining threads time out quietly
5. **Health** — A background thread probes all resolvers on a fixed interval and updates the healthy pool

The per-query overhead is minimal: UDP socket open → send → receive, repeated N times in parallel. All threads are daemon threads and require no cleanup.

---

## ⚠️ Notes

> **Resolver selection matters.** During a hard blackout, not all Iranian resolvers can complete lookups for foreign DNSTT domains. Use resolvers that you have verified work from the VPS — run `dig t.yourdomain.com @<resolver-ip>` to test before adding to the pool.

> **Cloud firewalls.** Ensure your chosen port is open for UDP in your VPS provider's dashboard (ArvanCloud, ParsPack, etc.) — iptables rules alone are not enough if the provider-level firewall blocks the port upstream.

> **Port conflicts.** If running x-ui or Xray on the same server, avoid port 443. Use 2053, 2083, or 8443.

> **Persistence.** If installed via systemd, the multiplexer starts automatically on reboot.

---

## Relation to Chinvat (iptables relay)

| | Chinvat (iptables) | chinvat-mx (this) |
|---|---|---|
| Method | Kernel-level DNAT | Application-layer proxy |
| Resolvers | One at a time | Pool, all in parallel |
| Failover | Manual re-run | Automatic health checking |
| DPI evasion | Port camouflage only | Port camouflage + traffic distribution |
| Dependencies | None (bash + iptables) | Python 3 stdlib only |

They can coexist or you can use chinvat-mx standalone. chinvat-mx does not require iptables rules.

---

## License

GNU General Public License v3.0

---

*Stay Connected. Crossing the bridge together.*
