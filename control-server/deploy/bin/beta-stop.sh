#!/usr/bin/env bash
# GlukVPN - stop the BETA channel. PROD is never touched.
#
# Order matters:
#   1. drain beta sessions, so devices are not left with a peer on a node that
#      is about to stop answering;
#   2. stop the node agent first - it is the thing that installs peers;
#   3. stop the control API;
#   4. take wg1 down (unit, then wg-quick, then ip link as the last resort);
#   5. verify tcp/8082 is CLOSED. If something still holds it, identify it,
#      prove it is not prod, TERM it, then KILL it, then verify again.
#
# Exit code 0 means one thing only: :8082 is closed. "the unit was not
# installed" is not a successful stop, which is exactly the bug this replaces.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional host overrides (ports, roots, interface). Deliberately NOT the
# deploy common.sh: this script must not inherit prod paths or prod actions.
if [ -f /etc/glukvpn-deploy/beta.env ]; then
  # shellcheck source=/dev/null
  . /etc/glukvpn-deploy/beta.env
fi

# shellcheck source=beta-lib.sh
. "$HERE/beta-lib.sh"

log "=== STOP BETA ==="

drain_beta_sessions

agent="$(resolve_agent_unit || true)"
control="$(resolve_control_unit || true)"

if [ -n "$agent" ]; then
  stop_beta_unit "$agent" "beta node agent"
else
  warn "beta node agent: no matching systemd unit found (looked for ${BETA_AGENT_CANDIDATES} and any *-beta unit)"
fi

if [ -n "$control" ]; then
  stop_beta_unit "$control" "beta control api"
else
  warn "beta control api: no matching systemd unit found (looked for ${BETA_CONTROL_CANDIDATES} and any *-beta unit)"
fi

stop_beta_wireguard || warn "${BETA_WG_IF} could not be fully removed"

# The port is the contract, not the unit list.
if port_open "$BETA_PORT"; then
  log "tcp/${BETA_PORT} is still open after stopping the units - finding the owner"
  clear_beta_port "$BETA_PORT" || true
fi

if port_open "$BETA_PORT"; then
  die "beta still answers on :${BETA_PORT} - the stop did not take effect"
fi

log "tcp/${BETA_PORT} is closed"
report_beta_state
log "=== BETA STOPPED ==="
