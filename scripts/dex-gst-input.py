#!/usr/bin/env python3
"""Мышь/клавиатура окна gst-launch → Samsung DeX (display wifi:desktop).

Видео остаётся miraclecast/gst. UIBC, если sinkctl отдал порт; иначе ADB
`input -d <DeX display>`. Оверлей почти прозрачный поверх xvimagesink.
"""
from __future__ import annotations

import os
import queue
import re
import subprocess
import threading
import time

# mutter/XWayland: Gtk иначе рисует оверлей 2× (3840×2160) поверх gst 1920×1080.
os.environ.setdefault("GDK_BACKEND", "x11")
os.environ["GDK_SCALE"] = "1"
os.environ["GDK_DPI_SCALE"] = "1"

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

def first_adb_serial() -> str:
    env = os.environ.get("DEX_ADB_SERIAL", "").strip()
    if env:
        return env
    try:
        p = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=5)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return ""
    for line in (p.stdout or "").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            return parts[0]
    return ""


SERIAL = first_adb_serial()
UIBC_HOST = os.environ.get("DEX_UIBC_HOST", "").strip()
UIBC_PORT = os.environ.get("DEX_UIBC_PORT", "").strip()
SCROLL_INVERT = os.environ.get("DEX_SCROLL_INVERT", "1").strip().lower() not in (
    "0",
    "false",
    "no",
    "off",
)
SCROLL_PX = max(24, min(240, int(os.environ.get("DEX_SCROLL_PX", "110"))))
POINTER_EVENTS = (
    Gdk.EventMask.BUTTON_PRESS_MASK
    | Gdk.EventMask.BUTTON_RELEASE_MASK
    | Gdk.EventMask.POINTER_MOTION_MASK
    | Gdk.EventMask.SCROLL_MASK
    | Gdk.EventMask.SMOOTH_SCROLL_MASK
)
LOG = os.environ.get(
    "DEX_INPUT_LOG",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "dex-tv-like", "gst-input.log"),
)

KEYMAP = {
    Gdk.KEY_Return: "KEYCODE_ENTER",
    Gdk.KEY_KP_Enter: "KEYCODE_ENTER",
    Gdk.KEY_BackSpace: "KEYCODE_DEL",
    Gdk.KEY_Delete: "KEYCODE_FORWARD_DEL",
    Gdk.KEY_Escape: "KEYCODE_BACK",
    Gdk.KEY_Tab: "KEYCODE_TAB",
    Gdk.KEY_Left: "KEYCODE_DPAD_LEFT",
    Gdk.KEY_Right: "KEYCODE_DPAD_RIGHT",
    Gdk.KEY_Up: "KEYCODE_DPAD_UP",
    Gdk.KEY_Down: "KEYCODE_DPAD_DOWN",
    Gdk.KEY_Home: "KEYCODE_HOME",
    Gdk.KEY_End: "KEYCODE_MOVE_END",
    Gdk.KEY_Page_Up: "KEYCODE_PAGE_UP",
    Gdk.KEY_Page_Down: "KEYCODE_PAGE_DOWN",
    Gdk.KEY_F1: "KEYCODE_MENU",
    Gdk.KEY_Super_L: "KEYCODE_HOME",
    Gdk.KEY_Super_R: "KEYCODE_HOME",
    Gdk.KEY_Control_L: None,
    Gdk.KEY_Control_R: None,
    Gdk.KEY_Shift_L: None,
    Gdk.KEY_Shift_R: None,
    Gdk.KEY_Alt_L: "KEYCODE_BACK",
    Gdk.KEY_Alt_R: "KEYCODE_BACK",
}


def log(msg: str) -> None:
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}"
    print(line, flush=True)


def run(cmd, timeout=8) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (p.stdout or "") + (p.stderr or "")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        return str(exc)


def find_gst_window():
    ids = run(["xdotool", "search", "--class", "GStreamer"]).split()
    if not ids:
        ids = run(["xdotool", "search", "--name", "gst-launch-1.0"]).split()
    best = None
    for wid in ids:
        if not wid.isdigit():
            continue
        geo = run(["xdotool", "getwindowgeometry", "--shell", wid])
        env = {}
        for line in geo.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                env[k] = v
        try:
            w, h = int(env.get("WIDTH", 0)), int(env.get("HEIGHT", 0))
            x, y = int(env.get("X", 0)), int(env.get("Y", 0))
        except ValueError:
            continue
        if w < 640 or h < 360:
            continue
        if w > 1920 or h > 1080:
            continue
        score = (w * h) + (100000 if (w, h) == (1920, 1080) else 0)
        if best is None or score > best[0]:
            best = (score, int(wid), x, y, w, h)
    if not best:
        return None
    return best[1:]


def find_dex_display(serial: str) -> int:
    forced = os.environ.get("DEX_DISPLAY_ID", "").strip()
    if forced.isdigit():
        return int(forced)
    if not serial:
        return 0
    out = run(["adb", "-s", serial, "shell", "dumpsys", "display"], timeout=12)
    m = re.search(
        r'DisplayInfo\{"[^"]*DeX[^"]*",\s*displayId\s+(\d+)',
        out,
    )
    if m:
        return int(m.group(1))
    m = re.search(r"displayId\s+(\d+)[^\n]*wifi:desktop:", out)
    if m:
        return int(m.group(1))
    m = re.search(r"FLAG_WIRELESS_DEX_DISPLAY[\s\S]{0,200}?displayId\s+(\d+)", out)
    if m:
        return int(m.group(1))
    listed = run(["scrcpy", "-s", serial, "--list-displays"], timeout=15)
    ids = re.findall(r"--display-id=(\d+)\s+\(1920x1080\)", listed)
    for i in ids:
        if i != "0":
            return int(i)
    return 19


class Injector:
    def __init__(self, serial: str, display: int):
        self.serial = serial
        self.display = display
        self.q: queue.Queue[str] = queue.Queue()
        self.uibc = None
        self.proc = None
        self.alive = True
        if UIBC_HOST and UIBC_PORT.isdigit():
            try:
                self.uibc = subprocess.Popen(
                    ["miracle-uibcctl", UIBC_HOST, UIBC_PORT],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
                log(f"UIBC connected {UIBC_HOST}:{UIBC_PORT}")
            except OSError as exc:
                log(f"UIBC fail: {exc}")
                self.uibc = None
        self._open_adb()
        threading.Thread(target=self._worker, daemon=True).start()

    def _open_adb(self) -> None:
        if not self.serial:
            self.proc = None
            return
        try:
            self.proc = subprocess.Popen(
                ["adb", "-s", self.serial, "shell"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            log(f"adb shell fail: {exc}")
            self.proc = None

    def send(self, line: str) -> None:
        self.q.put(line)

    def tap(self, x: int, y: int) -> None:
        log(f"tap {x},{y} d={self.display}")
        self.send(f"input -d {self.display} tap {x} {y}")

    def swipe(self, x1: int, y1: int, x2: int, y2: int, ms: int = 180) -> None:
        self.send(f"input -d {self.display} swipe {x1} {y1} {x2} {y2} {ms}")

    def motion(self, kind: str, x: int, y: int) -> None:
        self.send(f"input -d {self.display} motionevent {kind} {x} {y}")

    def key(self, code: str) -> None:
        log(f"key {code} d={self.display}")
        self.send(f"input -d {self.display} keyevent {code}")

    def text(self, s: str) -> None:
        esc = (
            s.replace("\\", "\\\\")
            .replace(" ", "%s")
            .replace("'", "\\'")
            .replace('"', '\\"')
            .replace("&", "\\&")
            .replace("<", "\\<")
            .replace(">", "\\>")
            .replace("|", "\\|")
            .replace(";", "\\;")
            .replace("(", "\\(")
            .replace(")", "\\)")
        )
        self.send(f"input -d {self.display} text {esc}")

    def uibc_touch(self, typ: str, x: int, y: int) -> None:
        if not self.uibc or not self.uibc.stdin:
            return
        try:
            self.uibc.stdin.write(f"{typ},1,0,{x},{y}\n")
            self.uibc.stdin.flush()
        except OSError:
            self.uibc = None

    def uibc_line(self, line: str) -> None:
        if not self.uibc or not self.uibc.stdin:
            return
        try:
            self.uibc.stdin.write(line + "\n")
            self.uibc.stdin.flush()
        except OSError:
            self.uibc = None

    def scroll(self, x: int, y: int, dx: float, dy: float, width: int = 1920, height: int = 1080) -> None:
        sign = -1 if SCROLL_INVERT else 1
        px = int(round(dx * SCROLL_PX * sign))
        py = int(round(dy * SCROLL_PX * sign))
        x2 = max(0, min(width - 1, x + px))
        y2 = max(0, min(height - 1, y + py))
        log(
            f"scroll dx={dx:.2f} dy={dy:.2f} {x},{y}->{x2},{y2} "
            f"uibc={1 if self.uibc else 0} d={self.display}"
        )

        def notches(v: float) -> int:
            return max(1, min(15, int(round(abs(v)))))

        if abs(dy) >= abs(dx) and abs(dy) >= 0.15:
            self.uibc_line(f"6,1,{0 if dy > 0 else 1},{notches(dy)}")
        elif abs(dx) >= 0.15:
            self.uibc_line(f"7,1,{0 if dx > 0 else 1},{notches(dx)}")
        if (x2, y2) != (x, y):
            self.uibc_touch("0", x, y)
            self.uibc_touch("2", (x + x2) // 2, (y + y2) // 2)
            self.uibc_touch("2", x2, y2)
            self.uibc_touch("1", x2, y2)
            if self.serial:
                self.swipe(x, y, x2, y2, 90)

    def _worker(self) -> None:
        while self.alive:
            try:
                line = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if self.proc is None or self.proc.poll() is not None:
                self._open_adb()
            if not self.proc or not self.proc.stdin:
                continue
            try:
                self.proc.stdin.write(line + "\n")
                self.proc.stdin.flush()
            except OSError:
                self.proc = None

    def close(self) -> None:
        self.alive = False
        for p in (self.proc, self.uibc):
            if p and p.poll() is None:
                try:
                    p.terminate()
                except OSError:
                    pass


class Overlay(Gtk.Window):
    def __init__(self, inj: Injector):
        super().__init__()
        self.inj = inj
        self.gst_id = None
        self.down = None
        self.last_move = 0.0
        self.scroll_acc = [0.0, 0.0]
        self.scroll_xy = (960, 540)
        self._scroll_flush_id = None
        self.set_title("DeX input")
        self.set_decorated(False)
        self.set_accept_focus(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_app_paintable(True)
        # Не нулевая альфа: иначе mutter отдаёт клики в gst, а не в слой ввода.
        self.set_opacity(0.08)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.add_events(POINTER_EVENTS | Gdk.EventMask.KEY_PRESS_MASK | Gdk.EventMask.FOCUS_CHANGE_MASK)
        self.connect("button-press-event", self.on_press)
        self.connect("button-release-event", self.on_release)
        self.connect("motion-notify-event", self.on_motion)
        self.connect("scroll-event", self.on_scroll)
        self.connect("key-press-event", self.on_key)
        self.connect("delete-event", Gtk.main_quit)
        GLib.timeout_add(400, self.sync_geom)
        self.sync_geom()

    def xy(self, event):
        alloc = self.get_allocation()
        w = max(alloc.width, 1)
        h = max(alloc.height, 1)
        x = int(max(0, min(event.x, w - 1)))
        y = int(max(0, min(event.y, h - 1)))
        dx = int(x * 1920 / w)
        dy = int(y * 1080 / h)
        return dx, dy

    def on_press(self, _w, event):
        x, y = self.xy(event)
        if event.button == 3:
            self.inj.key("KEYCODE_BACK")
            return True
        if event.button == 2:
            self.inj.key("KEYCODE_HOME")
            return True
        self.down = (x, y, time.time())
        self.inj.uibc_touch("0", x, y)
        self.inj.motion("DOWN", x, y)
        return True

    def on_release(self, _w, event):
        x, y = self.xy(event)
        if event.button != 1 or not self.down:
            return True
        x0, y0, t0 = self.down
        self.down = None
        dist = ((x - x0) ** 2 + (y - y0) ** 2) ** 0.5
        self.inj.uibc_touch("1", x, y)
        if dist < 12:
            self.inj.motion("UP", x, y)
            self.inj.tap(x, y)
        else:
            ms = max(80, min(800, int((time.time() - t0) * 1000)))
            self.inj.motion("UP", x, y)
            self.inj.swipe(x0, y0, x, y, ms)
        return True

    def on_motion(self, _w, event):
        if not self.down:
            return False
        now = time.time()
        if now - self.last_move < 0.04:
            return True
        self.last_move = now
        x, y = self.xy(event)
        self.inj.uibc_touch("2", x, y)
        self.inj.motion("MOVE", x, y)
        return True

    def _scroll_deltas(self, event):
        if event.direction == Gdk.ScrollDirection.SMOOTH:
            got = event.get_scroll_deltas()
            if isinstance(got, tuple) and len(got) == 3:
                _ok, dx, dy = got
                return float(dx or 0.0), float(dy or 0.0)
            if isinstance(got, tuple) and len(got) == 2:
                return float(got[0] or 0.0), float(got[1] or 0.0)
            return 0.0, 0.0
        if event.direction == Gdk.ScrollDirection.UP:
            return 0.0, -1.0
        if event.direction == Gdk.ScrollDirection.DOWN:
            return 0.0, 1.0
        if event.direction == Gdk.ScrollDirection.LEFT:
            return -1.0, 0.0
        if event.direction == Gdk.ScrollDirection.RIGHT:
            return 1.0, 0.0
        return 0.0, 0.0

    def _flush_scroll(self):
        self._scroll_flush_id = None
        ax, ay = self.scroll_acc
        if abs(ax) < 0.12 and abs(ay) < 0.12:
            return False
        self.scroll_acc = [0.0, 0.0]
        x, y = self.scroll_xy
        self.inj.scroll(x, y, ax, ay)
        return False

    def on_scroll(self, _w, event):
        x, y = self.xy(event)
        dx, dy = self._scroll_deltas(event)
        if dx == 0.0 and dy == 0.0:
            return True
        self.scroll_xy = (x, y)
        self.scroll_acc[0] += dx
        self.scroll_acc[1] += dy
        if abs(self.scroll_acc[0]) >= 0.7 or abs(self.scroll_acc[1]) >= 0.7:
            if self._scroll_flush_id is not None:
                GLib.source_remove(self._scroll_flush_id)
                self._scroll_flush_id = None
            self._flush_scroll()
        elif self._scroll_flush_id is None:
            self._scroll_flush_id = GLib.timeout_add(70, self._flush_scroll)
        return True

    def on_key(self, _w, event):
        key = event.keyval
        if key in KEYMAP:
            code = KEYMAP[key]
            if code:
                self.inj.key(code)
            return True
        ch = chr(Gdk.keyval_to_unicode(key)) if Gdk.keyval_to_unicode(key) else ""
        if ch and ch.isprintable():
            self.inj.text(ch)
            return True
        return False

    def sync_geom(self):
        found = find_gst_window()
        if not found:
            log("нет окна gst — жду")
            return True
        wid, x, y, w, h = found
        self.gst_id = wid
        w, h = min(w, 1920), min(h, 1080)
        self.resize(w, h)
        self.move(x, y)
        if not self.get_visible():
            self.show_all()
            log(f"overlay on gst id={wid} {w}x{h}+{x}+{y} display={self.inj.display}")
        return True


def main() -> int:
    os.environ.setdefault("GDK_BACKEND", "x11")
    display_id = find_dex_display(SERIAL)
    log(f"start adb={SERIAL or 'none'} display={display_id} uibc={UIBC_HOST}:{UIBC_PORT}")
    state = run(["adb", "-s", SERIAL, "get-state"]).strip()
    if "device" not in state:
        log(f"adb not device: {state}")
    inj = Injector(SERIAL, display_id)
    Overlay(inj)
    try:
        Gtk.main()
    finally:
        inj.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
