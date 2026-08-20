# GlukVPN node agent

Runs on every VPN node (Germany today, DE-02 / US-01 / FR-01 later). It is the only
component allowed to touch WireGuard on the node.

```
control plane (api.gluk.tech)          this node
─────────────────────────          ─────────
        ▲  outbound HTTPS only          agent (vpnagent user, CAP_NET_ADMIN)
        │  heartbeat / commands / report  │
        │                                ▼
                                       wg0 (kernel WireGuard)
```

## What it does

| Task | Detail |
| --- | --- |
| Enrollment | exchanges a one-time enrollment token for a node-specific token |
| Heartbeat | every `HEARTBEAT_INTERVAL_SEC` (10s): CPU, RAM, uptime, peer count, agent version, node WireGuard public key |
| Command channel | the heartbeat response carries `ADD_PEER` / `REMOVE_PEER` / `SYNC_PEERS`; each command is acked |
| Statistics | every `STATS_REPORT_INTERVAL_SEC` (30s): per-peer `bytesRx` / `bytesTx` / last handshake from `wg show wg0 dump` |
| Drift repair | peers with no live session are removed; sessions with no peer are reported back |
| Token rotation | rotates the node token 3 days before expiry and rewrites the env file |

## What it deliberately cannot do

- no PostgreSQL access — HTTPS API only;
- no inbound port: the agent only makes outbound requests, so no management port is exposed;
- no arbitrary command execution: the handler is a closed `switch` over three command
  types, and `wg` is called through `execFile` with a validated argv (no shell);
- no traffic inspection: only byte counters and handshake timestamps, never payloads,
  URLs or DNS queries;
- no client private keys: peers are added from a public key that the phone generated.

## Files

```
node-agent/
  src/
    agent.ts               main loop (heartbeat -> commands -> report)
    config.ts              env loading + validation, credential persistence
    lib/api.ts             HTTPS client (Bearer node token + X-Node-Id)
    lib/wg.ts              `wg` wrapper: dump / add peer / remove peer
    lib/metrics.ts         CPU, RAM, uptime, interface counters
    lib/logger.ts          JSON logs with secret redaction
    scripts/enroll.ts      one-time enrollment
  deploy/
    vpn-node-agent.service systemd unit (hardened, CAP_NET_ADMIN only)
    wg0.conf.example       WireGuard interface template (no peers inside)
  .env.example
```

## Install (Ubuntu 24.04)

All commands are shown before they are run, and each one says what it changes.
Run them as a user with sudo on the **node**, not on the control server.

### 1. Packages

```bash
# installs WireGuard tools and Node.js 20; changes nothing else
sudo apt-get update
sudo apt-get install -y wireguard-tools
node --version   # need >= 18; install Node 20 if missing
```

### 2. Node key pair and wg0

```bash
# generates the node private key (stays on this machine forever)
sudo install -d -m 700 /etc/wireguard
umask 077 && wg genkey | sudo tee /etc/wireguard/node.key >/dev/null
sudo cat /etc/wireguard/node.key | wg pubkey    # this public key is safe to share

# uplink interface name, needed for NAT below
ip route show default
```

Copy `deploy/wg0.conf.example` to `/etc/wireguard/wg0.conf`, then replace
`<NODE_PRIVATE_KEY>` and `<EGRESS_IF>`.

> **What this changes:** brings up a new `wg0` interface on UDP 51820, sets
> `net.ipv4.ip_forward=1` (the host starts routing), inserts one MASQUERADE rule
> and two FORWARD rules. Existing services, SSH and aaPanel are untouched, but the
> rules must be **inserted before** the Oracle Cloud `REJECT` rule — the template
> already uses `-I ... 1` for that. Snapshot first: `sudo iptables-save > ~/iptables.before`.

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
sudo wg show wg0            # interface up, 0 peers
```

### 3. Agent user and directories

```bash
# unprivileged service account, no login shell, no home directory content
sudo useradd --system --no-create-home --shell /usr/sbin/nologin vpnagent

sudo install -d -o vpnagent -g vpnagent -m 750 /opt/vpn-node-agent
sudo install -d -o vpnagent -g vpnagent -m 700 /etc/vpn-node-agent
```

### 4. Deploy the build

Build locally, copy `dist/`, `package.json`, `package-lock.json` and `node_modules`
(or run `npm ci --omit=dev` on the node):

```bash
sudo -u vpnagent cp -r dist package.json /opt/vpn-node-agent/
cd /opt/vpn-node-agent && sudo -u vpnagent npm ci --omit=dev
```

### 5. Configuration

```bash
sudo cp .env.example /etc/vpn-node-agent/agent.env
sudo chown vpnagent:vpnagent /etc/vpn-node-agent/agent.env
sudo chmod 600 /etc/vpn-node-agent/agent.env
sudo -e /etc/vpn-node-agent/agent.env
```

Fill in:

| Key | Value |
| --- | --- |
| `CONTROL_API_URL` | `https://api.gluk.tech` |
| `NODE_NAME` | `de-01` (lowercase, digits, dashes) |
| `NODE_COUNTRY` / `NODE_COUNTRY_CODE` | `Germany` / `DE` — must match reality |
| `NODE_PUBLIC_IP` | public IPv4 of this node (auto-detected if empty) |
| `NODE_ENROLLMENT_TOKEN` | one-time token from the control server |
| `WG_*` | must match `/etc/wireguard/wg0.conf` |

The file is owned by `vpnagent` because the agent rewrites it when the node token
rotates. It contains the node token — never commit it, never copy it around.

### 6. Enrollment

On the **control server**:

```bash
cd /opt/vpn-control && npm run cli -- nodes:token --note de-01
```

The token is printed once. Paste it into `NODE_ENROLLMENT_TOKEN`, then on the node:

```bash
sudo -u vpnagent ENV_FILE=/etc/vpn-node-agent/agent.env \
  node /opt/vpn-node-agent/dist/scripts/enroll.js
```

On success the script writes `NODE_ID` and `NODE_TOKEN` into the env file, clears
`NODE_ENROLLMENT_TOKEN`, and prints the node id (never the token).

### 7. Service

```bash
sudo cp deploy/vpn-node-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-node-agent
sudo systemctl status vpn-node-agent --no-pager
sudo journalctl -u vpn-node-agent -f
```

Within 10 seconds the node shows up as **Online** in the admin panel.

## Verify

```bash
sudo wg show wg0                       # peers appear on connect, vanish on disconnect
sudo journalctl -u vpn-node-agent -n 50
sudo iptables -t nat -S POSTROUTING    # exactly one MASQUERADE for 10.8.0.0/24
cat /proc/sys/net/ipv4/ip_forward      # 1
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| exit code 78 right after start | bad config or revoked credential; the unit stops on purpose. Check `journalctl`, fix the env file, re-enroll with `--force` |
| `wg show` fails with permission denied | the unit is missing `AmbientCapabilities=CAP_NET_ADMIN`, or you ran the agent as a plain user |
| node stays Offline | outbound HTTPS to `api.gluk.tech` blocked, wrong `CONTROL_API_URL`, or heartbeats rejected (see journal) |
| tunnel connects, no internet | `ip_forward=0`, missing MASQUERADE, wrong `<EGRESS_IF>`, or the FORWARD rules landed after the Oracle `REJECT` rule |
| slow / stalled downloads | MTU: try `WG_MTU=1380` in both wg0.conf and the env file |

## Uninstall

```bash
sudo systemctl disable --now vpn-node-agent
sudo rm /etc/systemd/system/vpn-node-agent.service
sudo systemctl daemon-reload
sudo systemctl disable --now wg-quick@wg0      # removes the interface and its NAT rules
sudo rm -rf /opt/vpn-node-agent /etc/vpn-node-agent
sudo userdel vpnagent
# optional, only if you no longer want WireGuard at all:
# sudo rm -rf /etc/wireguard
```

Remove the node from the control plane too:
`npm run cli -- nodes:delete de-01` (refuses while sessions are live).
