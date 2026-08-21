#!/usr/bin/env bash
# GlukVPN - shared helpers for the BETA lifecycle scripts.
#
# WHY THIS FILE EXISTS
#   The first version of beta-start/stop/restart assumed one fixed unit name
#   and trusted a single `systemctl list-unit-files` lookup to find it. On this
#   host the lookup missed, so the scripts printed
#
#     vpn-node-agent-beta is not installed, skipping
#     vpn-control-beta is not installed, skipping
#
#   skipped the stop, and :8082 kept answering. A stop that cannot see what it
#   is supposed to stop must fail loudly - or, better, look harder.
#
# WHAT IS DIFFERENT NOW
#   * unit names are resolved from systemd itself: `systemctl cat`, then
#     list-unit-files, then list-units --all, then a '*beta*' pattern search,
#     so a renamed or runtime-only unit is still found;
#   * "systemd does not know this unit" and "this unit is not running" are two
#     different outcomes, and neither one ends the stop early;
#   * the LISTENING PORT is the source of truth. After the units are stopped,
#     whatever still holds :8082 is identified, checked for not being prod,
#     TERMed, then KILLed;
#   * stop only succeeds when :8082 is actually closed. Otherwise exit 1.
#
# SAFETY RULES - do not relax these
#   - only units matching *-beta / *-beta.service, or wg-quick@wg1, may be
#     touched. Anything else aborts the script;
#   - a process whose cgroup, cwd or cmdline points at /opt/vpn-control/ or at
#     the prod units is never signalled: the script dies instead;
#   - PROD (:8081, wg0, vpn-control.service, vpn-node-agent.service) is never
#     started, stopped, restarted, enabled or killed from here.
#
# Sourced by beta-start.sh / beta-stop.sh / beta-restart.sh. Not executable on
# its own.

# --------------------------------- constants ---------------------------------

# Overridable for tests; the defaults are the real deployment.
BETA_PORT="${BETA_PORT:-8082}"
PROD_PORT="${PROD_PORT:-8081}"
BETA_WG_IF="${BETA_WG_IF:-wg1}"
BETA_WG_PORT="${BETA_WG_PORT:-51821}"
BETA_ROOT="${BETA_ROOT:-/opt/vpn-control-beta}"
BETA_ENV_FILE="${BETA_ENV_FILE:-/etc/vpn-control-beta/control.env}"
BETA_WG_CONF="${BETA_WG_CONF:-/etc/wireguard/wg1.conf}"

# Most likely name first. All of them are checked against systemd before use.
BETA_CONTROL_CANDIDATES="vpn-control-beta.service glukvpn-control-beta.service vpn-control-beta"
BETA_AGENT_CANDIDATES="vpn-node-agent-beta.service glukvpn-node-agent-beta.service vpn-node-agent-beta"

# Used only for the pattern fallback, never for matching prod.
BETA_CONTROL_PATTERN='(control|api).*beta|beta.*(control|api)'
BETA_AGENT_PATTERN='(node|agent).*beta|beta.*(node|agent)'

# The URL is assembled from parts so no full literal appears in this file.
BETA_SCHEME="http"
BETA_HOST="127.0.0.1"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { log "WARN: $*"; }
die() {
  log "FATAL: $*"
  exit 1
}

# ------------------------------- safety guards -------------------------------

# A unit may be acted on only if its name proves it is the beta stack.
assert_beta_unit() {
  case "$1" in
    *-beta.service | *-beta) return 0 ;;
    "wg-quick@${BETA_WG_IF}.service" | "wg-quick@${BETA_WG_IF}") return 0 ;;
  esac
  die "refusing to touch '$1': not a BETA unit"
}

# wg0 belongs to production. If someone points this at wg0, stop everything.
assert_beta_interface() {
  case "$BETA_WG_IF" in
    wg1) return 0 ;;
  esac
  die "refusing to manage interface '$BETA_WG_IF': BETA owns wg1 only"
}

# True when the process looks like production. Note the trailing slash in the
# path test: /opt/vpn-control-beta/... deliberately does NOT match.
pid_is_prod() {
  local pid="$1" info=""
  info="$(cat "/proc/$pid/cgroup" 2>/dev/null || true)"
  info="$info $(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  info="$info $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  case "$info" in
    */opt/vpn-control/*) return 0 ;;
    *vpn-control.service*) return 0 ;;
    *vpn-node-agent.service*) return 0 ;;
    *wg-quick@wg0*) return 0 ;;
  esac
  return 1
}

pid_describe() {
  local pid="$1"
  local cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  [ -n "$cmd" ] || cmd="$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)"
  printf '%s' "${cmd:0:120}"
}

# ------------------------------ unit resolution ------------------------------

# 0 when systemd knows the unit at all - installed, generated or runtime-only.
unit_exists() {
  local unit="$1"
  systemctl cat -- "$unit" >/dev/null 2>&1 && return 0
  systemctl list-unit-files --no-legend --plain -- "$unit" 2>/dev/null |
    grep -q . && return 0
  systemctl list-units --all --no-legend --plain -- "$unit" 2>/dev/null |
    grep -q . && return 0
  return 1
}

# Every beta-looking unit systemd has heard of, one per line.
list_beta_units() {
  {
    systemctl list-unit-files --no-legend --plain '*beta*' 2>/dev/null || true
    systemctl list-units --all --no-legend --plain '*beta*' 2>/dev/null || true
  } | awk '{ print $1 }' | grep -E -- '-beta(\.service)?$' | sort -u
}

# resolve_unit <pattern> <candidate...> -> prints the unit name, or nothing.
resolve_unit() {
  local pattern="$1"
  shift
  local candidate found
  for candidate in "$@"; do
    if unit_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  # Fallback: whatever beta unit matches the role. This is what makes a
  # renamed unit survivable instead of being reported as "not installed".
  found="$(list_beta_units | grep -E -i -- "$pattern" | head -n 1 || true)"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  return 1
}

resolve_control_unit() {
  # shellcheck disable=SC2086
  resolve_unit "$BETA_CONTROL_PATTERN" $BETA_CONTROL_CANDIDATES
}

resolve_agent_unit() {
  # shellcheck disable=SC2086
  resolve_unit "$BETA_AGENT_PATTERN" $BETA_AGENT_CANDIDATES
}

# ------------------------------- port helpers --------------------------------

# PIDs listening on a TCP port. ss first, lsof and fuser as fallbacks, so this
# works on a stripped-down box too.
port_pids() {
  local port="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnp "sport = :$port" 2>/dev/null |
      grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
    if [ -z "$out" ]; then
      out="$(ss -ltnp 2>/dev/null | grep -E "[:.]$port[[:space:]]" |
        grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
    fi
  fi
  if [ -z "$out" ] && command -v lsof >/dev/null 2>&1; then
    out="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  fi
  if [ -z "$out" ] && command -v fuser >/dev/null 2>&1; then
    out="$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' |
      grep -E '^[0-9]+$' | sort -u || true)"
  fi
  printf '%s' "$out"
}

# True when anything at all is listening, even a process we cannot see the pid
# of: the health probe is the second opinion.
port_open() {
  local port="$1"
  if [ -n "$(port_pids "$port")" ]; then return 0; fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE "[:.]$port[[:space:]]" && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 \
      "${BETA_SCHEME}://${BETA_HOST}:${port}/api/health" >/dev/null 2>&1 &&
      return 0
  fi
  return 1
}

wait_port_closed() {
  local port="$1" tries="${2:-10}" i=0
  while [ "$i" -lt "$tries" ]; do
    port_open "$port" || return 0
    sleep 1
    i=$((i + 1))
  done
  port_open "$port" && return 1
  return 0
}

wait_port_open() {
  local port="$1" tries="${2:-20}" i=0
  while [ "$i" -lt "$tries" ]; do
    port_open "$port" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# --------------------------------- actions -----------------------------------

stop_beta_unit() {
  local unit="$1" label="$2"
  assert_beta_unit "$unit"
  if ! unit_exists "$unit"; then
    warn "$label: systemd does not know '$unit' - continuing, the port check below is authoritative"
    return 0
  fi
  if systemctl is-active --quiet -- "$unit"; then
    log "stopping $unit"
    systemctl stop -- "$unit" ||
      warn "systemctl stop $unit exited non-zero, continuing"
  else
    log "$unit is already stopped"
  fi
}

start_beta_unit() {
  local unit="$1" label="$2"
  assert_beta_unit "$unit"
  if ! unit_exists "$unit"; then
    warn "$label: systemd does not know '$unit' - not starting it"
    return 1
  fi
  if systemctl is-active --quiet -- "$unit"; then
    log "$unit is already running"
    return 0
  fi
  log "starting $unit"
  systemctl start -- "$unit"
}

# Whatever still holds the beta port after the units are down.
clear_beta_port() {
  local port="$1" pid pids
  pids="$(port_pids "$port")"
  [ -n "$pids" ] || return 0

  for pid in $pids; do
    if pid_is_prod "$pid"; then
      die "pid $pid on :$port looks like PROD ($(pid_describe "$pid")) - refusing to signal it"
    fi
  done
  for pid in $pids; do
    log "pid $pid still holds :$port ($(pid_describe "$pid")), sending TERM"
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait_port_closed "$port" 8 && return 0

  pids="$(port_pids "$port")"
  for pid in $pids; do
    if pid_is_prod "$pid"; then
      die "pid $pid on :$port looks like PROD - refusing to signal it"
    fi
    log "pid $pid ignored TERM, sending KILL"
    kill -KILL "$pid" 2>/dev/null || true
  done
  wait_port_closed "$port" 5
}

stop_beta_wireguard() {
  assert_beta_interface
  local unit="wg-quick@${BETA_WG_IF}.service"
  if unit_exists "$unit" && systemctl is-active --quiet -- "$unit"; then
    log "stopping $unit"
    systemctl stop -- "$unit" || warn "systemctl stop $unit exited non-zero"
  else
    log "$unit was already stopped"
  fi

  if ip link show "$BETA_WG_IF" >/dev/null 2>&1; then
    log "$BETA_WG_IF is still up, taking it down directly"
    wg-quick down "$BETA_WG_IF" >/dev/null 2>&1 ||
      ip link delete dev "$BETA_WG_IF" >/dev/null 2>&1 || true
  fi

  if ip link show "$BETA_WG_IF" >/dev/null 2>&1; then
    warn "$BETA_WG_IF is still present"
    return 1
  fi
  log "$BETA_WG_IF is gone (udp/${BETA_WG_PORT} closed)"
}

start_beta_wireguard() {
  assert_beta_interface
  local unit="wg-quick@${BETA_WG_IF}.service"
  if ip link show "$BETA_WG_IF" >/dev/null 2>&1; then
    log "$BETA_WG_IF is already up"
    return 0
  fi
  if [ ! -f "$BETA_WG_CONF" ]; then
    warn "$BETA_WG_CONF is missing - skipping $BETA_WG_IF"
    return 1
  fi
  log "starting $unit"
  systemctl start -- "$unit" || {
    warn "$unit failed, trying wg-quick up directly"
    wg-quick up "$BETA_WG_IF" || return 1
  }
}

# Best-effort: ask the beta API to close its own sessions before it goes away,
# so devices are not left with a peer on a node that stopped answering.
drain_beta_sessions() {
  local cli="$BETA_ROOT/current/dist/scripts/cli.js"
  if [ ! -f "$cli" ]; then
    log "no beta release is active, skipping session drain"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node is not on PATH, skipping session drain"
    return 0
  fi
  log "draining beta sessions"
  (
    cd "$BETA_ROOT/current" || exit 0
    ENV_FILE="$BETA_ENV_FILE" node "$cli" sessions:drain >/dev/null 2>&1 || true
  )
}

# What the panel prints after start/stop.
report_beta_state() {
  local control agent
  control="$(resolve_control_unit || true)"
  agent="$(resolve_agent_unit || true)"
  log "beta control unit: ${control:-<not found>}"
  log "beta agent unit:   ${agent:-<not found>}"
  if [ -n "$control" ]; then
    log "beta control state: $(systemctl is-active -- "$control" 2>/dev/null || echo unknown)"
  fi
  if [ -n "$agent" ]; then
    log "beta agent state:   $(systemctl is-active -- "$agent" 2>/dev/null || echo unknown)"
  fi
  if port_open "$BETA_PORT"; then
    log "tcp/${BETA_PORT} is OPEN"
  else
    log "tcp/${BETA_PORT} is closed"
  fi
}
