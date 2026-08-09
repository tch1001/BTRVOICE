"""Microphone capture via PulseAudio's `parec`.

Deliberately a subprocess rather than a Python audio binding: `sounddevice` and
friends need libportaudio2 installed system-wide, and this machine can't get
system packages without a sudo prompt. `parec` ships with pulseaudio-utils,
which is already present anywhere `pactl` works, and it hands us exactly the
format we want on stdout with no conversion layer in between.

Whisper wants 16 kHz mono, so we ask parec for that directly and skip the
resampling the macOS path has to do (AVAudioConverter 48k float -> 24k PCM16).
"""

from __future__ import annotations

import shutil
import subprocess
import threading
from collections.abc import Callable

SAMPLE_RATE = 16_000
CHANNELS = 1
SAMPLE_WIDTH = 2  # s16le

# 20ms per frame, matching webrtcvad's frame size exactly. The VAD layer can
# re-slice arbitrary sizes, but picking one that divides evenly means capture
# frames map 1:1 onto VAD frames with no residual buffer and no added latency.
FRAME_MS = 20
FRAME_BYTES = int(SAMPLE_RATE * FRAME_MS / 1000) * SAMPLE_WIDTH * CHANNELS


def list_sources() -> list[tuple[str, str]]:
    """(name, description) for each PulseAudio source, monitors last.

    Monitors are loopbacks of *output* — capturing one records what the machine
    is playing, not what the user said. They're still listed because they're
    genuinely useful for transcribing a meeting the machine is playing, but a
    real mic should always win the default.
    """
    if not shutil.which("pactl"):
        return []
    out = subprocess.run(
        ["pactl", "list", "short", "sources"], capture_output=True, text=True
    )
    sources = []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            sources.append((parts[1], parts[1]))
    sources.sort(key=lambda s: s[0].endswith(".monitor"))
    return sources


def default_source() -> str | None:
    """Prefer a real input; fall back to a monitor only if nothing else exists."""
    sources = list_sources()
    for name, _ in sources:
        if not name.endswith(".monitor"):
            return name
    return sources[0][0] if sources else None


def has_real_input() -> bool:
    """True when a genuine capture device exists.

    Worth asking separately from `default_source`, because a machine with only a
    monitor source will happily "record" — it just transcribes whatever is
    playing instead of whatever was said, which looks like a broken microphone
    rather than a missing one.
    """
    return any(not name.endswith(".monitor") for name, _ in list_sources())


class MicCapture:
    """Streams s16le/16k/mono frames to `on_frame` until stopped."""

    def __init__(self, source: str | None = None):
        self.source = source
        self._proc: subprocess.Popen | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    @staticmethod
    def available() -> bool:
        return shutil.which("parec") is not None

    def start(self, on_frame: Callable[[bytes], None], on_error: Callable[[str], None]) -> None:
        if self._proc:
            return
        source = self.source or default_source()
        args = [
            "parec",
            "--format=s16le",
            f"--rate={SAMPLE_RATE}",
            f"--channels={CHANNELS}",
            "--latency-msec=30",
        ]
        if source:
            args.append(f"--device={source}")

        try:
            self._proc = subprocess.Popen(
                args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0
            )
        except FileNotFoundError:
            on_error("parec not found (install pulseaudio-utils)")
            return

        self._stop.clear()
        self._thread = threading.Thread(
            target=self._pump, args=(on_frame, on_error), daemon=True, name="mic-capture"
        )
        self._thread.start()

    def _pump(self, on_frame, on_error) -> None:
        assert self._proc and self._proc.stdout
        try:
            while not self._stop.is_set():
                data = self._proc.stdout.read(FRAME_BYTES)
                if not data:
                    break
                on_frame(data)
        except Exception as exc:  # pragma: no cover - device teardown races
            if not self._stop.is_set():
                on_error(str(exc))
        finally:
            if not self._stop.is_set() and self._proc:
                err = b""
                if self._proc.stderr:
                    try:
                        err = self._proc.stderr.read() or b""
                    except Exception:
                        pass
                if err:
                    on_error(err.decode("utf-8", "replace").strip())

    def stop(self) -> None:
        self._stop.set()
        if self._proc:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._proc.kill()
            self._proc = None
