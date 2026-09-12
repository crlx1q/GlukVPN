#!/usr/bin/env bash
#
# GlukVPN speed router: five sold speeds, one open port.
#
# ROUND 27 gave every shaped tier its own external port (2053, 2083, ...).
# This node lives in Oracle Cloud, where the VCN closes every port except 443,
# so a capped desktop client got connect_timeout and could not connect at all -
# and a non-standard port is also the first thing an ISP or a hotel Wi-Fi drops.
#
# ROUND 28 keeps exactly one port open and splits it by SNI. ssl_preread reads
# the server name out of the TLS ClientHello without terminating TLS, so the
# VLESS stream stays end-to-end encrypted between the client and sing-box; this
# only decides where to send it:
#
#   :443  de-01.gluk.tech          -> sing-box              (unlimited)
#         speed30.de-01.gluk.tech  -> 127.0.0.1:8460        -> sing-box
#         speed50.de-01.gluk.tech  -> 127.0.0.1:8461        -> sing-box
#         anything else            -> the site / API vhost
#
# The shaped relays live on loopback, so nothing new is exposed and no cloud
# firewall rule is needed. Which subdomain a device is given is decided by the
# control plane from the plan in the database (VLESS_SPEED_TIERS), never by the
# client.
#
# This script is deliberately read-only until told otherwise: port 443 already
# works on this machine, and silently rewriting whoever owns it is how an
# outage starts. Run it with no arguments to see what it would do.
#
# Usage:
#   ./install-speed-router.sh --domain de-01.gluk.tech [options]
#
#   --domain NAME          node gateway name (required)
#   --speeds LIST          sold speeds, default "30,50,100,250,500"
#   --base-port N          first loopback relay port, default 8460
#   --singbox-port N       sing-box listen_port; read from its config if unset
#   --site-upstream H:P    where non-VPN SNI goes; detected if unset
#   --output FILE          config to generate
#   --write                actually write it (implies nginx -t)
#   --force                replace a stream config this script does not own
#   --reload               reload nginx after a successful nginx -t
#   --certbot              expand the certificate over the speed names

set -euo pipefail

DOMAIN=""
SPEEDS="30,50,100,250,500"
BASE_PORT=8460
SINGBOX_PORT=""
SITE_UPSTREAM=""
OUTPUT="/etc/nginx/glukvpn/stream-speed-router.conf"
SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/glukvpn/singbox.json}"
DO_WRITE=0
DO_FORCE=0
DO_RELOAD=0
DO_CERTBOT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--domain) DOMAIN="${2:?}"; shift 2 ;;
		--speeds) SPEEDS="${2:?}"; shift 2 ;;
		--base-port) BASE_PORT="${2:?}"; shift 2 ;;
		--singbox-port) SINGBOX_PORT="${2:?}"; shift 2 ;;
		--site-upstream) SITE_UPSTREAM="${2:?}"; shift 2 ;;
		--output) OUTPUT="${2:?}"; shift 2 ;;
		--write) DO_WRITE=1; shift ;;
		--force) DO_FORCE=1; shift ;;
		--reload) DO_RELOAD=1; shift ;;
		--certbot) DO_CERTBOT=1; shift ;;
		-h|--help) sed -n '1,44p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -n "$DOMAIN" ] || { echo "--domain is required (e.g. de-01.gluk.tech)" >&2; exit 2; }

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. speed -> loopback port
#
# Same rule as the agent's parseSpeedTiers: ascending speed, basePort + index,
# skipping any port a tier pinned for itself. Both sides compute it instead of
# storing it, so there is nothing to get out of sync - but the agent also logs
# `shapedGateways` at startup, which is the authoritative answer if in doubt.
# ---------------------------------------------------------------------------
build_map() {
	awk -v spec="$1" -v base="$2" '
	BEGIN {
		n = split(spec, parts, ",")
		for (i = 1; i <= n; i++) {
			e = parts[i]; gsub(/[ \t]/, "", e)
			if (e == "") continue
			port = ""
			if (e ~ /^[0-9]+=[0-9]+$/) {
				split(e, kv, "="); mbps = kv[1] + 0; port = kv[2] + 0
				if (port < 1 || port > 65535) continue
			} else if (e ~ /^[0-9]+$/) { mbps = e + 0 } else continue
			if (mbps <= 0 || (mbps in seen)) continue
			seen[mbps] = 1; speeds[++c] = mbps; pin[mbps] = port
			if (port != "") used[port] = 1
		}
		for (i = 1; i <= c; i++)
			for (j = i + 1; j <= c; j++)
				if (speeds[j] < speeds[i]) { t = speeds[i]; speeds[i] = speeds[j]; speeds[j] = t }
		next_port = base + 0
		for (i = 1; i <= c; i++) {
			m = speeds[i]
			if (pin[m] != "") { print m, pin[m]; continue }
			while (next_port in used) next_port++
			if (next_port > 65535) break
			used[next_port] = 1; print m, next_port; next_port++
		}
	}'
}

MAP="$(build_map "$SPEEDS" "$BASE_PORT")"
[ -n "$MAP" ] || die "--speeds parsed to nothing: $SPEEDS"

# ---------------------------------------------------------------------------
# 2. where the traffic actually has to land
# ---------------------------------------------------------------------------
if [ -z "$SINGBOX_PORT" ] && [ -r "$SINGBOX_CONFIG" ]; then
	SINGBOX_PORT="$(python3 - "$SINGBOX_CONFIG" <<'PY' 2>/dev/null || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
for inbound in cfg.get("inbounds") or []:
    if isinstance(inbound, dict) and inbound.get("type") == "vless":
        port = inbound.get("listen_port")
        if isinstance(port, int):
            print(port)
        break
PY
)"
fi
[ -n "$SINGBOX_PORT" ] || die "could not read sing-box listen_port from $SINGBOX_CONFIG; pass --singbox-port"

if [ "$SINGBOX_PORT" = "443" ]; then
	# nginx is about to own 443. Forwarding VLESS back to 443 would send it
	# through this very map and straight back out, which is a socket bomb, not
	# a tunnel: sing-box has to move to an internal port first.
	die "sing-box listens on 443, which nginx needs. Move it to e.g. 8445 (install-singbox.sh --port 8445) and re-run"
fi

# nginx's conf path, straight from the binary rather than guessed.
NGINX_CONF="$(nginx -V 2>&1 | tr ' ' '\n' | sed -n 's/^--conf-path=//p' | head -n1)"
[ -n "$NGINX_CONF" ] || NGINX_CONF=/etc/nginx/nginx.conf
NGINX_ROOT="$(dirname "$NGINX_CONF")"

# Who owns 443 in the stream context today?
PREREAD_FILES="$(grep -rlsE '^[[:space:]]*ssl_preread[[:space:]]+on' "$NGINX_ROOT" /etc/nginx 2>/dev/null | sort -u || true)"

# The fallback for non-VPN SNI: the site and the API. Taken from the config
# that is working right now, because guessing it wrong takes the website down -
# and 8443/8444 on this node are the browser proxies, not the site.
if [ -z "$SITE_UPSTREAM" ] && [ -n "$PREREAD_FILES" ]; then
	while IFS= read -r conf; do
		[ -n "$conf" ] || continue
		default_target="$(sed -nE 's/^[[:space:]]*default[[:space:]]+([A-Za-z0-9_.:@-]+);.*/\1/p' "$conf" | head -n1)"
		[ -n "$default_target" ] || continue
		case "$default_target" in
			*:[0-9]*|unix:*) SITE_UPSTREAM="$default_target" ;;
			*) SITE_UPSTREAM="$(awk -v name="$default_target" '
					$1 == "upstream" && $2 == name { inside = 1; next }
					inside && $1 == "server" { gsub(/;/, "", $2); print $2; exit }
					inside && $1 == "}" { inside = 0 }' "$conf")" ;;
		esac
		[ -n "$SITE_UPSTREAM" ] && break
	done <<<"$PREREAD_FILES"
fi
[ -n "$SITE_UPSTREAM" ] || die "could not detect where non-VPN SNI currently goes; pass --site-upstream HOST:PORT"

# ---------------------------------------------------------------------------
# 3. DNS and the certificate
#
# The SNI a client sends is also the name it validates the certificate against,
# so speed30.<domain> must be in the certificate and must resolve. Either
# failure is a dead tunnel, not a slow one, which is why the control plane ships
# with VLESS_SPEED_TIERS empty until this part is done.
# ---------------------------------------------------------------------------
SPEED_NAMES=""
while read -r mbps _port; do
	[ -n "$mbps" ] || continue
	SPEED_NAMES="$SPEED_NAMES speed${mbps}.${DOMAIN}"
done <<<"$MAP"

for name in $SPEED_NAMES; do
	getent hosts "$name" >/dev/null 2>&1 || warn "$name does not resolve yet - add an A record to the same address as $DOMAIN"
done

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
CERT_MISSING=""
if [ -r "$CERT" ]; then
	SAN="$(openssl x509 -in "$CERT" -noout -text 2>/dev/null | tr ',' '\n' | sed -nE 's/.*DNS:([^ ]+).*/\1/p')"
	for name in $SPEED_NAMES; do
		if ! printf '%s\n' "$SAN" | grep -qx -e "$name" -e "*.${DOMAIN}"; then
			CERT_MISSING="$CERT_MISSING $name"
		fi
	done
else
	warn "cannot read $CERT - skipping the certificate check"
fi

CERTBOT_CMD="certbot certonly --nginx --cert-name $DOMAIN --expand -d $DOMAIN$(printf ' -d %s' $SPEED_NAMES)"
if [ -n "$CERT_MISSING" ]; then
	warn "the certificate does not cover:$CERT_MISSING"
	if [ "$DO_CERTBOT" = "1" ]; then
		say "==> $CERTBOT_CMD"
		eval "$CERTBOT_CMD"
	else
		say "    fix it with: $CERTBOT_CMD"
		say "    or once, with a wildcard (DNS-01): certbot certonly --cert-name $DOMAIN -d $DOMAIN -d '*.$DOMAIN' --preferred-challenges dns"
	fi
fi

# ---------------------------------------------------------------------------
# 4. the config
# ---------------------------------------------------------------------------
GENERATED="$(mktemp)"
trap 'rm -f "$GENERATED"' EXIT

{
	echo "# Managed by node-agent/deploy/install-speed-router.sh - do not edit by hand."
	echo "# Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ') for $DOMAIN, speeds: $SPEEDS"
	echo "#"
	echo "# ssl_preread only reads the SNI; TLS is still terminated by sing-box, so"
	echo "# nothing here can see inside a subscriber's tunnel."
	echo "stream {"
	echo "    map \$ssl_preread_server_name \$glukvpn_upstream {"
	echo "        hostnames;"
	echo "        default                 glukvpn_site;"
	echo "        $DOMAIN glukvpn_singbox;"
	while read -r mbps port; do
		[ -n "$mbps" ] || continue
		echo "        speed${mbps}.${DOMAIN} glukvpn_speed${mbps};"
	done <<<"$MAP"
	echo "    }"
	echo
	echo "    upstream glukvpn_site { server $SITE_UPSTREAM; }"
	echo "    upstream glukvpn_singbox { server 127.0.0.1:$SINGBOX_PORT; }"
	while read -r mbps port; do
		[ -n "$mbps" ] || continue
		echo "    upstream glukvpn_speed${mbps} { server 127.0.0.1:${port}; }  # ${mbps} Mbit/s"
	done <<<"$MAP"
	echo
	echo "    server {"
	echo "        listen 443 reuseport;"
	echo "        listen [::]:443 reuseport;"
	echo "        ssl_preread on;"
	echo "        proxy_pass \$glukvpn_upstream;"
	echo "        # A VPN tunnel is idle for minutes at a time and must survive it."
	echo "        proxy_timeout 10m;"
	echo "        proxy_connect_timeout 5s;"
	echo "    }"
	echo "}"
} >"$GENERATED"

say "speed map (mbit -> loopback port):"
while read -r mbps port; do
	[ -n "$mbps" ] || continue
	say "  speed${mbps}.${DOMAIN} -> 127.0.0.1:${port}"
done <<<"$MAP"
say "unlimited: $DOMAIN -> 127.0.0.1:$SINGBOX_PORT"
say "site/API:  everything else -> $SITE_UPSTREAM"
say ""
say "put these where they belong:"
say "  /etc/vpn-node-agent/agent.env : SHAPING_GATEWAY_SPEEDS=$SPEEDS"
say "                                 SHAPING_GATEWAY_BASE_PORT=$BASE_PORT"
say "                                 SHAPING_GATEWAY_TARGET_PORT=$SINGBOX_PORT"
say "  /etc/glukvpn/control.env      : VLESS_SPEED_TIERS=$SPEEDS"
say "  (set VLESS_SPEED_TIERS last: it is what starts handing the names out)"
say ""

if [ "$DO_WRITE" != "1" ]; then
	say "--- generated config (not written; pass --write) ---"
	cat "$GENERATED"
	if [ -n "$PREREAD_FILES" ]; then
		say "--- stream configs already using ssl_preread ---"
		printf '%s\n' "$PREREAD_FILES"
	fi
	exit 0
fi

# A second `listen 443` in the stream context cannot bind, so an existing
# ssl_preread config elsewhere has to be replaced, not joined.
FOREIGN="$(printf '%s\n' "$PREREAD_FILES" | grep -vFx "$OUTPUT" | sed '/^$/d' || true)"
if [ -n "$FOREIGN" ] && [ "$DO_FORCE" != "1" ]; then
	say "these files already route 443 by SNI:"
	printf '  %s\n' $FOREIGN
	die "refusing to add a second listener on 443. Replace the file above with the generated config, or re-run with --force to let this script own it"
fi

mkdir -p "$(dirname "$OUTPUT")"
BACKUP=""
if [ -f "$OUTPUT" ]; then
	BACKUP="${OUTPUT}.$(date -u '+%Y%m%d%H%M%S').bak"
	cp -p "$OUTPUT" "$BACKUP"
fi
for conf in $FOREIGN; do
	cp -p "$conf" "${conf}.$(date -u '+%Y%m%d%H%M%S').bak"
	# Disabled, not deleted: the operator's own file stays recoverable.
	mv "$conf" "${conf}.disabled-by-speed-router"
done
install -m 0644 "$GENERATED" "$OUTPUT"
say "wrote $OUTPUT"

if ! grep -qsF "$OUTPUT" "$NGINX_CONF"; then
	warn "$NGINX_CONF does not include $OUTPUT"
	say "    add this at the TOP LEVEL of $NGINX_CONF (outside http{}), then reload:"
	say "        include $OUTPUT;"
fi

if ! nginx -t; then
	if [ -n "$BACKUP" ]; then
		cp -p "$BACKUP" "$OUTPUT"
		say "restored $OUTPUT from $BACKUP"
	else
		rm -f "$OUTPUT"
		say "removed $OUTPUT"
	fi
	for conf in $FOREIGN; do mv "${conf}.disabled-by-speed-router" "$conf"; done
	die "nginx -t failed; nothing was changed"
fi

if [ "$DO_RELOAD" = "1" ]; then
	systemctl reload nginx
	say "nginx reloaded"
else
	say "run: systemctl reload nginx"
fi
