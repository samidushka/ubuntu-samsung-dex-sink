#!/usr/bin/env bash
# Start mouse/keyboard overlay for a gst-launch window. Does not kill video.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"
dex_prepare_display_env
export GDK_SCALE=1 GDK_DPI_SCALE=1
LOG="$(dex_session_runtime)/dex-tv-like/gst-input.log"
mkdir -p "$(dirname "$LOG")"
while read -r pid cmd; do
  [[ "$cmd" == *dex-gst-input.py* ]] && kill "$pid" 2>/dev/null || true
done < <(ps -C python3 -o pid=,cmd= 2>/dev/null || true)
sleep 0.2
exec python3 "$SCRIPT_DIR/dex-gst-input.py" >>"$LOG" 2>&1
