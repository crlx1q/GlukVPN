#!/usr/bin/env bash
# ============================================================================
# ROLLBACK PROD
#
# Points prod back at the previous release and restarts it. Seconds, not
# minutes: the old release directory is still on disk, fully built.
#
# THIS ROLLS BACK CODE ONLY.
#   Rows written by real users after the promote are kept. If the problem is a
#   schema migration, restore the dump taken by promote.sh manually - that is a
#   deliberate human decision, printed at the end of this script.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/rollback.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== ROLLBACK PROD ==="

[[ -L "${PROD_ROOT}/previous" ]] || die "no previous prod release recorded - nothing to roll back to"

previous="$(readlink -f "${PROD_ROOT}/previous")"
current="$(readlink -f "${PROD_ROOT}/current" 2>/dev/null || echo '')"

[[ -d "$previous" ]] || die "previous release directory is gone: ${previous}"
if [[ "$previous" == "$current" ]]; then
	die "previous and current are the same release ($(basename "$previous")) - nothing to do"
fi

log "current:  $(basename "$current")"
log "reverting to: $(basename "$previous")"
if [[ -r "${previous}/RELEASE" ]]; then
	log "target release info:"
	sed 's/^/    /' "${previous}/RELEASE"
fi

# Swap the two symlinks so a second rollback returns to where we started.
ln -sfn "$current" "${PROD_ROOT}/previous.tmp"
mv -Tf "${PROD_ROOT}/previous.tmp" "${PROD_ROOT}/previous"

ln -sfn "$previous" "${PROD_ROOT}/current.tmp"
mv -Tf "${PROD_ROOT}/current.tmp" "${PROD_ROOT}/current"

log "restarting ${PROD_SERVICE}"
systemctl restart "$PROD_SERVICE"

if ! wait_for_health "$PROD_PORT" 30; then
	log "CRITICAL: prod is unhealthy after rollback"
	log "  journalctl -u ${PROD_SERVICE} -n 80 --no-pager"
	log "  ls -1 ${PROD_ROOT}/releases   # older releases are still here"
	die "ROLLBACK failed"
fi

log "prod now runs:"
report_version "$PROD_PORT"

log "=== ROLLBACK OK ==="
log "Code is back on $(basename "$previous"). The database was NOT touched."
log "If the schema needs reverting too, pick the dump from the failed promote:"
log "  ls -lt ${BACKUP_DIR}"
log "  pg_restore --clean --if-exists --dbname \"\$PROD_DATABASE_URL\" <dump>"
