#!/usr/bin/env bash
# GlukVPN - start the BETA channel. PROD is never touched.
#
# Refuses to start when there is no beta release to run, brings wg1 up, starts
# the control API and the node agent, then waits for :8082 to actually answer.
# A start that leaves the port closed exits non-zero, so the panel shows a
# failure instead of a green button and a dead channel.
#
# Nothing here is enabled at boot: beta comes up when someone asks for it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f /etc/glukvpn-deploy/beta.env ]; then
  # shellcheck source=/dev/null
  . /etc/glukvpn-deploy/beta.env
fi

# shellcheck source=beta-lib.sh
. "$HERE/beta-lib.sh"

log "=== START BETA ==="

if [ ! -e "$BETA_ROOT/current" ]; then
  die "no beta release is active ($BETA_ROOT/current is missing) - run Deploy Beta first"
fi
log "beta release: $(basename "$(readlink -f "$BETA_ROOT/current" 2>/dev/null || echo unknown)")"

start_beta_wireguard || warn "${BETA_WG_IF} did not come up - the API will still be started"

control="$(resolve_control_unit || true)"
if [ -z "$control" ]; then
  die "beta control api: no systemd unit found (expected one of ${BETA_CONTROL_CANDIDATES})"
fi
start_beta_unit "$control" "beta control api"

agent="$(resolve_agent_unit || true)"
if [ -n "$agent" ]; then
  start_beta_unit "$agent" "beta node agent" ||
    warn "$agent did not start - beta API is up but peers will not be installed"
else
  warn "beta node agent: no matching systemd unit found - beta API only"
fi

if ! wait_port_open "$BETA_PORT" 25; then
  log "--- last 40 journal lines for $control ---"
  journalctl -u "$control" -n 40 --no-pager 2>/dev/null || true
  die "beta did not start answering on :${BETA_PORT}"
fi

if command -v curl >/dev/null 2>&1; then
  log "version: $(curl -fsS --max-time 3 \
    "${BETA_SCHEME}://${BETA_HOST}:${BETA_PORT}/api/version" 2>/dev/null ||
    echo unavailable)"
fi

report_beta_state
log "=== BETA STARTED ==="
