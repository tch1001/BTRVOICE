"""Synthetic keyboard injection on X11, and the focus bookkeeping it needs.

The macOS app types with `CGEvent`, whose unicode payload is indistinguishable
from a real keypress. The X11 equivalent is XTEST, which `xdotool` drives — the
target application receives ordinary key events and cannot tell the difference,
so no cooperation from it is required.

The bookkeeping half matters as much as the typing half. Our own panel must
never become the target, or a commit types the text back into the buffer it
came from. `TargetTracker` therefore remembers the last window that was focused
and *wasn't* ours; `TextInjector` restores focus to it before typing.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
import time

# xdotool types fast enough to outrun some toolkits' input queues (Electron and
# XTerm are the usual offenders), which silently drops characters. 12ms per key
# is slow enough to be reliable and still ~80 chars/sec.
KEY_DELAY_MS = 12

# Long strings go in chunks so a stall can't wedge the whole commit, and so the
# user sees progress land rather than one giant pause.
CHUNK_CHARS = 200


class XdotoolMissing(RuntimeError):
    pass


def _display_env() -> dict:
    """xdotool needs a DISPLAY. Over SSH there isn't one, so fall back to :0 —
    the local seat is the only place injection is meaningful anyway."""
    env = dict(os.environ)
    if not env.get("DISPLAY"):
        env["DISPLAY"] = ":0"
    return env


def _run(args: list[str], timeout: float = 5.0) -> str:
    if not shutil.which("xdotool"):
        raise XdotoolMissing("xdotool is not installed (apt install xdotool)")
    out = subprocess.run(
        args, capture_output=True, text=True, timeout=timeout, env=_display_env()
    )
    if out.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout.strip()


class TargetTracker:
    """Polls the focused window, ignoring our own, so we always know where a
    commit should go.

    Polling rather than subscribing to X events is deliberate: the alternative
    needs a second X connection and an event loop thread, and the failure mode
    of a missed poll (typing into the window the user left a moment ago) is far
    better than the failure mode of a wedged event loop (typing nowhere).
    """

    def __init__(self, own_window_names: tuple[str, ...] = ("BtrVoice",), interval: float = 0.25):
        self._own = own_window_names
        self._interval = interval
        self._lock = threading.Lock()
        self._target: str | None = None
        self._target_name: str = ""
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._loop, daemon=True, name="target-tracker")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.wait(self._interval):
            try:
                wid = _run(["xdotool", "getactivewindow"])
                name = _run(["xdotool", "getwindowname", wid])
            except Exception:
                continue  # window vanished mid-poll, or no active window
            if any(own in name for own in self._own):
                continue  # that's us — keep the previous target
            with self._lock:
                self._target, self._target_name = wid, name

    @property
    def target(self) -> str | None:
        with self._lock:
            return self._target

    @property
    def target_name(self) -> str:
        with self._lock:
            return self._target_name


class TextInjector:
    """Replays committed text as real key events into the tracked window."""

    def __init__(self, tracker: TargetTracker):
        self._tracker = tracker

    def available(self) -> bool:
        return shutil.which("xdotool") is not None

    def focus_target(self) -> bool:
        """Bring the target forward and wait for X to agree it's focused.

        `--sync` blocks until the window is actually active. Without it the
        first characters race the focus change and land in the old window.
        """
        wid = self._tracker.target
        if not wid:
            return False
        try:
            _run(["xdotool", "windowactivate", "--sync", wid], timeout=3.0)
            time.sleep(0.04)  # settle: some WMs report focus a frame early
            return True
        except Exception:
            return False

    def type_text(self, text: str) -> bool:
        """Type `text` into the target. Returns False if there was nowhere to
        type or xdotool refused; the caller keeps the buffer in that case so
        the user never loses words to a failed commit."""
        if not text:
            return True
        if not self.focus_target():
            return False
        try:
            for i in range(0, len(text), CHUNK_CHARS):
                chunk = text[i : i + CHUNK_CHARS]
                _run(
                    [
                        "xdotool",
                        "type",
                        "--clearmodifiers",
                        "--delay",
                        str(KEY_DELAY_MS),
                        "--",
                        chunk,
                    ],
                    timeout=max(10.0, len(chunk) * KEY_DELAY_MS / 1000 * 3),
                )
            return True
        except Exception:
            return False

    def press_combo(self, combo: str) -> bool:
        """Press a key combo such as 'ctrl+s' or 'Return' in the target window.

        This is what the app-command layer uses; it refocuses first for the same
        reason typing does.
        """
        if not self.focus_target():
            return False
        try:
            _run(["xdotool", "key", "--clearmodifiers", combo])
            return True
        except Exception:
            return False
