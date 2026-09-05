#!/usr/bin/env bash
# Idempotent egress safeguards for a GlukVPN node.
# Adds only narrowly scoped rules; never flushes or changes INPUT/SSH rules.
set -euo pipefail

WG_IF="${WG_IF:-wg0}"
WG_SUBNET="${WG_SUBNET:-10.8.0.0/24}"
WG_IPV6_SUBNET="${WG_IPV6_SUBNET:-}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ "$DRY_RUN" -ne 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root (or use --dry-run)." >&2
  exit 1
fi

say_rule() { printf '%q ' "$@"; printf '\n'; }
ensure_rule() {
  local tool="$1" table="$2" chain="$3"
  shift 3
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'ensure: '; say_rule "$tool" -w 5 -t "$table" -C "$chain" "$@"
    return
  fi
  command -v "$tool" >/dev/null 2>&1 || return 0
  if ! "$tool" -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null; then
    "$tool" -w 5 -t "$table" -I "$chain" 1 "$@"
  fi
}

add_family_rules() {
  local tool="$1" subnet="$2"
  # sing-box and other node-local processes: stop direct SMTP and common
  # BitTorrent listen/DHT ports. TCP/25 is separate from submission ports.
  ensure_rule "$tool" filter OUTPUT -p tcp --dport 25 -m comment --comment glukvpn-smtp25 -j REJECT
  ensure_rule "$tool" filter OUTPUT -p tcp --dport 6881:6999 -m comment --comment glukvpn-bittorrent -j REJECT
  ensure_rule "$tool" filter OUTPUT -p udp --dport 6881:6999 -m comment --comment glukvpn-bittorrent-dht -j REJECT
  ensure_rule "$tool" filter OUTPUT -p tcp --dport 51413 -m comment --comment glukvpn-bittorrent -j REJECT
  ensure_rule "$tool" filter OUTPUT -p udp --dport 51413 -m comment --comment glukvpn-bittorrent-dht -j REJECT

  # Forwarded safeguards apply only to packets entering from this VPN interface
  # and source subnet; unrelated host forwarding is untouched.
  [ -n "$subnet" ] || return 0
  ensure_rule "$tool" filter FORWARD -i "$WG_IF" -s "$subnet" -p tcp --dport 25 -m comment --comment glukvpn-smtp25 -j REJECT
  ensure_rule "$tool" filter FORWARD -i "$WG_IF" -s "$subnet" -p tcp --dport 6881:6999 -m comment --comment glukvpn-bittorrent -j REJECT
  ensure_rule "$tool" filter FORWARD -i "$WG_IF" -s "$subnet" -p udp --dport 6881:6999 -m comment --comment glukvpn-bittorrent-dht -j REJECT
  ensure_rule "$tool" filter FORWARD -i "$WG_IF" -s "$subnet" -p tcp --dport 51413 -m comment --comment glukvpn-bittorrent -j REJECT
  ensure_rule "$tool" filter FORWARD -i "$WG_IF" -s "$subnet" -p udp --dport 51413 -m comment --comment glukvpn-bittorrent-dht -j REJECT
}

if [ "$DRY_RUN" -ne 1 ] && ! command -v iptables >/dev/null 2>&1; then
  echo "iptables is required; no safeguards were installed." >&2
  exit 1
fi
add_family_rules iptables "$WG_SUBNET"
if [ -n "$WG_IPV6_SUBNET" ]; then
  add_family_rules ip6tables "$WG_IPV6_SUBNET"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "IPv6 FORWARD rules skipped: set WG_IPV6_SUBNET; IPv6 OUTPUT rules are still shown below."
  add_family_rules ip6tables ""
elif command -v ip6tables >/dev/null 2>&1; then
  add_family_rules ip6tables ""
fi

echo "GlukVPN egress safeguards are present."
echo "These port rules are defense in depth, not complete encrypted-P2P detection."
