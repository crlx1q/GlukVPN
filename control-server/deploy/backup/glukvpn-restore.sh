#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT="$ROOT/snapshot"
DUMPS="$ROOT/dumps"

if [[ "${EUID}" -ne 0 ]]; then
	echo "Run as root: sudo ./restore.sh" >&2
	exit 1
fi
if [[ ! -d "$SNAPSHOT" || ! -d "$DUMPS" ]]; then
	echo "snapshot/ or dumps/ is missing; unpack the complete archive first" >&2
	exit 2
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl nginx postgresql postgresql-client nodejs npm rclone wireguard-tools software-properties-common
if ! command -v awg >/dev/null 2>&1; then
	add-apt-repository -y ppa:amnezia/ppa || true
	apt-get update || true
	apt-get install -y amneziawg-tools amneziawg-dkms || true
fi

if ! getent group glukvpn >/dev/null; then groupadd --system glukvpn; fi
if ! id glukvpn >/dev/null 2>&1; then
	useradd --system --gid glukvpn --home-dir /opt/glukvpn --shell /usr/sbin/nologin glukvpn
fi

cp -a "$SNAPSHOT/." /
chown -R glukvpn:glukvpn /opt/glukvpn
if [[ -d /etc/glukvpn ]]; then
	chown -R root:glukvpn /etc/glukvpn
	find /etc/glukvpn -type d -exec chmod 0750 {} +
	find /etc/glukvpn -type f -exec chmod 0640 {} +
fi
if [[ -d /var/www/vpn.gluk.tech ]]; then chown -R www-data:www-data /var/www/vpn.gluk.tech; fi

systemctl enable --now postgresql
if [[ -s "$DUMPS/postgres-globals.sql" ]]; then
	sudo -u postgres psql --set ON_ERROR_STOP=1 -f "$DUMPS/postgres-globals.sql" || \
		echo "warning: some PostgreSQL globals already existed; continuing" >&2
fi
for database in glukvpn glukvpn_beta; do
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${database}'" | grep -q 1; then
		sudo -u postgres createdb "$database"
	fi
	sudo -u postgres pg_restore --clean --if-exists --no-owner --dbname="$database" "$DUMPS/${database}.dump"
done

for directory in \
	/opt/glukvpn/control-server \
	/opt/glukvpn/beta-control-server \
	/opt/glukvpn/node-agent \
	/opt/glukvpn/beta-node-agent; do
	if [[ ! -f "$directory/package.json" ]]; then continue; fi
	(
		cd "$directory"
		if [[ -f package-lock.json ]]; then npm ci; else npm install; fi
		npm run build --if-present
	)
done

systemctl daemon-reload
nginx -t
systemctl enable --now nginx
for service in \
	glukvpn-control \
	glukvpn-beta-control \
	glukvpn-node-agent \
	glukvpn-beta-node-agent \
	glukvpn-browser-proxy \
	glukvpn-beta-browser-proxy \
	glukvpn-deploy-worker \
	glukvpn-egress-guard \
	glukvpn-singbox \
	glukvpn-singbox-reload.path \
	awg-quick@awg0; do
	if systemctl cat "${service}.service" >/dev/null 2>&1 || [[ "$service" == *.path ]] || [[ "$service" == awg* ]]; then
		systemctl enable --now "$service" || true
	fi
done
if systemctl cat glukvpn-backup.timer >/dev/null 2>&1; then systemctl enable --now glukvpn-backup.timer; fi

echo "Restore complete. Verify API health, node heartbeats, DNS/TLS and a real VPN connection."
