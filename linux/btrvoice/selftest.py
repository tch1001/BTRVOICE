"""Pure-logic suite, mirroring Sources/BtrVoice/Support/SelfTest.swift.

Only logic that runs without a microphone, a GPU or an X server belongs here —
buffer arithmetic and frame math. Run it with `python -m btrvoice --self-test`.
"""

from __future__ import annotations

from .audio import FRAME_BYTES, SAMPLE_RATE
from .buffer import TextBuffer

_failures: list[str] = []


def _check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        _failures.append(name)


def _buffer_tests() -> None:
    b = TextBuffer()
    _check("starts empty", b.is_empty)

    b.append_final("hello")
    b.append_final("world")
    _check("finals join with one space", b.confirmed == "hello world", repr(b.confirmed))

    b.set_partial("and more")
    _check("display includes partial", b.display_text == "hello world and more", repr(b.display_text))

    taken = b.take_confirmed()
    _check("commit takes only confirmed", taken == "hello world", repr(taken))
    _check("commit leaves the partial", b.partial == "and more", repr(b.partial))

    b.restore(taken)
    _check("restore puts text back", b.confirmed == "hello world", repr(b.confirmed))

    b.backspace_word()
    _check("backspace drops a word", b.confirmed == "hello", repr(b.confirmed))
    b.backspace_char()
    _check("backspace drops a char", b.confirmed == "hell", repr(b.confirmed))

    b.newline()
    b.append_final("next")
    _check("newline is not double-spaced", b.confirmed == "hell\nnext", repr(b.confirmed))

    b.clear()
    _check("clear empties everything", b.is_empty)

    b2 = TextBuffer()
    b2.set_partial("only a guess")
    _check("partial alone is not committable", b2.take_confirmed() == "")


def _audio_tests() -> None:
    _check("16 kHz mono is what whisper wants", SAMPLE_RATE == 16_000)
    _check("frame is a whole number of samples", FRAME_BYTES % 2 == 0)
    # webrtcvad only accepts 10/20/30 ms frames, so the capture frame has to
    # divide evenly into 20 ms slices or the VAD layer would drift.
    vad_frame = int(SAMPLE_RATE * 20 / 1000) * 2
    _check("capture frame divides into VAD frames", FRAME_BYTES % vad_frame == 0,
           f"{FRAME_BYTES} % {vad_frame} = {FRAME_BYTES % vad_frame}")


def run() -> int:
    print("BtrVoice self-test")
    print(" buffer:")
    _buffer_tests()
    print(" audio:")
    _audio_tests()
    if _failures:
        print(f"\n{len(_failures)} failure(s): {', '.join(_failures)}")
        return 1
    print("\nall passed")
    return 0
