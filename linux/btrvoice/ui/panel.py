"""The floating dictation panel.

The single most important property here is that this window **never takes focus**.
If it does, `TargetTracker` loses the window the user was typing in and the commit
goes to the wrong place — or worse, back into the panel itself.

Qt gives us two flags that together achieve what a non-activating NSPanel does on
macOS:

  Qt.WindowDoesNotAcceptFocus  — the WM is told not to give us the input focus
  WA_ShowWithoutActivating     — showing the window doesn't raise/activate it

Because the panel can't be focused, it also can't receive key events, so every
control is driven from the tray, the global hotkey, or the mouse. That's a
constraint, not an oversight: a text box you could click into would be a text box
that steals focus.
"""

from __future__ import annotations

from collections.abc import Callable

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath
from PySide6.QtWidgets import (
    QApplication,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

PANEL_W, PANEL_H = 620, 260


class DictationPanel(QWidget):
    def __init__(
        self,
        on_commit: Callable[[], None],
        on_discard: Callable[[], None],
        on_toggle: Callable[[], None],
    ):
        super().__init__()
        self._on_commit = on_commit
        self._on_discard = on_discard
        self._on_toggle = on_toggle

        self.setWindowTitle("BtrVoice")
        self.setWindowFlags(
            Qt.Tool                      # no taskbar entry
            | Qt.FramelessWindowHint
            | Qt.WindowStaysOnTopHint
            | Qt.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WA_ShowWithoutActivating, True)
        self.setAttribute(Qt.WA_TranslucentBackground, True)
        self.resize(PANEL_W, PANEL_H)

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 14, 18, 14)
        root.setSpacing(10)

        header = QHBoxLayout()
        self._status = QLabel("idle")
        self._status.setStyleSheet("color:#8a8f98; font-size:12px;")
        self._target = QLabel("")
        self._target.setStyleSheet("color:#5c6068; font-size:12px;")
        self._target.setAlignment(Qt.AlignRight)
        header.addWidget(self._status)
        header.addStretch()
        header.addWidget(self._target)
        root.addLayout(header)

        self._text = QTextEdit()
        self._text.setReadOnly(True)  # see class docstring: focus is not ours to take
        self._text.setFrameStyle(0)
        self._text.setFont(QFont("Sans Serif", 13))
        self._text.setStyleSheet(
            "QTextEdit { background: transparent; color: #e8eaed; border: none; }"
        )
        root.addWidget(self._text, 1)

        buttons = QHBoxLayout()
        buttons.setSpacing(8)
        self._mic = self._button("Start  (F9)", self._on_toggle, primary=True)
        buttons.addWidget(self._mic)
        buttons.addStretch()
        buttons.addWidget(self._button("Discard", self._on_discard))
        buttons.addWidget(self._button("Commit  (F10)", self._on_commit, primary=True))
        root.addLayout(buttons)

        self._drag_from = None
        self.move_to_default()

    # ---------------------------------------------------------------- chrome

    def _button(self, label: str, slot, primary: bool = False) -> QPushButton:
        b = QPushButton(label)
        b.setCursor(Qt.PointingHandCursor)
        b.setFocusPolicy(Qt.NoFocus)  # clicking must not pull focus from the target
        accent = "#3b82f6" if primary else "#2a2d33"
        b.setStyleSheet(
            f"""QPushButton {{ background:{accent}; color:#f5f6f7; border:none;
                   border-radius:7px; padding:7px 15px; font-size:13px; }}
                QPushButton:hover {{ background:{'#4c8ef7' if primary else '#343841'}; }}"""
        )
        b.clicked.connect(slot)
        return b

    def paintEvent(self, event) -> None:  # rounded translucent backdrop
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        path = QPainterPath()
        path.addRoundedRect(self.rect().adjusted(0, 0, -1, -1), 14, 14)
        painter.fillPath(path, QColor(24, 26, 30, 242))
        painter.strokePath(path, QColor(60, 64, 72))

    def move_to_default(self) -> None:
        screen = QApplication.primaryScreen()
        if not screen:
            return
        area = screen.availableGeometry()
        self.move(
            area.x() + (area.width() - PANEL_W) // 2,
            area.y() + area.height() - PANEL_H - 70,
        )

    # Dragging by the body, since there's no title bar.
    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.LeftButton:
            self._drag_from = event.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, event) -> None:
        if self._drag_from and event.buttons() & Qt.LeftButton:
            self.move(event.globalPosition().toPoint() - self._drag_from)

    def mouseReleaseEvent(self, event) -> None:
        self._drag_from = None

    # ---------------------------------------------------------------- state

    def set_text(self, confirmed: str, partial: str) -> None:
        """Confirmed text solid, partial greyed — the user can see at a glance
        which words are theirs to commit."""
        confirmed_html = confirmed.replace("\n", "<br>")
        html = f'<span style="color:#e8eaed">{confirmed_html}</span>'
        if partial:
            html += f' <span style="color:#787d87">{partial}</span>'
        self._text.setHtml(html)
        cursor = self._text.textCursor()
        cursor.movePosition(cursor.MoveOperation.End)
        self._text.setTextCursor(cursor)

    def set_status(self, text: str, listening: bool = False) -> None:
        colour = "#34d399" if listening else "#8a8f98"
        self._status.setStyleSheet(f"color:{colour}; font-size:12px;")
        self._status.setText(text)
        self._mic.setText("Stop  (F9)" if listening else "Start  (F9)")

    def set_target(self, name: str) -> None:
        self._target.setText(f"→ {name[:48]}" if name else "no target")

    def flash(self, message: str) -> None:
        previous = self._status.text()
        self._status.setText(message)
        QTimer.singleShot(1600, lambda: self._status.setText(previous))
