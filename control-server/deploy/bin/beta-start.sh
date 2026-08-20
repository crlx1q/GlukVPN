#!/usr/bin/env bash
# ============================================================================
# START BETA
#
# Brings the beta stack back up in dependency order (wg1 -> control server ->
# node agent) and refuses to report success until beta is actually healthy.
#
# PROD IS NOT TOUCHED: only beta-only units and the beta loopback port appear
# below.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/beta-start.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BETA_AGENT_SERVICE="vpn-node-agent-beta"
BETA_WG_UNIT="wg-quick@wg1"
BETA_WG_IFACE="wg1"

log "=== START BETA ==="

# A channel with no release cannot start; the operator has to deploy first.
[[ -L "${BETA_ROOT}/current" ]] ||
	die "no beta release is active - run Deploy Beta first"
log "release: $(basename "$(readlink -f "${BETA_ROOT}/current")")"

start_unit() {
	local unit="$1" required="${2:-required}"
	if ! systemctl cat "$unit" >/dev/null 2>&1; then
		if [[ "$required" == "optional" ]]; then
			log "${unit} is not installed, skipping"
			return 0
		fi
		die "${unit} is not installed"
	fi
	log "starting ${unit}"
	# enable --now so beta also comes back after a reboot, mirroring Stop Beta
	# which disables the same units.
	systemctl enable --now "$unit"
	return 0
}

# 1. Tunnel interface first: the agent expects wg1 to exist.
start_unit "$BETA_WG_UNIT"
if ip link show "$BETA_WG_IFACE" >/dev/null 2>&1; then
	log "${BETA_WG_IFACE} is up (udp/51821)"
else
	die "${BETA_WG_IFACE} did not come up - check: journalctl -u ${BETA_WG_UNIT} -n 50"
fi

# 2. Control server, then its health gate.
start_unit "$BETA_SERVICE"
if ! wait_for_health "$BETA_PORT" 30; then
	log "journalctl -u ${BETA_SERVICE} -n 50 --no-pager  # to see why"
	die "beta control server is not healthy on :${BETA_PORT}"
fi
log "beta now runs:"
report_version "$BETA_PORT"

# 3. Node agent last: it registers and starts heartbeating against the API
#    that is now up.
start_unit "$BETA_AGENT_SERVICE" optional

# 4. Wait for a heartbeat to land. The agent beats every 10s and the control
#    plane marks a node OFFLINE after 30s, so ~45s is a fair window.
node_online="no"
for attempt in $(seq 1 9); do
	if ( cd "$(readlink -f "${BETA_ROOT}/current")" &&
		sudo -u "$BETA_USER" ENV_FILE="$BETA_ENV" npm run --silent cli -- nodes:list 2>/dev/null ) |
		grep -q "ONLINE"; then
		node_online="yes"
		break
	fi
	sleep 5
done

if [[ "$node_online" == "yes" ]]; then
	log "beta node is ONLINE (heartbeat received)"
else
	# Not fatal: the control server is healthy and the panel will show the node
	# as OFFLINE, which is the honest state.
	log "warning: no beta node heartbeat yet"
	log "  check: systemctl status ${BETA_AGENT_SERVICE}"
	log "  check: journalctl -u ${BETA_AGENT_SERVICE} -n 50 --no-pager"
fi

# 5. Prod must still be fine.
if wait_for_health "$PROD_PORT" 5; then
	log "prod is healthy and unaffected"
else
	die "prod is NOT healthy after starting beta - investigate immediately"
fi

log "=== START BETA OK ==="
