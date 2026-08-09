"""The engine contract, mirroring Sources/BtrVoice/Speech/TranscriptionEngine.swift.

Keeping the callback names identical across the two ports is intentional: it
means a behaviour described in one codebase ("we emit a partial per delta, and a
final per VAD segment") reads the same in the other.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Protocol


class TranscriptionEngine(Protocol):
    """Fed 16 kHz mono PCM16 frames; emits partials and finals.

    A *partial* is a best-guess for the utterance currently being spoken and
    replaces whatever partial came before it. A *final* is a settled segment and
    is appended to the buffer. Only finals are ever committed to another app.
    """

    display_name: str
    is_on_device: bool

    on_partial: Callable[[str], None] | None
    on_segment_final: Callable[[str], None] | None
    on_error: Callable[[str], None] | None
    on_status: Callable[[str], None] | None

    def start(self) -> None: ...
    def append(self, frame: bytes) -> None: ...
    def finish(self) -> None:
        """Flush any audio still buffered and emit a last final if warranted."""
        ...

    def discard_utterance(self) -> None:
        """Throw away the in-flight utterance; its results must not surface."""
        ...

    def cancel(self) -> None: ...
