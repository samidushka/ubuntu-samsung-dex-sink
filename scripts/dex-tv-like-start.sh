#!/usr/bin/env bash
# Start Miracast sink (manual miracle-sinkctl). Prefer dex-sink-run-now.sh.
# NetworkManager stays up so Ethernet can keep internet. Wi‑Fi becomes unmanaged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_dex-common.sh
source "$SCRIPT_DIR/_dex-common.sh"

FRIENDLY="$(dex_friendly_name)"
STATE_DIR="$(dex_session_runtime)/dex-tv-like"
mkdir -p "$STATE_DIR"
PID_WIFID="$STATE_DIR/miracle-wifid.pid"
LOG="$STATE_DIR/miracle.log"
STATE_FILE="$STATE_DIR/session.env"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info() { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
die() { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

command -v miracle-wifid >/dev/null || die "No miracle-wifid — run ./dex-tv-like-install.sh first"
command -v miracle-sinkctl >/dev/null || die "No miracle-sinkctl — run ./dex-tv-like-install.sh first"
command -v iw >/dev/null || die "No iw"
command -v nmcli >/dev/null || die "No nmcli"

sudo systemctl start NetworkManager.service 2>/dev/null || true
systemctl is-active --quiet NetworkManager || die "NetworkManager is not active"

sudo rfkill unblock wifi || true
nmcli radio wifi on 2>/dev/null || sudo nmcli radio wifi on 2>/dev/null || true

WIFI_DEV="$(dex_wifi_iface)"
[[ -n "${WIFI_DEV:-}" ]] || die "No Wi‑Fi interface"
ETH_DEV="$(dex_eth_iface)"
WIFI_CONN="$(nmcli -t -f DEVICE,CONNECTION device status | awk -F: -v d="$WIFI_DEV" '$1==d{print $2; exit}')"
[[ "$WIFI_CONN" == "--" ]] && WIFI_CONN=""

if ! iw list 2>/dev/null | grep -q 'P2P-device'; then
  die "Wi‑Fi has no P2P — the phone will not see this laptop as a TV"
fi

if [[ -z "${ETH_DEV:-}" ]]; then
  warn "Ethernet is not connected — during DeX the laptop may lose internet (Wi‑Fi goes to P2P)."
else
  info "Ethernet stays up: $ETH_DEV"
fi

warn "Preparing Wi‑Fi «${WIFI_DEV}» for Miracast; DeX name: «${FRIENDLY}»…"

if [[ -f "$PID_WIFID" ]] && kill -0 "$(cat "$PID_WIFID")" 2>/dev/null; then
  sudo kill "$(cat "$PID_WIFID")" 2>/dev/null || true
fi
sudo pkill -x miracle-wifid 2>/dev/null || true
sudo pkill -x miracle-sinkctl 2>/dev/null || true

nmcli device disconnect "$WIFI_DEV" 2>/dev/null || true
nmcli device set "$WIFI_DEV" managed no 2>/dev/null || sudo nmcli device set "$WIFI_DEV" managed no
sleep 1

{
  echo "WIFI_DEV=${WIFI_DEV}"
  echo "WIFI_CONN=${WIFI_CONN}"
  echo "ETH_DEV=${ETH_DEV:-}"
  echo "STARTED_AT=$(date -Is)"
} >"$STATE_FILE"

: >"$LOG"
# Samsung Smart View wants to be GO (invite, go_intent≈13).
# High go-intent on the laptop makes us GO; DHCP/RTSP then fail.
sudo miracle-wifid --log-level info --lazy-managed --go-intent 0 -i "$WIFI_DEV" >>"$LOG" 2>&1 &
echo $! | sudo tee "$PID_WIFID" >/dev/null
sleep 2
if ! sudo kill -0 "$(cat "$PID_WIFID")" 2>/dev/null; then
  warn "Retry miracle-wifid without --lazy-managed…"
  sudo miracle-wifid --log-level info --go-intent 0 -i "$WIFI_DEV" >>"$LOG" 2>&1 &
  echo $! | sudo tee "$PID_WIFID" >/dev/null
  sleep 2
fi
sudo kill -0 "$(cat "$PID_WIFID")" 2>/dev/null || die "miracle-wifid did not start — see $LOG"

info "miracle-wifid on ${WIFI_DEV} (log: $LOG)"
info "Ethernet / NetworkManager were not stopped."
echo
echo "In miracle-sinkctl:"
echo "  ${YELLOW}set-managed <N> yes${NC}   # required with --lazy-managed, then:"
echo "  ${YELLOW}run <N>${NC}"
echo "  ${YELLOW}set-friendly-name ${FRIENDLY}${NC}"
echo "  ${YELLOW}list${NC}"
echo
echo "Phone: DeX → “TV / monitor” → «${FRIENDLY}»."
echo "Stop: Ctrl+C, then ${YELLOW}dex-tv-like-stop${NC} (returns Wi‑Fi to NetworkManager)."
echo

exec sudo miracle-sinkctl --uibc
