#!/usr/bin/env bash
# ============================================================================
# RESTART BETA
#
# Stop, then start. Kept as its own action so the audit log records "restart"
# rather than two unrelated jobs, and so a half-finished restart cannot be
# mistaken for a deliberate Beta OFF.
#
# PROD IS NOT TOUCHED.
#
# Takes no arguments. Run by the deploy worker, or by hand:
#   sudo /opt/glukvpn-deploy/bin/beta-restart.sh
# ============================================================================

set -Eeuo pipefail
# shellcheck source=/opt/glukvpn-deploy/bin/common.sh
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SELF_DIR}/common.sh"

log "=== RESTART BETA ==="

"${SELF_DIR}/beta-stop.sh"

# Give systemd a moment to release the port and tear down the interface before
# the start script asserts they are back.
sleep 2

"${SELF_DIR}/beta-start.sh"

log "=== RESTART BETA OK ==="
