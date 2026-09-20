#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BACKUP_ROOT="${BACKUP_ROOT:-/opt/glukvpn/backups}"
BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/daily}"
STATUS_FILE="${BACKUP_STATUS_FILE:-${BACKUP_ROOT}/status.json}"
LOCK_FILE="${BACKUP_LOCK_FILE:-${BACKUP_ROOT}/backup.lock}"
ENV_FILE="${BACKUP_ENV_FILE:-/etc/glukvpn/backup.env}"
RETENTION="${BACKUP_RETENTION:-5}"
RESTORE_SOURCE="${RESTORE_SOURCE:-/opt/glukvpn/bin/glukvpn-restore.sh}"

if [[ -r "$ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$ENV_FILE"
fi

mkdir -p "$BACKUP_DIR"
chown root:glukvpn "$BACKUP_ROOT" "$BACKUP_DIR"
chmod 0750 "$BACKUP_ROOT" "$BACKUP_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	echo "backup already running" >&2
	exit 75
fi

TIMESTAMP="$(date -u +%Y-%m-%d_%H-%M-%S)"
FILENAME="glukvpn-backup-${TIMESTAMP}.tar.gz"
ARCHIVE="${BACKUP_DIR}/${FILENAME}"
SIDECAR="${ARCHIVE}.json"
STAGING="$(mktemp -d "${BACKUP_ROOT}/.staging.XXXXXX")"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GOOGLE_CONFIGURED=false
GOOGLE_STATUS=disabled
LAST_ERROR=""

if [[ -n "${RCLONE_REMOTE:-}" ]]; then GOOGLE_CONFIGURED=true; GOOGLE_STATUS=pending; fi

write_status() {
	python3 - "$STATUS_FILE" "$STARTED_AT" "${1:-}" "${2:-}" "$FILENAME" "$LAST_ERROR" "$GOOGLE_CONFIGURED" "$GOOGLE_STATUS" <<'PY'
import json, os, sys, tempfile
path, attempt, success, running, filename, error, configured, cloud = sys.argv[1:]
data = {
    "lastAttemptAt": attempt or None,
    "lastSuccessAt": success or None,
    "lastFilename": filename or None,
    "lastError": error or None,
    "googleDriveConfigured": configured == "true",
    "googleDriveStatus": cloud,
    "running": running == "true",
}
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".status.", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False)
os.replace(tmp, path)
PY
	chown root:glukvpn "$STATUS_FILE"
	chmod 0640 "$STATUS_FILE"
}

notify() {
	local text="$1"
	if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then return 0; fi
	curl --fail --silent --show-error --max-time 15 \
		--data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
		--data-urlencode "text=${text}" \
		"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null || true
}

fail() {
	local code=$?
	LAST_ERROR="backup failed at line ${BASH_LINENO[0]} (exit ${code})"
	GOOGLE_STATUS=failed
	write_status "" false || true
	notify "❌ GlukVPN backup failed: ${LAST_ERROR}" || true
	rm -rf "$STAGING"
	exit "$code"
}
trap fail ERR
trap 'rm -rf "$STAGING"' EXIT

write_status "" true
mkdir -p "$STAGING/dumps" "$STAGING/snapshot"

runuser -u postgres -- pg_dump -Fc glukvpn >"$STAGING/dumps/glukvpn.dump"
runuser -u postgres -- pg_dump -Fc glukvpn_beta >"$STAGING/dumps/glukvpn_beta.dump"
runuser -u postgres -- pg_dumpall --globals-only >"$STAGING/dumps/postgres-globals.sql"

copy_path() {
	local source="$1"
	if [[ ! -e "$source" ]]; then return 0; fi
	tar -C / \
		--exclude='node_modules' --exclude='.git' --exclude='dist/.cache' \
		--exclude='.dart_tool' --exclude='build' --exclude='coverage' \
		--exclude='var/www/vpn.gluk.tech/downloads' \
		-cf - "${source#/}" | tar -C "$STAGING/snapshot" -xf -
}

copy_path /etc/glukvpn
copy_path /etc/amnezia
copy_path /etc/nginx
copy_path /etc/letsencrypt
copy_path /var/www/vpn.gluk.tech
for source in \
	/opt/glukvpn/control-server \
	/opt/glukvpn/beta-control-server \
	/opt/glukvpn/node-agent \
	/opt/glukvpn/beta-node-agent; do
	copy_path "$source"
done

mkdir -p "$STAGING/snapshot/etc/systemd/system"
while IFS= read -r -d '' unit; do
	cp -a "$unit" "$STAGING/snapshot/etc/systemd/system/"
done < <(find /etc/systemd/system -maxdepth 1 \( -name 'glukvpn*' -o -name 'awg*' \) -print0)

if [[ ! -r "$RESTORE_SOURCE" ]]; then
	echo "restore script not found: $RESTORE_SOURCE" >&2
	exit 2
fi
cp "$RESTORE_SOURCE" "$STAGING/restore.sh"
chmod 0700 "$STAGING/restore.sh"
printf '%s\n' "$TIMESTAMP" >"$STAGING/BACKUP_CREATED_UTC"
printf '%s\n' "GlukVPN application disaster-recovery archive. Run: sudo ./restore.sh" >"$STAGING/README.txt"

tar -C "$STAGING" -czf "$ARCHIVE" .
chown root:glukvpn "$ARCHIVE"
chmod 0640 "$ARCHIVE"
printf '{"googleDrive":"%s"}\n' "$GOOGLE_STATUS" >"$SIDECAR"
chmod 0640 "$SIDECAR"

if [[ "$GOOGLE_CONFIGURED" == true ]]; then
	RCLONE_ARGS=()
	if [[ -n "${RCLONE_CONFIG:-}" ]]; then RCLONE_ARGS+=(--config "$RCLONE_CONFIG"); fi
	if rclone "${RCLONE_ARGS[@]}" copyto "$ARCHIVE" "${RCLONE_REMOTE%/}/${FILENAME}" --checksum --retries 3; then
		GOOGLE_STATUS=uploaded
		mapfile -t REMOTE_BACKUPS < <(rclone "${RCLONE_ARGS[@]}" lsf "${RCLONE_REMOTE%/}" --files-only --include 'glukvpn-backup-*.tar.gz' | sort -r)
		if (( ${#REMOTE_BACKUPS[@]} > RETENTION )); then
			for old in "${REMOTE_BACKUPS[@]:RETENTION}"; do
				rclone "${RCLONE_ARGS[@]}" deletefile "${RCLONE_REMOTE%/}/${old}"
			done
		fi
	else
		GOOGLE_STATUS=failed
		LAST_ERROR="archive created, Google Drive upload failed"
	fi
fi
printf '{"googleDrive":"%s"}\n' "$GOOGLE_STATUS" >"$SIDECAR"
chown root:glukvpn "$SIDECAR"
chmod 0640 "$SIDECAR"

mapfile -t LOCAL_BACKUPS < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'glukvpn-backup-*.tar.gz' -printf '%f\n' | sort -r)
if (( ${#LOCAL_BACKUPS[@]} > RETENTION )); then
	for old in "${LOCAL_BACKUPS[@]:RETENTION}"; do
		rm -f "$BACKUP_DIR/$old" "$BACKUP_DIR/$old.json"
	done
fi

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_status "$FINISHED_AT" false
SIZE="$(du -h "$ARCHIVE" | awk '{print $1}')"
if [[ "$GOOGLE_STATUS" == uploaded ]]; then
	notify "✅ GlukVPN backup ${FILENAME} (${SIZE}) created and uploaded to Google Drive."
elif [[ "$GOOGLE_STATUS" == disabled ]]; then
	notify "⚠️ GlukVPN backup ${FILENAME} (${SIZE}) created locally; Google Drive is not configured."
else
	notify "⚠️ GlukVPN backup ${FILENAME} (${SIZE}) created, but Google Drive upload failed."
fi

echo "$ARCHIVE"
