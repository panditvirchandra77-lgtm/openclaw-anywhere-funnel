#!/bin/sh
# keepalive.sh - idempotent start/re-raise for a dedicated tailscaled + Tailscale Funnel
# on a PRoot sandbox (Altare / Pterodactyl-style).
#
# Why OperatorUser="container": inside PRoot, getuid() returns 0 but the
# socket SO_PEERCRED shows uid 999 ("container"). Tailscale authorizes writes
# against the peercred uid, so the operator MUST be "container".
#
# Usage:
#   export TS_AUTHKEY="tskey-auth-..."   # only needed for the very first login
#   sh keepalive.sh
#
# Safe to run repeatedly: exits 0 immediately if the daemon is already healthy.

set -u

DIR="${OCANYWHERE_DIR:-/workspace/ocanywhere}"
STATE="${TS_STATEDIR:-/workspace/tailscale-state}"
SOCK="${TS_SOCKET:-/tmp/tailscaled.sock}"
HOSTNAME_TS="${TS_HOSTNAME:-glasswing-anywhere}"
FUNNEL_PORT="${FUNNEL_PORT:-18789}"          # local service to expose
FUNNEL_HTTPS_PORT="${FUNNEL_HTTPS_PORT:-443}" # public HTTPS port
LOG="$DIR/tailscaled.log"

mkdir -p "$DIR" "$STATE"

# --- write the config that seeds OperatorUser=container ---------------------
cat > "$DIR/config.json" <<'CFG'
{
  "Version": "alpha0",
  "Locked": false,
  "ServerURL": "",
  "OperatorUser": "container"
}
CFG

ts() { /usr/bin/tailscale --socket="$SOCK" "$@"; }

healthy() {
  [ -S "$SOCK" ] && ts status >/dev/null 2>&1
}

start() {
  rm -f "$SOCK"
  /usr/sbin/tailscaled --tun=userspace-networking \
    --statedir="$STATE" --state="$STATE/tailscaled.state" \
    --config="$DIR/config.json" --socket="$SOCK" >>"$LOG" 2>&1 &
  echo $! > "$DIR/tailscaled.pid"
  sleep 6

  # Log in only if the node is not already authenticated (state persists).
  if [ -n "${TS_AUTHKEY:-}" ]; then
    ts up --hostname="$HOSTNAME_TS" --authkey="$TS_AUTHKEY" --timeout=30s >>"$LOG" 2>&1 || true
  fi

  # Ensure Funnel is on (idempotent).
  ts funnel --bg --https="$FUNNEL_HTTPS_PORT" "$FUNNEL_PORT" >>"$LOG" 2>&1 || \
    ts funnel --bg "$FUNNEL_PORT" >>"$LOG" 2>&1 || true
}

if healthy; then
  exit 0
fi

start
