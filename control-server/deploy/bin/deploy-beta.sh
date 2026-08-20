#!/usr/bin/env bash
# ============================================================================
# DEPLOY BETA
#
# Builds a new release from /opt/glukvpn-src and activates it on the beta
# channel only. Prod is not touched in any way.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/deploy-beta.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== DEPLOY BETA (release ${RELEASE_ID}) ==="

# Beta may legitimately be switched off. Deploying turns it back on.
if ! systemctl is-enabled --quiet "$BETA_SERVICE" 2>/dev/null; then
	log "note: ${BETA_SERVICE} is not enabled at boot (that is the default)"
fi

# 1. Build + migrate the beta database.
target="$(build_release "$BETA_ROOT" "$BETA_USER" "$BETA_ENV")"

# Human-readable marker inside the release; not read by the app.
{
	echo "release_id=${RELEASE_ID}"
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "channel=beta"
	if [[ -d /opt/glukvpn-src/.git ]]; then
		echo "git_commit=$(git -C /opt/glukvpn-src rev-parse --short HEAD 2>/dev/null || echo unknown)"
	fi
} > "${target}/RELEASE"
chmod 640 "${target}/RELEASE"
chown "${BETA_USER}:${BETA_USER}" "${target}/RELEASE"

# 2. Swap the symlink and restart.
activate_release "$BETA_ROOT" "$target"

log "restarting ${BETA_SERVICE}"
systemctl restart "$BETA_SERVICE"

# 3. Health gate. A failed beta deploy rolls itself back so the channel is
#    never left broken; prod was never involved.
if ! wait_for_health "$BETA_PORT" 30; then
	log "beta failed its health check, reverting the symlink"
	if [[ -L "${BETA_ROOT}/previous" ]]; then
		ln -sfn "$(readlink -f "${BETA_ROOT}/previous")" "${BETA_ROOT}/current.tmp"
		mv -Tf "${BETA_ROOT}/current.tmp" "${BETA_ROOT}/current"
		systemctl restart "$BETA_SERVICE" || true
		wait_for_health "$BETA_PORT" 20 || log "previous beta release is unhealthy too"
	else
		log "no previous beta release to revert to"
	fi
	log "journalctl -u ${BETA_SERVICE} -n 50 --no-pager  # to see why"
	die "DEPLOY BETA failed"
fi

log "beta now runs:"
report_version "$BETA_PORT"

prune_releases "$BETA_ROOT"

log "=== DEPLOY BETA OK (${RELEASE_ID}) ==="
log "Test it at https://beta-api.gluk.tech and https://beta-admin.gluk.tech"
