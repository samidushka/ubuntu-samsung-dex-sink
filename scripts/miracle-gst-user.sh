#!/bin/bash
# GStreamer player for miracle-sinkctl → visible window in the desktop session.
# sinkctl often runs as root. Without XAUTHORITY, autovideosink may pick a
# Wayland GL sink: pipeline PLAYING, no mapped window.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

dex_prepare_display_env

LOG="$(dex_session_runtime)/dex-tv-like/miracle-gst.log"
mkdir -p "$(dirname "$LOG")"

play() {
  local PORT=7236 AUDIO=0 DEBUG=0
  local UIBC_HOST="" UIBC_PORT=""
  # sinkctl --uibc -e: argv = player <source_ip> <uibc_port> -p … -r …
  if [[ "${1:-}" =~ ^[0-9A-Fa-f.:]+$ ]] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
    UIBC_HOST="$1"
    UIBC_PORT="$2"
    shift 2
  fi
  while getopts "r:d:as:p:h" opt; do
    case "$opt" in
      p) PORT="${OPTARG// /}" ;;
      a) AUDIO=1 ;;
      d) DEBUG="${OPTARG// /}" ;;
      r|s) ;;
      h) echo "miracle-gst-user [-p port] [-a]  |  [uibc_host uibc_port] -p port"; exit 0 ;;
    esac
  done

  echo "$(date -Is) start $* uid=$(id -u) DISPLAY=$DISPLAY XAUTHORITY=${XAUTHORITY:-} WAYLAND=$WAYLAND_DISPLAY player=dex-gst-player uibc=${UIBC_HOST:-none}:${UIBC_PORT:-}" >>"$LOG"

  PLAYER_PY="$SCRIPT_DIR/dex-gst-player.py"

  (
    export DISPLAY XAUTHORITY XDG_RUNTIME_DIR
    for _ in $(seq 1 80); do
      sleep 0.25
      if command -v xdotool >/dev/null; then
        ids="$(xdotool search --name 'DeX (Miracast)' 2>/dev/null || true)"
        [[ -z "$ids" ]] && ids="$(xdotool search --class GStreamer 2>/dev/null || true)"
        if [[ -n "$ids" ]]; then
          for id in $ids; do
            xdotool windowmove "$id" 40 40 windowactivate "$id" windowraise "$id" 2>/dev/null || true
          done
          echo "$(date -Is) xdotool move ids=$ids" >>"$LOG"
          break
        fi
      fi
    done
  ) &

  extra=()
  [[ -n "$UIBC_HOST" && -n "$UIBC_PORT" ]] && extra+=("$UIBC_HOST" "$UIBC_PORT")
  extra+=(-p "$PORT" -r "1920x1080")
  [[ "$AUDIO" == 1 ]] && extra+=(-a)
  [[ "$DEBUG" != 0 ]] && extra+=(-d "$DEBUG")
  echo "$(date -Is) exec $PLAYER_PY ${extra[*]}" >>"$LOG"
  exec python3 "$PLAYER_PY" "${extra[@]}" >>"$LOG" 2>&1
}

if [[ "$(id -u)" -eq 0 ]]; then
  SESSION_USER="$(dex_session_user)"
  [[ "$SESSION_USER" != "root" ]] || { echo "no desktop user for player" >&2; exit 1; }
  exec runuser -u "$SESSION_USER" -- env \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="${XAUTHORITY:-}" \
    GDK_BACKEND=x11 \
    GST_GL_WINDOW=x11 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
    HOME="$(dex_session_home)" USER="$SESSION_USER" LOGNAME="$SESSION_USER" \
    bash "$0" "$@"
fi

play "$@"
