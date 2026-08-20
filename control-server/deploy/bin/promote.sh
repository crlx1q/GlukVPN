#!/usr/bin/env bash
# ============================================================================
# PROMOTE BETA -> PROD
#
# Takes the exact release directory that beta is running right now, installs it
# as a new prod release and switches prod over atomically.
#
# WHAT MOVES:      code, and only code.
# WHAT NEVER MOVES: data. Beta accounts, beta sessions and beta nodes stay in
#                   glukvpn_beta forever. Prod keeps its own database; the only
#                   thing applied to it is the migration files that ship with
#                   the promoted code.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/promote.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "=== PROMOTE BETA -> PROD (release ${RELEASE_ID}) ==="

# ---------------------------------------------------------------------------
# 1. Refuse to promote anything that is not proven healthy.
# ---------------------------------------------------------------------------
[[ -L "${BETA_ROOT}/current" ]] || die "beta has no active release - run Deploy Beta first"
beta_release="$(readlink -f "${BETA_ROOT}/current")"
[[ -d "$beta_release" ]] || die "beta release directory is missing: ${beta_release}"

systemctl is-active --quiet "$BETA_SERVICE" ||
	die "beta is not running - start it and verify it before promoting"

wait_for_health "$BETA_PORT" 10 ||
	die "beta is unhealthy - fix beta first, prod stays untouched"

log "promoting beta release $(basename "$beta_release")"
log "beta reports:"
report_version "$BETA_PORT"

# ---------------------------------------------------------------------------
# 2. Back up prod BEFORE anything is applied to it.
#    This is the one step that must never be skipped: the promoted code may
#    carry migrations, and migrations are the only irreversible part.
# ---------------------------------------------------------------------------
backup_path="$(backup_database "$PROD_ENV" prod)"
log "prod backup: ${backup_path}"
log "restore command if ever needed:"
log "  pg_restore --clean --if-exists --dbname \"\$PROD_DATABASE_URL\" ${backup_path}"

# ---------------------------------------------------------------------------
# 3. Copy the beta release into a fresh prod release directory.
#    Nothing is written over the running prod release, so a failure here
#    leaves prod exactly as it was.
# ---------------------------------------------------------------------------
prod_target="${PROD_ROOT}/releases/${RELEASE_ID}"
mkdir -p "${PROD_ROOT}/releases"

log "copying release into ${prod_target}"
# Same machine, same architecture: node_modules and dist are reused as built.
# Env files are excluded - prod keeps its own secrets and its own database.
rsync -a --delete \
	--exclude '.env' \
	--exclude '.env.*' \
	"${beta_release}/" "${prod_target}/"

{
	echo "release_id=${RELEASE_ID}"
	echo "promoted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "channel=prod"
	echo "promoted_from_beta_release=$(basename "$beta_release")"
	echo "prod_backup=${backup_path}"
} > "${prod_target}/RELEASE"

chown -R "${PROD_USER}:${PROD_USER}" "$prod_target"
find "$prod_target" -type d -exec chmod 750 {} +
find "$prod_target" -type f -exec chmod 640 {} +
find "$prod_target/node_modules" -type f -perm -u+x -exec chmod 750 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Apply migrations to the PROD database, with the prod env file.
# ---------------------------------------------------------------------------
log "applying migrations to prod database"
if ! ( cd "$prod_target" && ENV_FILE="$PROD_ENV" npx prisma migrate deploy ); then
	log "migration failed - prod code was NOT switched, prod still runs the old release"
	log "database may be partially migrated; inspect before retrying:"
	log "  backup at ${backup_path}"
	die "PROMOTE failed during migration"
fi

# ---------------------------------------------------------------------------
# 5. Atomic switch + restart.
# ---------------------------------------------------------------------------
activate_release "$PROD_ROOT" "$prod_target"

log "restarting ${PROD_SERVICE}"
systemctl restart "$PROD_SERVICE"

# ---------------------------------------------------------------------------
# 6. Health gate with automatic rollback of the CODE.
#
#    The database is intentionally NOT restored automatically: by the time a
#    promote fails, real users may already have written rows, and rolling the
#    data back would destroy them. Code rollback is safe and instant; data
#    restore is a human decision, with the dump from step 2.
# ---------------------------------------------------------------------------
if ! wait_for_health "$PROD_PORT" 30; then
	log "prod failed its health check - rolling the code back"
	if [[ -L "${PROD_ROOT}/previous" ]]; then
		previous="$(readlink -f "${PROD_ROOT}/previous")"
		ln -sfn "$previous" "${PROD_ROOT}/current.tmp"
		mv -Tf "${PROD_ROOT}/current.tmp" "${PROD_ROOT}/current"
		systemctl restart "$PROD_SERVICE" || true
		if wait_for_health "$PROD_PORT" 30; then
			log "prod restored to $(basename "$previous")"
		else
			log "CRITICAL: prod is down on both releases"
			log "  journalctl -u ${PROD_SERVICE} -n 80 --no-pager"
		fi
	else
		log "CRITICAL: no previous prod release to roll back to"
	fi
	log "if the schema is the problem, restore with:"
	log "  pg_restore --clean --if-exists --dbname \"\$PROD_DATABASE_URL\" ${backup_path}"
	die "PROMOTE failed - prod code rolled back"
fi

log "prod now runs:"
report_version "$PROD_PORT"

prune_releases "$PROD_ROOT"

log "=== PROMOTE OK (${RELEASE_ID}) ==="
log "prod backup kept at ${backup_path}"
log "rollback within seconds: sudo /opt/glukvpn-deploy/bin/rollback.sh"
