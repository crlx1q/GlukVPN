#!/usr/bin/env bash
# ============================================================================
# GlukVPN deploy scripts - shared helpers.
#
# Installed at /opt/glukvpn-deploy/bin/ as root:root 0755. The deploy worker
# executes these files directly (execFile, no shell), and they accept NO
# arguments: every path is a constant defined here. That is deliberate - the
# admin "Deploy"/"Promote" buttons must not be able to influence what runs.
#
# Layout these scripts assume:
#   /opt/glukvpn-src/                source tree (control-server/ inside)
#   /opt/vpn-control/releases/<id>/  immutable prod releases
#   /opt/vpn-control/current         symlink -> active prod release
#   /opt/vpn-control/previous        symlink -> rollback target
#   /opt/vpn-control-beta/...        same layout for beta
#   /var/backups/glukvpn/            pg_dump archives
# ============================================================================

set -Eeuo pipefail

SRC_DIR="/opt/glukvpn-src/control-server"

PROD_ROOT="/opt/vpn-control"
BETA_ROOT="/opt/vpn-control-beta"

PROD_ENV="/etc/vpn-control/control.env"
BETA_ENV="/etc/vpn-control-beta/control.env"

PROD_SERVICE="vpn-control"
BETA_SERVICE="vpn-control-beta"

PROD_PORT="8081"
BETA_PORT="8082"

PROD_USER="vpncontrol"
BETA_USER="vpnbeta"

BACKUP_DIR="/var/backups/glukvpn"
KEEP_RELEASES=5

# Timestamped id shared by every step of one run.
RELEASE_ID="$(date -u +%Y%m%d-%H%M%S)"

log() {
	printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

die() {
	printf '[%s] FATAL: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
	exit 1
}

# Read one key from an env file without sourcing it (sourcing would execute it)
# and without ever printing the value.
env_value() {
	local file="$1" key="$2"
	[[ -r "$file" ]] || die "env file not readable: $file"
	sed -n "s/^${key}=//p" "$file" | tail -n 1 | sed 's/^"//; s/"$//'
}

# Wait for /api/health to report ok on a loopback port.
wait_for_health() {
	local port="$1" tries="${2:-30}" i body
	for ((i = 1; i <= tries; i++)); do
		if body="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/health" 2>/dev/null)"; then
			if [[ "$body" == *'"ok":true'* ]]; then
				log "health ok on :${port}"
				return 0
			fi
		fi
		sleep 1
	done
	log "health FAILED on :${port} after ${tries}s"
	return 1
}

# Report channel/version, for the job log.
report_version() {
	local port="$1"
	curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/version" 2>/dev/null || true
	printf '\n'
}

# Build a fresh release directory from the source tree.
# Args: <root> <owner-user> <env-file>
build_release() {
	local root="$1" owner="$2" env_file="$3"
	local target="${root}/releases/${RELEASE_ID}"

	[[ -d "$SRC_DIR" ]] || die "source tree missing: $SRC_DIR"
	mkdir -p "${root}/releases"

	log "building release ${RELEASE_ID} in ${target}"
	# Copy sources only. node_modules and any stray .env stay out; the release
	# gets its dependencies from a clean npm ci below.
	rsync -a --delete \
		--exclude '.git' \
		--exclude 'node_modules' \
		--exclude '.env' \
		--exclude '.env.*' \
		--exclude 'tests' \
		"${SRC_DIR}/" "${target}/"

	( cd "$target" && npm ci --no-audit --no-fund )
	( cd "$target" && npm run build )

	# Migrations run with the channel's own DATABASE_URL, never a shared one.
	log "applying migrations"
	( cd "$target" && ENV_FILE="$env_file" npx prisma migrate deploy )

	chown -R "${owner}:${owner}" "$target"
	find "$target" -type d -exec chmod 750 {} +
	find "$target" -type f -exec chmod 640 {} +
	find "$target/node_modules" -type f -perm -u+x -exec chmod 750 {} + 2>/dev/null || true

	printf '%s' "$target"
}

# Point `current` at a release without ever leaving the symlink missing.
# Args: <root> <release-path>
activate_release() {
	local root="$1" target="$2"
	local previous=""

	if [[ -L "${root}/current" ]]; then
		previous="$(readlink -f "${root}/current")"
		ln -sfn "$previous" "${root}/previous.tmp"
		mv -Tf "${root}/previous.tmp" "${root}/previous"
	fi

	# ln -sfn + mv -T is the atomic pattern: the rename replaces the symlink in
	# one operation, so no request ever hits a half-swapped directory.
	ln -sfn "$target" "${root}/current.tmp"
	mv -Tf "${root}/current.tmp" "${root}/current"
	log "activated $(basename "$target")"
	[[ -n "$previous" ]] && log "rollback target: $(basename "$previous")"
	return 0
}

# Keep the last N releases so rollback stays possible without unbounded growth.
prune_releases() {
	local root="$1" keep="${2:-$KEEP_RELEASES}"
	local current previous
	current="$(readlink -f "${root}/current" 2>/dev/null || true)"
	previous="$(readlink -f "${root}/previous" 2>/dev/null || true)"

	# shellcheck disable=SC2012
	ls -1dt "${root}/releases/"*/ 2>/dev/null | tail -n "+$((keep + 1))" | while read -r dir; do
		dir="${dir%/}"
		[[ "$dir" == "$current" || "$dir" == "$previous" ]] && continue
		log "pruning old release $(basename "$dir")"
		rm -rf "$dir"
	done
	return 0
}

# pg_dump of a channel database into /var/backups/glukvpn.
# Args: <env-file> <label>
backup_database() {
	local env_file="$1" label="$2"
	local url out
	url="$(env_value "$env_file" DATABASE_URL)"
	[[ -n "$url" ]] || die "DATABASE_URL missing in $env_file"

	mkdir -p "$BACKUP_DIR"
	chmod 700 "$BACKUP_DIR"
	out="${BACKUP_DIR}/${label}-${RELEASE_ID}.dump"

	log "backing up ${label} database"
	# Custom format: restore with pg_restore, compressed, no plaintext secrets.
	PGCONNECT_TIMEOUT=10 pg_dump --format=custom --file="$out" "$url"
	chmod 600 "$out"
	log "backup written: ${out} ($(du -h "$out" | cut -f1))"

	printf '%s' "$out"
}
