#!/usr/bin/env bash
# ============================================================================
# STOP BETA
#
# Switches the whole beta stack off: control server, node agent, wg1.
# "Beta OFF" means really off - each unit is stopped *and* disabled, so a
# reboot does not quietly bring it back.
#
# PROD IS NOT TOUCHED. Every name below is a beta-only constant
# (vpn-control-beta, vpn-node-agent-beta, wg1 :51821, 10.9.0.0/24); prod keeps
# serving api.gluk.tech on wg0 :51820 / 10.8.0.0/24 and this script verifies
# that before it exits.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/beta-stop.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BETA_AGENT_SERVICE="vpn-node-agent-beta"
BETA_WG_UNIT="wg-quick@wg1"
BETA_WG_IFACE="wg1"

log "=== STOP BETA ==="

# ---------------------------------------------------------------------------
# 1. Close live beta sessions while the database is still reachable.
#
# Peers vanish together with wg1, so waiting for a REMOVE_PEER ack from an
# agent we are about to stop would only leak address leases. `sessions:drain`
# closes them and frees the leases in one transaction, and refuses to run on
# anything other than the beta channel.
# ---------------------------------------------------------------------------
if [[ -L "${BETA_ROOT}/current" ]]; then
	log "closing live beta sessions"
	if ! ( cd "$(readlink -f "${BETA_ROOT}/current")" &&
		sudo -u "$BETA_USER" ENV_FILE="$BETA_ENV" npm run --silent cli -- sessions:drain ); then
		log "warning: could not drain beta sessions - continuing with the stop"
	fi
else
	log "no beta release is active, skipping session drain"
fi

# ---------------------------------------------------------------------------
# 2. Stop the units, most dependent first.
# ---------------------------------------------------------------------------
stop_unit() {
	local unit="$1"
	# `systemctl cat` also resolves template instances such as wg-quick@wg1.
	if ! systemctl cat "$unit" >/dev/null 2>&1; then
		log "${unit} is not installed, skipping"
		return 0
	fi
	if systemctl is-active --quiet "$unit"; then
		log "stopping ${unit}"
		systemctl stop "$unit"
	else
		log "${unit} was already stopped"
	fi
	# Disabled as well: OFF has to survive a reboot.
	systemctl disable --quiet "$unit" 2>/dev/null || true
	return 0
}

stop_unit "$BETA_AGENT_SERVICE"
stop_unit "$BETA_SERVICE"
stop_unit "$BETA_WG_UNIT"

# ---------------------------------------------------------------------------
# 3. Prove beta is down.
# ---------------------------------------------------------------------------
if ip link show "$BETA_WG_IFACE" >/dev/null 2>&1; then
	log "warning: interface ${BETA_WG_IFACE} still exists"
	log "  check: systemctl status ${BETA_WG_UNIT} ; ip link delete ${BETA_WG_IFACE}"
else
	log "${BETA_WG_IFACE} is gone (udp/51821 closed)"
fi

if curl -fsS --max-time 3 "http://127.0.0.1:${BETA_PORT}/api/health" >/dev/null 2>&1; then
	die "beta still answers on :${BETA_PORT} - the stop did not take effect"
fi
log "beta no longer answers on :${BETA_PORT} (expected)"

# ---------------------------------------------------------------------------
# 4. Prove prod is untouched. Failing here means something outside this script
#    went wrong and a human needs to look at it now.
# ---------------------------------------------------------------------------
if wait_for_health "$PROD_PORT" 5; then
	log "prod is healthy and unaffected"
else
	die "prod is NOT healthy after stopping beta - investigate immediately"
fi

log "beta stopped at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "=== STOP BETA OK ==="
log "Start it again from the prod admin panel (Channels -> Start Beta)."
