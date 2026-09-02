#!/usr/bin/env bash
# ============================================================================
# GlukVPN node - forwarding doctor
#
#   sudo bash fix-forwarding.sh            # report, then repair
#   sudo bash fix-forwarding.sh --report   # report only, change nothing
#
# Safe by construction: nothing is ever flushed, no existing rule is deleted,
# and every rule is checked with -C before being inserted. Running it twice
# changes nothing the second time. An SSH session cannot be lost by it.
#
# WHY THIS EXISTS
#
# wg0.conf.example carries the PostUp lines that turn the node into a router,
# but they only ever run if that template was installed with <EGRESS_IF>
# actually filled in. A node whose /etc/wireguard/wg0.conf was written by hand
# runs WireGuard perfectly - handshakes succeed, peers appear, counters move -
# while every forwarded packet falls through to the REJECT rule that Oracle
# Cloud images ship at the end of the FORWARD chain.
#
# The client then sees the worst possible symptom: a tunnel that is up and
# authenticated, with no internet behind it. And because REJECT answers each
# packet with an ICMP refusal, the tunnel byte counters grow in BOTH
# directions - which looks like a working data path until you notice the
# inbound bytes are refusals, not replies.
# ============================================================================
set -uo pipefail

WG_IF="${WG_IF:-wg0}"
TUN_NET="${TUN_NET:-10.8.0.0/24}"

REPORT_ONLY=0
if [ "${1:-}" = "--report" ]; then
  REPORT_ONLY=1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this with sudo." >&2
  exit 1
fi

IPT="iptables -w 5"

say() {
  printf '\n=== %s\n' "$1"
}

EGRESS="${EGRESS_IF:-}"
if [ -z "$EGRESS" ]; then
  EGRESS="$(ip route show default | awk '/default/ {print $5; exit}')"
fi

say "what this node looks like"
echo "tunnel interface : $WG_IF"
echo "tunnel subnet    : $TUN_NET"
echo "egress interface : ${EGRESS:-NONE FOUND}"
echo "ip_forward       : $(cat /proc/sys/net/ipv4/ip_forward)"

if [ -z "$EGRESS" ]; then
  echo
  echo "No default route found, so the uplink interface cannot be detected."
  echo "Re-run as: sudo EGRESS_IF=enp0s6 bash fix-forwarding.sh"
  exit 1
fi

if ! ip link show "$WG_IF" >/dev/null 2>&1; then
  echo
  echo "Interface $WG_IF does not exist. Start it first: sudo wg-quick up $WG_IF"
  exit 1
fi

say "peers as WireGuard sees them"
# The endpoint column is the tell. A peer whose endpoint is an address from
# inside the tunnel means the client's own encrypted packets are looping back
# into the tunnel instead of leaving through its physical adapter.
wg show "$WG_IF" || true

say "addresses and routes on $WG_IF"
ip -brief address show "$WG_IF" || true
ip route show table all dev "$WG_IF" || true

say "FORWARD chain, with packet counters and line numbers"
# Read this from the top down: the first matching rule wins. If a REJECT or
# DROP appears ABOVE the two ACCEPT rules for the tunnel, forwarding is dead
# no matter how correct everything else is.
$IPT -L FORWARD -v -n --line-numbers || true

say "NAT, so replies can find their way back"
$IPT -t nat -S POSTROUTING || true

BLOCKER="$($IPT -L FORWARD -n --line-numbers 2>/dev/null | awk '$2 == "REJECT" || $2 == "DROP" {print $1; exit}')"
if [ -n "${BLOCKER:-}" ]; then
  echo
  echo "First blocking rule in FORWARD is at line $BLOCKER."
  echo "Our ACCEPT rules must sit above it, which is why they are inserted at 1 and 2."
fi

if [ "$REPORT_ONLY" -eq 1 ]; then
  say "report only, nothing was changed"
  exit 0
fi

say "snapshot before touching anything"
SNAPSHOT="/root/iptables-before-glukvpn-$(date +%Y%m%d-%H%M%S).rules"
iptables-save > "$SNAPSHOT"
echo "saved to $SNAPSHOT"
echo "to undo everything below: sudo iptables-restore < $SNAPSHOT"

say "repair"

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  sysctl -q -w net.ipv4.ip_forward=1
  echo "turned ip_forward on"
else
  echo "ip_forward was already on"
fi
# Survive a reboot.
if [ ! -f /etc/sysctl.d/99-glukvpn.conf ]; then
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-glukvpn.conf
  echo "persisted ip_forward in /etc/sysctl.d/99-glukvpn.conf"
fi

# Tunnel -> uplink. Inserted at 1 so it lands above any REJECT.
if $IPT -C FORWARD -i "$WG_IF" -o "$EGRESS" -j ACCEPT 2>/dev/null; then
  echo "FORWARD $WG_IF -> $EGRESS already allowed"
else
  $IPT -I FORWARD 1 -i "$WG_IF" -o "$EGRESS" -j ACCEPT
  echo "allowed FORWARD $WG_IF -> $EGRESS"
fi

# Uplink -> tunnel, replies only.
if $IPT -C FORWARD -i "$EGRESS" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  echo "FORWARD $EGRESS -> $WG_IF (established) already allowed"
else
  $IPT -I FORWARD 2 -i "$EGRESS" -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  echo "allowed FORWARD $EGRESS -> $WG_IF for replies"
fi

# Source NAT for the tunnel subnet.
if $IPT -t nat -C POSTROUTING -s "$TUN_NET" -o "$EGRESS" -j MASQUERADE 2>/dev/null; then
  echo "MASQUERADE for $TUN_NET already present"
else
  $IPT -t nat -I POSTROUTING 1 -s "$TUN_NET" -o "$EGRESS" -j MASQUERADE
  echo "added MASQUERADE for $TUN_NET"
fi

# MSS clamping, so TCP still works when the path MTU is smaller than ours.
if $IPT -t mangle -C FORWARD -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
  echo "MSS clamping already present"
else
  $IPT -t mangle -I FORWARD 1 -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  echo "added MSS clamping"
fi

# Let the node answer pings from inside the tunnel, so the client's latency
# readout stops showing dashes.
if $IPT -C INPUT -i "$WG_IF" -j ACCEPT 2>/dev/null; then
  echo "INPUT from $WG_IF already allowed"
else
  $IPT -I INPUT 1 -i "$WG_IF" -j ACCEPT
  echo "allowed INPUT from $WG_IF"
fi

say "FORWARD chain after the repair"
$IPT -L FORWARD -v -n --line-numbers || true

say "done"
echo "Reconnect the client and try again. The counters to watch are the two"
echo "ACCEPT rules above: if traffic now flows, their packet counts climb."
echo
echo "These rules live in memory. To keep them across reboots either install"
echo "the PostUp lines from wg0.conf.example into /etc/wireguard/$WG_IF.conf,"
echo "or install iptables-persistent and run: sudo netfilter-persistent save"
