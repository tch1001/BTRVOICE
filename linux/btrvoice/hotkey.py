"""Global hotkeys via pynput's X11 backend.

These have to work while another application has focus — that's the whole point —
so they're a root-window grab rather than Qt shortcuts, which only fire when the
app is focused and ours deliberately never is.

pynput delivers callbacks on its own listener thread. Nothing here may touch a
widget; callers marshal onto the Qt thread themselves.
"""

from __future__ import annotations

from collections.abc import Callable


class HotkeyManager:
    def __init__(self) -> None:
        self._listener = None

    def start(self, bindings: dict[str, Callable[[], None]], on_error: Callable[[str], None]) -> bool:
        """`bindings` maps pynput hotkey strings ('<f9>') to callables."""
        try:
            from pynput import keyboard
        except Exception as exc:
            on_error(f"hotkeys unavailable: {exc}")
            return False
        try:
            self._listener = keyboard.GlobalHotKeys(bindings)
            self._listener.daemon = True
            self._listener.start()
            return True
        except Exception as exc:
            # A grab fails when something else already owns the combination.
            # Dictation still works from the panel and tray, so this is a
            # degradation rather than a failure to start.
            on_error(f"could not grab hotkeys: {exc}")
            return False

    def stop(self) -> None:
        if self._listener:
            self._listener.stop()
            self._listener = None
