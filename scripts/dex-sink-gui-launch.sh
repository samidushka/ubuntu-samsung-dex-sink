#!/usr/bin/env bash
# Menu / desktop launcher for the Miracast DeX sink.
# sudo password: zenity dialog (not written to disk).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

STATE="$(dex_session_runtime)/dex-tv-like"
mkdir -p "$STATE"
RUN_NOW="$SCRIPT_DIR/dex-sink-run-now.sh"
STOP="$SCRIPT_DIR/dex-tv-like-stop.sh"
OUT="$STATE/gui-launch.out"
PROMPT="$SCRIPT_DIR/dex-sudo-prompt.sh"

notify() {
  command -v notify-send >/dev/null && notify-send -u "${2:-normal}" "DeX sink" "$1" || true
}

if [[ ! -x "$RUN_NOW" ]]; then
  zenity --error --text="Missing $RUN_NOW"$'\n'"Run scripts/dex-tv-like-install.sh first." 2>/dev/null || true
  exit 1
fi

if pgrep -x miracle-sinkctl >/dev/null 2>&1; then
  zenity --question --title="DeX sink" \
    --text="Sink is already running."$'\n\n'"Stop and start again?" \
    --ok-label="Restart" --cancel-label="Leave it" 2>/dev/null || exit 0
  if [[ -x "$STOP" ]]; then
    SUDO_ASKPASS="$PROMPT" "$STOP" >/dev/null 2>&1 || true
    sleep 1
  fi
fi

notify "Starting DeX sink…" normal
: >"$OUT"
nohup env SUDO_ASKPASS="$PROMPT" "$RUN_NOW" >"$OUT" 2>&1 &
LAUNCH_PID=$!

ok=0
for _ in $(seq 1 30); do
  sleep 1
  if grep -q "FriendlyName=" "$OUT" 2>/dev/null && grep -q "Managed=true" "$OUT" 2>/dev/null; then
    ok=1
    break
  fi
  if grep -q "\[FAIL\]" "$OUT" 2>/dev/null; then
    break
  fi
  kill -0 "$LAUNCH_PID" 2>/dev/null || break
done

NAME="$(grep -o 'FriendlyName=[^[:space:]]*' "$OUT" 2>/dev/null | tail -1 | cut -d= -f2)"
NAME="${NAME:-Ubuntu-DeX}"

if [[ "$ok" -eq 1 ]]; then
  notify "On air: ${NAME}. Phone: DeX → TV → ${NAME}" critical
  zenity --info --title="DeX sink" --width=420 \
    --text="On air: <b>${NAME}</b>"$'\n\n'"On the phone:"$'\n'"1) DeX → “TV or monitor”"$'\n'"2) Choose <b>${NAME}</b>"$'\n\n'"The video window appears after CONNECT."$'\n'"Stop: “DeX stop” in the app menu." 2>/dev/null || true
else
  notify "Did not come up — see the log" critical
  zenity --error --title="DeX sink" --width=480 \
    --text="Could not start the sink."$'\n\n'"Log:"$'\n'"$OUT"$'\n\n'"$(tail -20 "$OUT" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')" 2>/dev/null || true
  exit 1
fi
