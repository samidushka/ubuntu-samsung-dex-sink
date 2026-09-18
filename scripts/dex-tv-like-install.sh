#!/usr/bin/env bash
# Install miraclecast + this DeX-as-TV sink. Run on the laptop, in a local
# terminal (needs interactive sudo). Do not start as root.
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
info() { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
die() { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

[[ "${EUID:-}" -eq 0 ]] && die "Run as your user, not root: ./scripts/dex-tv-like-install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="${MIRACLECAST_SRC:-$HOME/src/miraclecast}"
PREFIX="${MIRACLECAST_PREFIX:-/usr/local}"
BINDIR="${DEX_BINDIR:-$HOME/.local/bin}"
APPDIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
PATCH="$ROOT_DIR/patches/miraclecast-samsung-invitation.patch"

command -v git >/dev/null || die "git is required"

NEED_BUILD_DEPS=0
command -v cmake >/dev/null || NEED_BUILD_DEPS=1
command -v make >/dev/null || NEED_BUILD_DEPS=1
command -v miracle-sinkctl >/dev/null 2>&1 || NEED_BUILD_DEPS=1

if [[ "$NEED_BUILD_DEPS" -eq 1 ]]; then
  warn "Installing build and runtime packages (sudo)…"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential cmake pkg-config git \
    libglib2.0-dev libudev-dev libsystemd-dev libreadline-dev \
    check libtool autoconf \
    gstreamer1.0-tools gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-libav \
    python3 python3-gi gir1.2-gtk-3.0 gir1.2-gstreamer-1.0 \
    gir1.2-gst-plugins-base-1.0 \
    wpasupplicant iw network-manager xdotool zenity
fi

if ! command -v miracle-sinkctl >/dev/null 2>&1; then
  warn "Cloning and building miraclecast → ${SRC_DIR}"
  mkdir -p "$(dirname "$SRC_DIR")"
  if [[ -d "$SRC_DIR/.git" ]]; then
    git -C "$SRC_DIR" pull --ff-only || true
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 https://github.com/albfan/miraclecast.git "$SRC_DIR"
  fi
  if [[ -f "$SRC_DIR/res/org.freedesktop.miracle.conf" ]]; then
    sudo cp "$SRC_DIR/res/org.freedesktop.miracle.conf" /etc/dbus-1/system.d/
  fi
  # Ubuntu 26.04 / CMake 4.x rejects cmake_minimum_required(VERSION 2.8)
  if grep -q 'cmake_minimum_required(VERSION 2\.' "$SRC_DIR/CMakeLists.txt" 2>/dev/null; then
    sed -i 's/cmake_minimum_required(VERSION 2\.[0-9])/cmake_minimum_required(VERSION 3.16)/' \
      "$SRC_DIR/CMakeLists.txt"
    warn "CMakeLists: minimum 3.16 (CMake 4 compatibility)"
  fi
  rm -rf "$SRC_DIR/build"
  cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$SRC_DIR/build" -j"$(nproc)"
  sudo cmake --install "$SRC_DIR/build"
  sudo ldconfig
fi

if [[ -f "$PATCH" && -f "$SRC_DIR/src/wifi/wifid-supplicant.c" ]]; then
  if ! grep -q 'supplicant_event_p2p_invitation_received' "$SRC_DIR/src/wifi/wifid-supplicant.c"; then
    warn "Applying Samsung P2P invitation / AP-STA bind patch"
    git -C "$SRC_DIR" apply --whitespace=nowarn "$PATCH" || patch -d "$SRC_DIR" -p1 <"$PATCH"
    if [[ ! -d "$SRC_DIR/build" ]]; then
      cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    fi
    cmake --build "$SRC_DIR/build" -j"$(nproc)"
    sudo cmake --install "$SRC_DIR/build"
  else
    info "Invitation patch already present in $SRC_DIR"
  fi
fi

command -v miracle-wifid >/dev/null || die "miracle-wifid missing after install"
command -v miracle-sinkctl >/dev/null || die "miracle-sinkctl missing after install"
info "miracle-wifid: $(command -v miracle-wifid)"
info "miracle-sinkctl: $(command -v miracle-sinkctl)"

if iw list 2>/dev/null | grep -q 'P2P-device'; then
  info "Wi‑Fi reports P2P-device (required for wireless DeX)"
else
  die "This Wi‑Fi card has no P2P-device — wireless DeX like a TV will not work"
fi

chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py 2>/dev/null || true
mkdir -p "$BINDIR"
link_bin() { ln -sfn "$SCRIPT_DIR/$1" "$BINDIR/$2"; }
link_bin dex-tv-like-install.sh dex-tv-like-install
link_bin dex-tv-like-start.sh dex-tv-like-start
link_bin dex-tv-like-stop.sh dex-tv-like-stop
link_bin dex-sink-run-now.sh dex-sink-run-now
link_bin dex-p2p-join-on-invite.sh dex-p2p-join-on-invite
link_bin miracle-gst-user.sh miracle-gst-user
link_bin dex-gst-player.py dex-gst-player
link_bin dex-gst-input.py dex-gst-input
link_bin dex-gst-input-start.sh dex-gst-input-start
link_bin dex-restart-player.sh dex-restart-player
link_bin dex-sink-gui-launch.sh dex-sink-gui-launch
link_bin dex-sink-gui-stop.sh dex-sink-gui-stop
link_bin dex-sudo-prompt.sh dex-sudo-prompt

mkdir -p "$APPDIR"
for desk in "$ROOT_DIR/applications/"*.desktop; do
  [[ -f "$desk" ]] || continue
  dest="$APPDIR/$(basename "$desk")"
  sed "s|@BINDIR@|$BINDIR|g" "$desk" >"$dest"
  chmod 644 "$dest"
done
update-desktop-database "$APPDIR" 2>/dev/null || true
info "Desktop launchers installed under $APPDIR"

cat <<EOF

${GREEN}Install complete.${NC}

Next, on this laptop:
  1) Leave Ethernet connected if you want internet during DeX.
     Wi‑Fi must be on (radio), but it does not need a hotspot.
  2) Start: ${YELLOW}DeX like TV (sink)${NC} from the app menu
     or: ${YELLOW}$BINDIR/dex-sink-run-now${NC}
  3) Phone: DeX / Smart View → “TV or monitor” → pick this laptop.

Default on-air name: ${YELLOW}\$(hostname)-DeX${NC}
Override with:  export DEX_FRIENDLY_NAME=MyLaptop-DeX

Put $BINDIR on PATH (often ~/.local/bin already is).

EOF
