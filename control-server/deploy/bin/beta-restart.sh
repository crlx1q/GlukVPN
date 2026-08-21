#!/usr/bin/env bash
# GlukVPN - restart the BETA channel by running the verified stop, then the
# verified start. PROD is never touched.
#
# It deliberately does NOT reimplement either half: a restart that stops
# differently from stop is how "restart succeeded but :8082 is still the old
# process" happens. If the stop cannot prove the port is closed, the restart
# fails here and the start is never attempted.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f /etc/glukvpn-deploy/beta.env ]; then
  # shellcheck source=/dev/null
  . /etc/glukvpn-deploy/beta.env
fi

# shellcheck source=beta-lib.sh
. "$HERE/beta-lib.sh"

log "=== RESTART BETA ==="

"$HERE/beta-stop.sh"
"$HERE/beta-start.sh"

log "=== BETA RESTARTED ==="
