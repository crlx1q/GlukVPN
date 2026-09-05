#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
bash -n "$DIR/glukvpn-egress-guard.sh"
out="$(WG_IF=wg-test WG_SUBNET=10.77.0.0/24 WG_IPV6_SUBNET=fd77::/64 bash "$DIR/glukvpn-egress-guard.sh" --dry-run)"
grep -q -- '-t filter -C OUTPUT -p tcp --dport 25' <<<"$out"
grep -q -- '-t filter -C OUTPUT -p udp --dport 6881:6999' <<<"$out"
grep -q -- '-t filter -C FORWARD -i wg-test -s 10.77.0.0/24 -p tcp --dport 51413' <<<"$out"
grep -q -- '-t filter -C FORWARD -i wg-test -s fd77::/64 -p udp --dport 51413' <<<"$out"
if grep -Eq -- '(ensure_rule .* INPUT|ensure_rule .*dport 22|iptables .* (-F|--flush))' "$DIR/glukvpn-egress-guard.sh"; then
  echo 'unsafe firewall operation found' >&2
  exit 1
fi
echo 'egress guard static/dry-run checks passed'
