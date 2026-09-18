#!/usr/bin/env bash
# GUI stop for the Miracast DeX sink.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STOP="$SCRIPT_DIR/dex-tv-like-stop.sh"
PROMPT="$SCRIPT_DIR/dex-sudo-prompt.sh"
if [[ -x "$STOP" ]]; then
  env SUDO_ASKPASS="$PROMPT" "$STOP" || true
else
  zenity --error --text="Missing $STOP" 2>/dev/null || true
  exit 1
fi
pkill -f 'dex-sink-run-now' 2>/dev/null || true
pkill -f 'miracle-gst' 2>/dev/null || true
notify-send "DeX sink" "Stopped" 2>/dev/null || true
zenity --info --text="DeX sink stopped." 2>/dev/null || true
