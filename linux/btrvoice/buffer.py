"""The review buffer — the thing that makes BtrVoice BtrVoice.

Dictation lands here, not in the target app. The user reads it, fixes it or
throws it away, and only an explicit commit sends it onward as keystrokes.

Two kinds of text live here and the distinction is load-bearing:

  *confirmed* — settled segments from the engine. Only this is ever committed.
  *partial*   — the current best guess at what's still being said. Shown greyed
                out, replaced wholesale by the next partial, and never typed
                into another app.

Committing while a partial is outstanding would type words the user hasn't seen
settle, so `take_confirmed` deliberately leaves the partial behind.
"""

from __future__ import annotations

import re
import threading


class TextBuffer:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._confirmed = ""
        self._partial = ""

    # ---------------------------------------------------------------- reading

    @property
    def confirmed(self) -> str:
        with self._lock:
            return self._confirmed

    @property
    def partial(self) -> str:
        with self._lock:
            return self._partial

    @property
    def display_text(self) -> str:
        """What the panel shows: confirmed text plus the pending guess."""
        with self._lock:
            if not self._partial:
                return self._confirmed
            if not self._confirmed:
                return self._partial
            return f"{self._confirmed} {self._partial}"

    @property
    def is_empty(self) -> bool:
        with self._lock:
            return not self._confirmed and not self._partial

    # ---------------------------------------------------------------- writing

    def append_final(self, text: str) -> None:
        """Append a settled segment, joining with a single space."""
        text = text.strip()
        if not text:
            return
        with self._lock:
            self._partial = ""
            if not self._confirmed:
                self._confirmed = text
            elif self._confirmed.endswith(("\n", " ")):
                self._confirmed += text
            else:
                self._confirmed += " " + text

    def set_partial(self, text: str) -> None:
        with self._lock:
            self._partial = text.strip()

    def clear_partial(self) -> None:
        with self._lock:
            self._partial = ""

    def clear(self) -> None:
        with self._lock:
            self._confirmed = ""
            self._partial = ""

    def set_confirmed(self, text: str) -> None:
        """Wholesale replacement — used when the user edits the panel by hand,
        and by the GPT editor when it rewrites the buffer."""
        with self._lock:
            self._confirmed = text

    # ---------------------------------------------------------------- editing

    def backspace_word(self) -> None:
        with self._lock:
            self._confirmed = re.sub(r"\s*\S+\s*$", "", self._confirmed)

    def backspace_char(self) -> None:
        with self._lock:
            self._confirmed = self._confirmed[:-1]

    def newline(self) -> None:
        with self._lock:
            self._confirmed = self._confirmed.rstrip() + "\n"

    # ---------------------------------------------------------------- commit

    def take_confirmed(self) -> str:
        """Hand the confirmed text to the caller and clear it.

        The partial survives on purpose: it hasn't settled, so it isn't the
        user's yet. If the caller fails to type the text it should hand it back
        with `restore` rather than dropping it on the floor.
        """
        with self._lock:
            text = self._confirmed
            self._confirmed = ""
            return text

    def restore(self, text: str) -> None:
        """Put text back after a failed commit, ahead of anything since added."""
        if not text:
            return
        with self._lock:
            self._confirmed = text if not self._confirmed else f"{text} {self._confirmed}"
