"""Wiring: microphone -> engine -> buffer -> panel, and buffer -> target app.

The controller equivalent of Dictation/DictationController.swift.

Threading, because it's the thing most likely to bite: mic frames arrive on the
parec pump thread, decode results on the whisper worker thread, and hotkeys on
pynput's listener thread. Qt widgets may only be touched from the main thread, so
every one of those paths ends at a signal on `Bridge` and the actual UI work
happens in a slot.
"""

from __future__ import annotations

import sys

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtGui import QAction, QIcon, QPainter, QPixmap
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from .audio import MicCapture, default_source, has_real_input
from .buffer import TextBuffer
from .hotkey import HotkeyManager
from .inject import TargetTracker, TextInjector
from .stt.local_whisper import LocalWhisperEngine


class Bridge(QObject):
    """Worker threads emit here; slots run on the Qt thread."""

    partial = Signal(str)
    final = Signal(str)
    status = Signal(str)
    error = Signal(str)
    toggle = Signal()
    commit = Signal()
    discard = Signal()
    toggle_panel = Signal()


class BtrVoiceApp:
    def __init__(self, model_size: str = "large-v3", language: str | None = "en"):
        self.qt = QApplication(sys.argv)
        self.qt.setApplicationName("BtrVoice")
        self.qt.setQuitOnLastWindowClosed(False)

        self.buffer = TextBuffer()
        self.bridge = Bridge()
        self.tracker = TargetTracker(own_window_names=("BtrVoice",))
        self.injector = TextInjector(self.tracker)
        self.mic = MicCapture()
        self.engine = LocalWhisperEngine(model_size=model_size, language=language)
        self.hotkeys = HotkeyManager()
        self.listening = False

        from .ui.panel import DictationPanel

        self.panel = DictationPanel(
            on_commit=self.bridge.commit.emit,
            on_discard=self.bridge.discard.emit,
            on_toggle=self.bridge.toggle.emit,
            on_hide=self.bridge.toggle_panel.emit,
        )

        self._wire()
        self._build_tray()

    # ---------------------------------------------------------------- wiring

    def _wire(self) -> None:
        self.engine.on_partial = self.bridge.partial.emit
        self.engine.on_segment_final = self.bridge.final.emit
        self.engine.on_status = self.bridge.status.emit
        self.engine.on_error = self.bridge.error.emit

        self.bridge.partial.connect(self._on_partial)
        self.bridge.final.connect(self._on_final)
        self.bridge.status.connect(lambda m: self.panel.set_status(m, self.listening))
        self.bridge.error.connect(self._on_error)
        self.bridge.toggle.connect(self.toggle)
        self.bridge.commit.connect(self.commit)
        self.bridge.discard.connect(self.discard)
        self.bridge.toggle_panel.connect(self.toggle_panel)

        # Partials are pulled rather than pushed: the engine only knows time has
        # passed when we tell it, and a timer keeps that off the audio path.
        self._partial_timer = QTimer()
        self._partial_timer.timeout.connect(self.engine.maybe_partial)
        self._partial_timer.start(200)

        self._target_timer = QTimer()
        self._target_timer.timeout.connect(
            lambda: self.panel.set_target(self.tracker.target_name)
        )
        self._target_timer.start(400)

    def _build_tray(self) -> None:
        pix = QPixmap(64, 64)
        pix.fill("#3b82f6")
        painter = QPainter(pix)
        painter.setPen("#ffffff")
        painter.drawText(pix.rect(), 0x0084, "BV")  # AlignCenter
        painter.end()

        self.tray = QSystemTrayIcon(QIcon(pix))
        menu = QMenu()
        self._tray_toggle = QAction("Start dictating  (F9)")
        self._tray_toggle.triggered.connect(self.bridge.toggle.emit)
        menu.addAction(self._tray_toggle)
        commit = QAction("Commit to focused app  (F10)")
        commit.triggered.connect(self.bridge.commit.emit)
        menu.addAction(commit)
        menu.addSeparator()
        self._tray_panel = QAction("Hide panel  (F7)")
        self._tray_panel.triggered.connect(self.bridge.toggle_panel.emit)
        menu.addAction(self._tray_panel)
        menu.addSeparator()
        quit_action = QAction("Quit")
        quit_action.triggered.connect(self.shutdown)
        menu.addAction(quit_action)
        self.tray.setContextMenu(menu)
        self.tray.setToolTip("BtrVoice")
        self.tray.show()

    # ---------------------------------------------------------------- actions

    def toggle(self) -> None:
        self.stop_listening() if self.listening else self.start_listening()

    def start_listening(self) -> None:
        if self.listening:
            return
        if not self.mic.available():
            self._on_error("parec not found (install pulseaudio-utils)")
            return
        if not default_source():
            self._on_error("no audio input device — plug in a microphone")
            return
        self.listening = True
        if not has_real_input():
            # Only a .monitor source exists, so we'd transcribe system output.
            # Say so rather than letting it look like a dead microphone.
            self.panel.set_status("no mic — capturing system audio", listening=True)
        else:
            self.panel.set_status("listening…", listening=True)
        self._tray_toggle.setText("Stop dictating  (F9)")
        self.mic.start(self.engine.append, self.bridge.error.emit)

    def stop_listening(self) -> None:
        if not self.listening:
            return
        self.listening = False
        self.mic.stop()
        self.engine.finish()
        self.panel.set_status("stopped", listening=False)
        self._tray_toggle.setText("Start dictating  (F9)")

    def commit(self) -> None:
        """Type the confirmed text into the tracked window.

        On failure the text goes back into the buffer — a commit that can't
        reach the target must never be a commit that loses the words.
        """
        text = self.buffer.take_confirmed()
        if not text.strip():
            self.panel.flash("nothing to commit")
            self.buffer.restore(text)
            return
        self._refresh()
        if self.injector.type_text(text):
            self.panel.flash(f"typed into {self.tracker.target_name[:28]}")
        else:
            self.buffer.restore(text)
            self.panel.flash("no target window — text kept")
        self._refresh()

    def toggle_panel(self) -> None:
        """Show/hide the panel without touching dictation.

        Hiding is safe because quitOnLastWindowClosed is off and the tray icon
        is the app's real home — dictation, hotkeys and the buffer all survive
        the panel going away.
        """
        if self.panel.isVisible():
            self.panel.hide()
            self._tray_panel.setText("Show panel  (F7)")
        else:
            self.panel.show()
            self._tray_panel.setText("Hide panel  (F7)")

    def discard(self) -> None:
        self.buffer.clear()
        self.engine.discard_utterance()
        self._refresh()
        self.panel.flash("discarded")

    # ---------------------------------------------------------------- slots

    def _on_partial(self, text: str) -> None:
        self.buffer.set_partial(text)
        self._refresh()

    def _on_final(self, text: str) -> None:
        self.buffer.append_final(text)
        self._refresh()

    def _on_error(self, message: str) -> None:
        self.panel.set_status(f"error: {message[:70]}", listening=self.listening)

    def _refresh(self) -> None:
        self.panel.set_text(self.buffer.confirmed, self.buffer.partial)

    # ---------------------------------------------------------------- lifecycle

    def run(self) -> int:
        self.tracker.start()
        self.engine.start()
        self.hotkeys.start(
            {
                "<f9>": self.bridge.toggle.emit,
                "<f10>": self.bridge.commit.emit,
                "<f8>": self.bridge.discard.emit,
                "<f7>": self.bridge.toggle_panel.emit,
            },
            on_error=self.bridge.error.emit,
        )
        self.panel.show()
        self.panel.set_status("ready — F9 to dictate, F10 to commit")
        return self.qt.exec()

    def shutdown(self) -> None:
        self.stop_listening()
        self.engine.cancel()
        self.tracker.stop()
        self.hotkeys.stop()
        self.qt.quit()
