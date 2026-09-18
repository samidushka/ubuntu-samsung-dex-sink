#!/usr/bin/env bash
# Miracast sink for Samsung DeX / Smart View “like a TV”.
# Ethernet stays in NetworkManager. Wi‑Fi is unmanaged for P2P.
# sinkctl only reads commands from a TTY → script(1).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

FRIENDLY="$(dex_friendly_name)"
WIFI="$(dex_wifi_iface)"
WIFI="${WIFI:-wlp1s0}"
STATE="$(dex_session_runtime)/dex-tv-like"
LOG="$STATE/miracle.log"
CMD_FILE="$STATE/sinkctl.cmds"
PLAYER_WRAP="${SCRIPT_DIR}/miracle-gst-user.sh"
mkdir -p "$STATE"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info() { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
die() { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

if [[ -z "${SUDO_ASKPASS:-}" && ! -t 0 && -x "$SCRIPT_DIR/dex-sudo-prompt.sh" ]] && command -v zenity >/dev/null; then
  export SUDO_ASKPASS="$SCRIPT_DIR/dex-sudo-prompt.sh"
  sudo() { command sudo -A "$@"; }
fi

command -v miracle-wifid >/dev/null || die "miracle-wifid not found (run dex-tv-like-install.sh)"
command -v miracle-sinkctl >/dev/null || die "miracle-sinkctl not found"
command -v script >/dev/null || die "script(1) not found (bsdutils / util-linux)"
[[ -x "$PLAYER_WRAP" ]] || die "missing player $PLAYER_WRAP"

ETH="$(dex_eth_iface)"
info "Ethernet: ${ETH:-none} (left as-is)"
info "Wi‑Fi P2P: $WIFI → «${FRIENDLY}»"
info "Window player: $PLAYER_WRAP"

nmcli device disconnect "$WIFI" 2>/dev/null || true
sudo nmcli device set "$WIFI" managed no
sudo rfkill unblock wifi || true
sudo ip link set "$WIFI" up
# UFW otherwise swallows RTP (UDP 7236) on the P2P iface after the socket moves:
# pipeline PLAYING, no frames, no window.
if command -v ufw >/dev/null 2>&1; then
  # 192.168.49.0/24 is the usual Wi‑Fi Direct / P2P-GO subnet (not your LAN).
  sudo ufw status 2>/dev/null | grep -q '192.168.49.0/24' || \
    sudo ufw allow from 192.168.49.0/24 comment 'miracle-dex-p2p' >/dev/null || true
  sudo ufw status 2>/dev/null | grep -q '7236/udp' || \
    sudo ufw allow 7236/udp comment 'miracle-dex-rtp' >/dev/null || true
fi
sleep 1

sudo pkill -x miracle-sinkctl 2>/dev/null || true
sudo pkill -x miracle-wifid 2>/dev/null || true
sleep 1

: >"$LOG"
# Phone wants to be GO. go-intent 15 on the laptop breaks DHCP/RTSP.
sudo miracle-wifid --log-level info --lazy-managed --go-intent 0 -i "$WIFI" >>"$LOG" 2>&1 &
sleep 2
pgrep -x miracle-wifid >/dev/null || die "miracle-wifid did not start"

LINK_PATH=""
LINK_RUN=""
for _ in $(seq 1 25); do
  sleep 0.4
  LINK_PATH="$(busctl --system tree org.freedesktop.miracle.wifi 2>/dev/null | sed -n 's|.*\(/org/freedesktop/miracle/wifi/link/_[0-9]*\).*|\1|p' | head -1)"
  if [[ -n "$LINK_PATH" ]]; then
    LINK_RUN="$(busctl --system get-property org.freedesktop.miracle.wifi "$LINK_PATH" org.freedesktop.miracle.wifi.Link InterfaceIndex 2>/dev/null | awk '{print $2}')"
    [[ -n "$LINK_RUN" ]] && break
  fi
done
[[ -n "$LINK_RUN" ]] || die "no miracle link — see $LOG"
LINK_CMD="$LINK_RUN"
info "link cmd=$LINK_CMD path=$LINK_PATH"

cat >"$CMD_FILE" <<EOF
set-managed ${LINK_CMD} yes
run ${LINK_CMD}
set-friendly-name ${FRIENDLY}
list
EOF

SESSION_UID="$(dex_session_uid)"
SESSION_RUNTIME="/run/user/${SESSION_UID}"
dex_prepare_display_env

info "sinkctl + pty + player + UIBC; mouse/keyboard in the video window"
(
  sleep 2
  while IFS= read -r line; do
    printf '%s\n' "$line"
    sleep 1
  done <"$CMD_FILE"
  sleep infinity
) | sudo script -qfc "env XDG_RUNTIME_DIR=${SESSION_RUNTIME} WAYLAND_DISPLAY=${WAYLAND_DISPLAY} DISPLAY=${DISPLAY} XAUTHORITY=${XAUTHORITY:-} miracle-sinkctl --uibc -e ${PLAYER_WRAP}" /dev/null >>"$LOG" 2>&1 &
SINK_WRAP_PID=$!
echo "$SINK_WRAP_PID" >"$STATE/sinkctl-wrap.pid"
sleep 8

FN="$(busctl --system get-property org.freedesktop.miracle.wifi "$LINK_PATH" org.freedesktop.miracle.wifi.Link FriendlyName 2>/dev/null | awk -F'"' '{print $2}')"
SCAN="$(busctl --system get-property org.freedesktop.miracle.wifi "$LINK_PATH" org.freedesktop.miracle.wifi.Link P2PScanning 2>/dev/null | awk '{print $2}')"
WFD="$(busctl --system get-property org.freedesktop.miracle.wifi "$LINK_PATH" org.freedesktop.miracle.wifi.Link WfdSubelements 2>/dev/null | awk -F'"' '{print $2}')"
MAN="$(busctl --system get-property org.freedesktop.miracle.wifi "$LINK_PATH" org.freedesktop.miracle.wifi.Link Managed 2>/dev/null | awk '{print $2}')"
ETH_STATE="—"
[[ -n "${ETH:-}" ]] && ETH_STATE="$(nmcli -t -f DEVICE,STATE device | awk -F: -v e="$ETH" '$1==e{print $2; exit}')"

echo
info "On-air check:"
echo "  FriendlyName=$FN"
echo "  Managed=$MAN  P2PScanning=$SCAN  Wfd=$WFD"
echo "  Ethernet ${ETH:-none}: $ETH_STATE"
tail -50 "$LOG" || true

if [[ "$MAN" != "true" || "$SCAN" != "true" || -z "$FN" ]]; then
  die "radio is not ready"
fi

JOIN_HELPER="${SCRIPT_DIR}/dex-p2p-join-on-invite.sh"
if [[ -x "$JOIN_HELPER" ]]; then
  sudo "$JOIN_HELPER" start || warn "join-on-invite did not start"
  info "Samsung P2P-INVITATION → p2p_connect pbc join"
fi

info "On the phone: cancel a stuck attempt, then DeX → TV → «${FN}» → Start"
info "The video window appears after CONNECT, not during “Connecting…”"
echo "Stop: dex-tv-like-stop"
trap 'sudo "'"$JOIN_HELPER"'" stop 2>/dev/null || true; sudo pkill -x miracle-sinkctl 2>/dev/null || true; sudo pkill -x miracle-wifid 2>/dev/null || true; sudo nmcli device set '"$WIFI"' managed yes 2>/dev/null || true; exit 0' INT TERM
trap - EXIT
wait "$SINK_WRAP_PID" || true
