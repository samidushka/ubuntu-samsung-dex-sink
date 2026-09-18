#!/usr/bin/env python3
"""Gtk-окно Miracast (RTP 7236) + мышь/клава в Samsung DeX через ADB.

Картинка остаётся GStreamer, не scrcpy. sinkctl --uibc может передать
host/port в env DEX_UIBC_*; если телефон порт не открыл — только ADB.
"""
from __future__ import annotations

import os
import queue
import re
import subprocess
import sys
import threading
import time

os.environ.setdefault("GDK_BACKEND", "x11")
os.environ["GDK_SCALE"] = "1"
os.environ["GDK_DPI_SCALE"] = "1"

import gi

gi.require_version("Gst", "1.0")
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import Gdk, Gst, GstVideo, Gtk  # noqa: E402

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
    Gdk.KEY_Alt_L: "KEYCODE_BACK",
    Gdk.KEY_Alt_R: "KEYCODE_BACK",
    Gdk.KEY_Super_L: "KEYCODE_HOME",
    Gdk.KEY_Super_R: "KEYCODE_HOME",
}


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", flush=True)


def run(cmd, timeout=8) -> str:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (p.stdout or "") + (p.stderr or "")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        return str(exc)


def find_dex_display(serial: str) -> int:
    forced = os.environ.get("DEX_DISPLAY_ID", "").strip()
    if forced.isdigit():
        return int(forced)
    if not serial:
        return 0
    out = run(["adb", "-s", serial, "shell", "dumpsys", "display"], timeout=12)
    m = re.search(r'DisplayInfo\{"[^"]*DeX[^"]*",\s*displayId\s+(\d+)', out)
    if m:
        return int(m.group(1))
    m = re.search(r"displayId\s+(\d+)[^\n]*wifi:desktop:", out)
    if m:
        return int(m.group(1))
    return 19


class Injector:
    def __init__(self, serial: str, display: int):
        self.serial = serial
        self.display = display
        self.q: queue.Queue[str] = queue.Queue()
        self.proc = None
        self.uibc = None
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
                log(f"UIBC {UIBC_HOST}:{UIBC_PORT}")
            except OSError as exc:
                log(f"UIBC fail {exc}")
                self.uibc = None
        self._open()
        threading.Thread(target=self._worker, daemon=True).start()

    def _open(self) -> None:
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
            log(f"adb fail {exc}")
            self.proc = None

    def send(self, line: str) -> None:
        self.q.put(line)

    def tap(self, x, y) -> None:
        log(f"tap {x},{y} d={self.display}")
        self.send(f"input -d {self.display} tap {x} {y}")

    def swipe(self, x1, y1, x2, y2, ms=180) -> None:
        self.send(f"input -d {self.display} swipe {x1} {y1} {x2} {y2} {ms}")

    def motion(self, kind, x, y) -> None:
        self.send(f"input -d {self.display} motionevent {kind} {x} {y}")

    def key(self, code: str) -> None:
        log(f"key {code} d={self.display}")
        self.send(f"input -d {self.display} keyevent {code}")

    def text(self, s: str) -> None:
        esc = s.replace(" ", "%s").replace("'", "\\'")
        self.send(f"input -d {self.display} text {esc}")

    def uibc_line(self, line: str) -> None:
        if self.uibc and self.uibc.stdin:
            try:
                self.uibc.stdin.write(line + "\n")
                self.uibc.stdin.flush()
            except OSError:
                self.uibc = None

    def _worker(self) -> None:
        while self.alive:
            try:
                line = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            if self.proc is None or self.proc.poll() is not None:
                self._open()
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


class DexPlayer:
    def __init__(self, port: int, audio: bool, width: int, height: int):
        self.width = width
        self.height = height
        self.inj = Injector(SERIAL, find_dex_display(SERIAL) if SERIAL else 0)
        self.down = None
        self.last_move = 0.0
        self.xid = None

        self.win = Gtk.Window(title="DeX (Miracast)")
        self.win.set_default_size(width, height)
        self.win.connect("destroy", self.quit)
        self.win.connect("key-press-event", self.on_key)
        self.win.set_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
            | Gdk.EventMask.KEY_PRESS_MASK
        )
        self.win.connect("button-press-event", self.on_press)
        self.win.connect("button-release-event", self.on_release)
        self.win.connect("motion-notify-event", self.on_motion)
        self.win.connect("scroll-event", self.on_scroll)

        pipe = (
            f"udpsrc port={port} caps=application/x-rtp,media=video,"
            f"clock-rate=90000,encoding-name=MP2T,payload=33 ! "
            f"rtpjitterbuffer latency=80 ! rtpmp2tdepay ! "
            f"tsdemux ignore-pcr=true name=demuxer "
            f"demuxer.video_0_1011 ! queue max-size-buffers=0 max-size-time=0 ! "
            f"h264parse ! avdec_h264 ! videoconvert ! "
            f"gtksink name=dexsink sync=false"
        )
        if audio:
            pipe += (
                " demuxer.audio_0_1100 ! queue max-size-buffers=0 max-size-time=0 ! "
                "aacparse ! avdec_aac ! audioconvert ! audioresample ! autoaudiosink"
            )
        log(f"pipeline {pipe}")
        Gst.init(None)
        self.pipeline = Gst.parse_launch(pipe)
        sink = self.pipeline.get_by_name("dexsink")
        widget = sink.get_property("widget")
        widget.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
            | Gdk.EventMask.SCROLL_MASK
        )
        widget.connect("button-press-event", self.on_press)
        widget.connect("button-release-event", self.on_release)
        widget.connect("motion-notify-event", self.on_motion)
        widget.connect("scroll-event", self.on_scroll)
        self.win.add(widget)
        self.da = widget
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", self.on_error)

    def xy(self, event):
        alloc = self.da.get_allocation()
        w, h = max(alloc.width, 1), max(alloc.height, 1)
        x = int(max(0, min(event.x, w - 1)) * self.width / w)
        y = int(max(0, min(event.y, h - 1)) * self.height / h)
        return x, y

    def on_press(self, _w, event):
        x, y = self.xy(event)
        if event.button == 3:
            self.inj.key("KEYCODE_BACK")
            return True
        if event.button == 2:
            self.inj.key("KEYCODE_HOME")
            return True
        self.down = (x, y, time.time())
        self.inj.uibc_line(f"0,1,0,{x},{y}")
        self.inj.motion("DOWN", x, y)
        return True

    def on_release(self, _w, event):
        if event.button != 1 or not self.down:
            return True
        x, y = self.xy(event)
        x0, y0, t0 = self.down
        self.down = None
        self.inj.uibc_line(f"1,1,0,{x},{y}")
        dist = ((x - x0) ** 2 + (y - y0) ** 2) ** 0.5
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
        self.inj.uibc_line(f"2,1,0,{x},{y}")
        self.inj.motion("MOVE", x, y)
        return True

    def on_scroll(self, _w, event):
        x, y = self.xy(event)
        dy = 120 if event.direction == Gdk.ScrollDirection.DOWN else -120
        self.inj.swipe(x, y, x, max(0, min(self.height - 1, y + dy)), 80)
        return True

    def on_key(self, _w, event):
        if event.keyval in KEYMAP:
            code = KEYMAP[event.keyval]
            if code:
                self.inj.key(code)
                self.inj.uibc_line("3,0x%04X,0x0000" % event.keyval)
            return True
        ch = chr(Gdk.keyval_to_unicode(event.keyval)) if Gdk.keyval_to_unicode(event.keyval) else ""
        if ch and ch.isprintable():
            self.inj.text(ch)
            self.inj.uibc_line("3,0x%04X,0x0000" % event.keyval)
            return True
        return False

    def on_sync(self, _bus, msg):
        if msg.get_structure() and msg.get_structure().get_name() == "prepare-window-handle":
            if self.xid:
                msg.src.set_window_handle(self.xid)

    def on_error(self, _bus, msg):
        log(f"gst error {msg.parse_error()}")

    def place(self) -> None:
        try:
            self.win.move(40, 40)
        except Exception:
            pass

    def run(self) -> None:
        self.win.show_all()
        self.pipeline.set_state(Gst.State.PLAYING)
        self.place()
        log(f"gtksink playing display={self.inj.display}")
        Gtk.main()

    def quit(self, *_a) -> None:
        self.pipeline.set_state(Gst.State.NULL)
        self.inj.close()
        Gtk.main_quit()


def parse_args(argv):
    port, audio, w, h = 7236, False, 1920, 1080
    host = port_u = ""
    args = list(argv)
    if args and re.match(r"^[0-9A-Fa-f.:]+$", args[0]) and len(args) > 1 and args[1].isdigit():
        host, port_u = args[0], args[1]
        args = args[2:]
        os.environ["DEX_UIBC_HOST"] = host
        os.environ["DEX_UIBC_PORT"] = port_u
        global UIBC_HOST, UIBC_PORT
        UIBC_HOST, UIBC_PORT = host, port_u
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-p" and i + 1 < len(args):
            port = int(args[i + 1])
            i += 2
        elif a == "-a":
            audio = True
            i += 1
        elif a in ("-r", "-s") and i + 1 < len(args):
            m = re.match(r"(\d+)x(\d+)", args[i + 1])
            if m:
                w, h = int(m.group(1)), int(m.group(2))
            i += 2
        elif a == "-d":
            i += 2
        else:
            i += 1
    return port, audio, w, h


def main() -> int:
    port, audio, w, h = parse_args(sys.argv[1:])
    log(f"player port={port} {w}x{h} audio={audio} adb={SERIAL or 'none'}")
    DexPlayer(port, audio, w, h).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
