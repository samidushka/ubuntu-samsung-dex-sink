# Shared helpers. Sourced by other scripts in this directory.
# shellcheck shell=bash

dex_wifi_iface() {
  nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}'
}

dex_eth_iface() {
  nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null \
    | awk -F: '$2=="ethernet" && $3=="connected"{print $1; exit}'
}

dex_session_user() {
  if [[ "$(id -u)" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      printf '%s\n' "$SUDO_USER"
      return
    fi
    logname 2>/dev/null && return
    printf 'root\n'
    return
  fi
  id -un
}

dex_session_uid() {
  id -u "$(dex_session_user)" 2>/dev/null || id -u
}

dex_session_home() {
  getent passwd "$(dex_session_user)" | cut -d: -f6
}

dex_session_runtime() {
  local uid
  uid="$(dex_session_uid)"
  printf '%s\n' "${XDG_RUNTIME_DIR:-/run/user/${uid}}"
}

dex_friendly_name() {
  local host
  host="$(hostname -s 2>/dev/null || true)"
  [[ -n "$host" ]] || host="Linux"
  printf '%s\n' "${DEX_FRIENDLY_NAME:-${host}-DeX}"
}

dex_prepare_display_env() {
  local uid user home runtime
  user="$(dex_session_user)"
  uid="$(dex_session_uid)"
  home="$(dex_session_home)"
  runtime="$(dex_session_runtime)"
  export XDG_RUNTIME_DIR="$runtime"
  export DISPLAY="${DISPLAY:-:0}"
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  export GDK_BACKEND="${GDK_BACKEND:-x11}"
  export GST_GL_WINDOW="${GST_GL_WINDOW:-x11}"
  if [[ -z "${XAUTHORITY:-}" ]]; then
    local auth
    auth="$(ls -1t "$runtime"/.mutter-Xwaylandauth* 2>/dev/null | head -1 || true)"
    if [[ -z "$auth" && -f "$home/.Xauthority" ]]; then
      auth="$home/.Xauthority"
    fi
    [[ -n "$auth" ]] && export XAUTHORITY="$auth"
  fi
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime/bus}"
  export HOME="$home"
  export USER="$user"
  export LOGNAME="$user"
}
