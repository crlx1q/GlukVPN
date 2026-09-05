#!/usr/bin/env bash
# Installs the sing-box VLESS+TLS gateway on a GlukVPN node.
#
# ROUND 24. This is the other half of the Windows engine change: the desktop
# service now speaks VLESS over TLS instead of WireGuard over UDP, so the node
# needs a listener that talks it. To a provider's DPI equipment the result is
# indistinguishable from an ordinary HTTPS site, which is the whole point -
# plain WireGuard on UDP 51820 is fingerprinted by its header and throttled
# after the handshake.
#
# Note what is NOT here: no ip_forward, no MASQUERADE, no FORWARD rules, no
# MTU clamping. sing-box terminates the client's connections and re-opens them
# from the node itself, so the kernel never has to route foreign packets. The
# entire class of forwarding problems from rounds 19-22 does not exist on this
# path.
#
# Usage (one command, as root):
#   ./install-singbox.sh --domain de-01.gluk.tech
#
# Options:
#   --domain <fqdn>   certificate name the client will verify (required)
#   --port <n>        TCP port to listen on (default 443)
#   --cert <path>     TLS certificate chain (default: letsencrypt for domain)
#   --key <path>      TLS private key (default: letsencrypt for domain)
#   --uuid <uuid>     reuse an existing credential instead of generating one

set -euo pipefail

DOMAIN=""
PORT="443"
CERT=""
KEY=""
UUID=""

CONFIG_DIR="/etc/glukvpn"
CONFIG="$CONFIG_DIR/singbox.json"
BIN="/usr/local/bin/sing-box"
UNIT="/etc/systemd/system/glukvpn-singbox.service"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

note() { printf '\n== %s\n' "$1"; }
fail() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --port)   PORT="${2:-}"; shift 2 ;;
    --cert)   CERT="${2:-}"; shift 2 ;;
    --key)    KEY="${2:-}"; shift 2 ;;
    --uuid)   UUID="${2:-}"; shift 2 ;;
    -h|--help) sed -n '1,25p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || fail "run this as root"
[ -n "$DOMAIN" ] || fail "--domain is required, e.g. --domain de-01.gluk.tech"

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed"
done

# ---------------------------------------------------------------------------
# Certificates. The browser gateway on this node already terminates TLS for
# the same domain, so in practice these files exist.
# ---------------------------------------------------------------------------
if [ -z "$CERT" ]; then
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
fi
if [ -z "$KEY" ]; then
  KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
fi
[ -r "$CERT" ] || fail "certificate not readable: $CERT (pass --cert)"
[ -r "$KEY" ] || fail "private key not readable: $KEY (pass --key)"

# ---------------------------------------------------------------------------
# Port. Fail loudly instead of colliding silently: 8443 and 8444 already
# belong to the prod and beta browser proxies on this node.
# ---------------------------------------------------------------------------
if command -v ss >/dev/null 2>&1; then
  if [ -n "$(ss -ltnH "sport = :$PORT" 2>/dev/null || true)" ]; then
    printf 'Port %s is already in use:\n' "$PORT" >&2
    ss -ltnp "sport = :$PORT" >&2 || true
    fail "choose a free port with --port"
  fi
fi

if [ -z "$UUID" ]; then
  if [ -r "$CONFIG_DIR/vless-uuid" ]; then
    UUID="$(cat "$CONFIG_DIR/vless-uuid")"
  else
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
fi

# ---------------------------------------------------------------------------
# Official release, the same source as the Windows payload.
# ---------------------------------------------------------------------------
note "Fetching the latest official sing-box release"
LATEST_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
DOWNLOAD_BASE="https://github.com/SagerNet/sing-box/releases/download"

TAG="$(curl -fsSL "$LATEST_API" 2>/dev/null | grep '"tag_name"' | head -n1 | cut -d'"' -f4)"
[ -n "$TAG" ] || fail "could not resolve the latest sing-box release"
VERSION="${TAG#v}"
ARCH="amd64"
case "$(uname -m)" in
  aarch64|arm64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="amd64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac
ARCHIVE="sing-box-$VERSION-linux-$ARCH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/singbox.tar.gz" "$DOWNLOAD_BASE/$TAG/$ARCHIVE.tar.gz"
tar -xzf "$TMP/singbox.tar.gz" -C "$TMP"
install -m 0755 "$TMP/$ARCHIVE/sing-box" "$BIN"
printf 'installed %s as %s\n' "$TAG" "$BIN"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
note "Writing $CONFIG"
install -d -m 0750 "$CONFIG_DIR"
printf '%s\n' "$UUID" > "$CONFIG_DIR/vless-uuid"
chmod 0600 "$CONFIG_DIR/vless-uuid"

cat > "$CONFIG" <<JSON
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "gluk",
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
JSON
chmod 0600 "$CONFIG"
"$BIN" check -c "$CONFIG" || fail "sing-box rejected the generated configuration"

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------
note "Installing $UNIT"
cat > "$UNIT" <<UNITFILE
[Unit]
Description=GlukVPN sing-box VLESS gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=3
# Renewed certificates are picked up on restart, so certbot's deploy hook can
# reload this unit the same way it reloads the browser gateway.
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNITFILE

systemctl daemon-reload
systemctl enable --now glukvpn-singbox.service
sleep 2
systemctl is-active --quiet glukvpn-singbox.service \
  || fail "the service did not stay up - journalctl -u glukvpn-singbox -n 50"

# Install the idempotent OUTPUT + VPN-scoped FORWARD safeguards. This never
# flushes firewall chains or touches INPUT/SSH. The oneshot reapplies missing
# rules after reboot; operators can inspect its --dry-run output first.
if [ -f "$SCRIPT_DIR/glukvpn-egress-guard.sh" ] && [ -f "$SCRIPT_DIR/glukvpn-egress-guard.service" ]; then
  note "Installing GlukVPN egress safeguards"
  install -m 0755 "$SCRIPT_DIR/glukvpn-egress-guard.sh" /usr/local/sbin/glukvpn-egress-guard
  install -m 0644 "$SCRIPT_DIR/glukvpn-egress-guard.service" /etc/systemd/system/glukvpn-egress-guard.service
  systemctl daemon-reload
  systemctl enable --now glukvpn-egress-guard.service
fi

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------
if command -v iptables >/dev/null 2>&1; then
  if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    printf 'opened TCP %s in the local firewall\n' "$PORT"
    command -v netfilter-persistent >/dev/null 2>&1 \
      && netfilter-persistent save >/dev/null 2>&1 || true
  fi
fi

note "Done"
cat <<SUMMARY
sing-box $TAG is listening on TCP $PORT for $DOMAIN.

One thing this script cannot do for you: on Oracle Cloud the port also has to
be allowed in the instance's security list, or the packets never reach the
node. Add an ingress rule for TCP $PORT if there is not one already.

Hand this to the control plane so the desktop app sends it with "up":

  "gateway": {
    "type": "vless",
    "host": "$DOMAIN",
    "port": $PORT,
    "uuid": "$UUID",
    "flow": "xtls-rprx-vision"
  }

The credential is also stored in $CONFIG_DIR/vless-uuid.
SUMMARY
