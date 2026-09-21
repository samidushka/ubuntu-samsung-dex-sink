#!/usr/bin/env bash
# Restart only the video window (UDP 7236). Leaves P2P / sinkctl running.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"
dex_prepare_display_env
export GDK_SCALE=1 GDK_DPI_SCALE=1
LOG="$(dex_session_runtime)/dex-tv-like/miracle-gst.log"
mkdir -p "$(dirname "$LOG")"

while read -r pid cmd; do
  [[ "$cmd" == python3*dex-gst-input.py* || "$cmd" == python3*dex-gst-player.py* ]] && kill "$pid" 2>/dev/null || true
done < <(ps -C python3 -o pid=,cmd= 2>/dev/null || true)

sleep 0.4
extra=()
if [[ -n "${DEX_UIBC_HOST:-}" && "${DEX_UIBC_PORT:-}" =~ ^[0-9]+$ ]]; then
  extra+=("$DEX_UIBC_HOST" "$DEX_UIBC_PORT")
elif [[ -f "$LOG" ]]; then
  last="$(grep -Eo 'uibc=[0-9A-Fa-f.:]+:[0-9]+' "$LOG" | tail -1 || true)"
  if [[ "$last" =~ uibc=([^:]+):([0-9]+)$ ]]; then
    extra+=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
  fi
fi
exec python3 "$SCRIPT_DIR/dex-gst-player.py" "${extra[@]}" -p 7236 -a -r 1920x1080 >>"$LOG" 2>&1
