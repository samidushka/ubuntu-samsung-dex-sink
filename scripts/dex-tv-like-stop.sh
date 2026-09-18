#!/usr/bin/env bash
# Stop Miracast sink; return Wi‑Fi to NetworkManager. Ethernet is not touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

STATE_DIR="$(dex_session_runtime)/dex-tv-like"
PID_WIFID="$STATE_DIR/miracle-wifid.pid"
STATE_FILE="$STATE_DIR/session.env"

WIFI_DEV=""
WIFI_CONN=""
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"

if [[ -z "${SUDO_ASKPASS:-}" && -t 0 ]]; then
  :
elif [[ -z "${SUDO_ASKPASS:-}" && -x "$SCRIPT_DIR/dex-sudo-prompt.sh" ]] && command -v zenity >/dev/null; then
  export SUDO_ASKPASS="$SCRIPT_DIR/dex-sudo-prompt.sh"
  sudo() { command sudo -A "$@"; }
fi

echo "Stopping miraclecast…"
JOIN_HELPER="$SCRIPT_DIR/dex-p2p-join-on-invite.sh"
if [[ -x "$JOIN_HELPER" ]]; then
  sudo "$JOIN_HELPER" stop 2>/dev/null || true
fi
pkill -f 'dex-p2p-join-on-invite' 2>/dev/null || true
pkill -f 'dex-sink-run-now' 2>/dev/null || true
pkill -f 'sleep infinity' 2>/dev/null || true
pkill -f 'miracle-gst' 2>/dev/null || true
while read -r pid cmd; do
  [[ "$cmd" == *dex-gst-input.py* || "$cmd" == *dex-gst-player.py* ]] && kill "$pid" 2>/dev/null || true
done < <(ps -C python3 -o pid=,cmd= 2>/dev/null || true)
if [[ -f "$PID_WIFID" ]]; then
  sudo kill "$(cat "$PID_WIFID")" 2>/dev/null || true
  rm -f "$PID_WIFID"
fi
sudo pkill -x miracle-wifid 2>/dev/null || true
sudo pkill -x miracle-sinkctl 2>/dev/null || true
sudo pkill -x miracle-uibcctl 2>/dev/null || true
rm -f "$STATE_DIR/sinkctl-wrap.pid"
sleep 1

sudo systemctl start NetworkManager.service 2>/dev/null || true
sudo rfkill unblock wifi || true
nmcli radio wifi on 2>/dev/null || sudo nmcli radio wifi on 2>/dev/null || true

if [[ -z "${WIFI_DEV:-}" ]]; then
  WIFI_DEV="$(dex_wifi_iface)"
fi

if [[ -n "${WIFI_DEV:-}" ]]; then
  echo "Returning Wi‑Fi ${WIFI_DEV} to NetworkManager…"
  nmcli device set "$WIFI_DEV" managed yes 2>/dev/null || sudo nmcli device set "$WIFI_DEV" managed yes || true
  if [[ -n "${WIFI_CONN:-}" && "$WIFI_CONN" != "--" ]]; then
    nmcli connection up id "$WIFI_CONN" ifname "$WIFI_DEV" 2>/dev/null || \
      sudo nmcli connection up id "$WIFI_CONN" ifname "$WIFI_DEV" 2>/dev/null || true
  else
    nmcli device connect "$WIFI_DEV" 2>/dev/null || true
  fi
fi

rm -f "$STATE_FILE"
echo "Done. Check: nmcli device status"
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status | sed -n '1,12p' || true
