#!/usr/bin/env bash
# Samsung Smart View sends P2P-INVITATION (phone = GO). Stock miraclecast
# ignores it. Listen on wpa_cli and join: p2p_connect <sa> pbc join.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

STATE="$(dex_session_runtime)/dex-tv-like"
LOG="$STATE/p2p-join.log"
PIDFILE="$STATE/p2p-join.pid"
CTRL_DIR="/run/miracle/wifi"
mkdir -p "$STATE"

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

wpa() {
  local global
  global="$(ls -1 "$CTRL_DIR"/*.global 2>/dev/null | head -1 || true)"
  if [[ -n "$global" ]]; then
    wpa_cli -g "$global" "$@"
  else
    local ifc
    ifc="$(p2p_if)"
    wpa_cli -p "$CTRL_DIR" -i "$ifc" "$@"
  fi
}

p2p_if() {
  local ifc
  ifc="$(basename "$(ls -1 "$CTRL_DIR"/p2p-dev-* 2>/dev/null | head -1 || true)")"
  if [[ -n "$ifc" ]]; then
    printf '%s\n' "$ifc"
    return
  fi
  local wifi
  wifi="$(dex_wifi_iface)"
  printf 'p2p-dev-%s\n' "${wifi:-wlan0}"
}

cmd_action() {
  # wpa_cli -a: $1=ifname, then event words (no quotes).
  local sa="" ev="" a
  shift || true
  for a in "$@"; do
    case "$a" in
      P2P-INVITATION-RECEIVED*) ev=invite ;;
      P2P-GROUP-STARTED*) ev=group; log "event group $*" ;;
      sa=*) sa="${a#sa=}" ;;
    esac
  done
  [[ "$ev" == "invite" && -n "$sa" ]] || exit 0
  log "INVITATION sa=$sa — join"
  (
    wpa p2p_connect "$sa" pbc join >>"$LOG" 2>&1 || true
    sleep 2
    if ! ip -br link 2>/dev/null | grep -q '^p2p-'; then
      log "join did not bring up p2p-* — P2P_CONNECT pbc"
      wpa p2p_connect "$sa" pbc >>"$LOG" 2>&1 || true
    fi
  ) &
  exit 0
}

cmd_start() {
  : >"$LOG"
  log "start"
  local ifc global
  ifc="$(p2p_if)"
  global="$(ls -1 "$CTRL_DIR"/*.global 2>/dev/null | head -1 || true)"
  [[ -n "$global" ]] || { log "no global ctrl $CTRL_DIR"; exit 1; }
  wpa_cli -g "$global" set persistent_reconnect 1 >>"$LOG" 2>&1 || true
  pkill -f 'wpa_cli .*dex-p2p-join-on-invite' 2>/dev/null || true
  nohup wpa_cli -p "$CTRL_DIR" -i "$ifc" -a "$0" >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  log "wpa_cli -a pid=$(cat "$PIDFILE") if=$ifc"
}

cmd_stop() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f 'wpa_cli .*dex-p2p-join-on-invite' 2>/dev/null || true
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  *) cmd_action "$@" ;;
esac
