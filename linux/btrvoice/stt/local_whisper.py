"""On-device streaming transcription: webrtcvad segments, faster-whisper decodes.

The macOS app gets segmentation for free — OpenAI's Realtime API runs server-side
VAD and pushes `.delta` / `.completed` events. Locally we have to do that
ourselves, so this module is the Linux stand-in for both halves:

  VAD          decides where an utterance ends        (-> a *final*)
  re-decode    periodically re-runs the open utterance (-> a *partial*)

Partials are produced by transcribing the utterance-so-far from the top rather
than by decoding incrementally. Whisper is a sequence model with no streaming
mode, so a from-scratch decode of 2 seconds of audio is both simpler and more
accurate than trying to splice partial decodes together — and on a 3090 it costs
a few tens of milliseconds, well under the repaint interval.
"""

from __future__ import annotations

import threading
import time

import numpy as np

from ..audio import SAMPLE_RATE

# webrtcvad accepts only 10, 20 or 30 ms frames at 8/16/32/48 kHz.
VAD_FRAME_MS = 20
VAD_FRAME_BYTES = int(SAMPLE_RATE * VAD_FRAME_MS / 1000) * 2

# How much trailing silence closes an utterance. Long enough to survive the
# pause mid-sentence that everyone makes while thinking, short enough that the
# commit doesn't feel laggy.
SILENCE_HANGOVER_MS = 700

# Ignore blips — a keyboard clack passes VAD but isn't speech.
MIN_UTTERANCE_MS = 300

# Re-decode the open utterance at most this often.
PARTIAL_INTERVAL_S = 0.55


class LocalWhisperEngine:
    """faster-whisper on CUDA, wrapped in the TranscriptionEngine contract."""

    def __init__(
        self,
        model_size: str = "large-v3",
        device: str = "cuda",
        compute_type: str = "float16",
        language: str | None = "en",
        vad_aggressiveness: int = 2,
    ):
        self.display_name = f"Whisper {model_size} (local)"
        self.is_on_device = True
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.language = language
        self._vad_aggressiveness = vad_aggressiveness

        self.on_partial = None
        self.on_segment_final = None
        self.on_error = None
        self.on_status = None

        self._model = None
        self._vad = None
        self._lock = threading.Lock()
        self._pending = bytearray()   # audio not yet sliced into VAD frames
        self._utterance = bytearray() # audio of the utterance in progress
        self._silence_ms = 0
        self._speaking = False
        self._suppress = False
        self._last_partial_at = 0.0
        self._cancelled = False
        self._work = threading.Semaphore(0)
        self._queue: list[tuple[bytes, bool]] = []
        self._thread: threading.Thread | None = None

    # ---------------------------------------------------------------- lifecycle

    def start(self) -> None:
        self._cancelled = False
        self._thread = threading.Thread(target=self._worker, daemon=True, name="whisper")
        self._thread.start()

    def _ensure_model(self) -> bool:
        """Load lazily so the UI can come up instantly and report progress."""
        if self._model is not None:
            return True
        try:
            import webrtcvad
            from faster_whisper import WhisperModel
        except ImportError as exc:
            self._emit_error(f"missing dependency: {exc}")
            return False

        self._status(f"loading {self.model_size} on {self.device}…")
        try:
            self._model = WhisperModel(
                self.model_size, device=self.device, compute_type=self.compute_type
            )
        except Exception as exc:
            # A CUDA/cuDNN problem is the likely cause and CPU still works, just
            # slower — degrade rather than leaving the user with nothing.
            self._status(f"CUDA unavailable ({exc}); falling back to CPU")
            try:
                self._model = WhisperModel(self.model_size, device="cpu", compute_type="int8")
                self.device = "cpu"
            except Exception as exc2:
                self._emit_error(f"could not load model: {exc2}")
                return False
        self._vad = webrtcvad.Vad(self._vad_aggressiveness)
        self._status(f"{self.display_name} ready")
        return True

    # ---------------------------------------------------------------- ingestion

    def append(self, frame: bytes) -> None:
        """Slice incoming audio into VAD frames and track speech/silence edges."""
        if self._cancelled:
            return
        with self._lock:
            self._pending.extend(frame)
            while len(self._pending) >= VAD_FRAME_BYTES:
                chunk = bytes(self._pending[:VAD_FRAME_BYTES])
                del self._pending[:VAD_FRAME_BYTES]
                self._consume_vad_frame(chunk)

    def _consume_vad_frame(self, chunk: bytes) -> None:
        """Caller holds the lock."""
        if self._vad is None:
            # Model still loading: keep the audio so the first words aren't lost.
            self._utterance.extend(chunk)
            return
        try:
            voiced = self._vad.is_speech(chunk, SAMPLE_RATE)
        except Exception:
            voiced = True

        if voiced:
            self._speaking = True
            self._silence_ms = 0
            self._utterance.extend(chunk)
            return

        if not self._speaking:
            return  # silence before any speech — nothing to hold on to

        # Trailing silence still belongs to the utterance: whisper reads a word's
        # release, and clipping at the exact VAD edge chops final consonants.
        self._utterance.extend(chunk)
        self._silence_ms += VAD_FRAME_MS
        if self._silence_ms >= SILENCE_HANGOVER_MS:
            self._close_utterance()

    def _close_utterance(self) -> None:
        """Caller holds the lock."""
        audio = bytes(self._utterance)
        self._utterance.clear()
        self._speaking = False
        self._silence_ms = 0
        if len(audio) < SAMPLE_RATE * 2 * MIN_UTTERANCE_MS // 1000:
            return
        self._queue.append((audio, True))
        self._work.release()

    def maybe_partial(self) -> None:
        """Queue a re-decode of the open utterance if one is due."""
        now = time.monotonic()
        with self._lock:
            if not self._speaking or now - self._last_partial_at < PARTIAL_INTERVAL_S:
                return
            if len(self._utterance) < SAMPLE_RATE * 2 * MIN_UTTERANCE_MS // 1000:
                return
            self._last_partial_at = now
            self._queue.append((bytes(self._utterance), False))
        self._work.release()

    # ---------------------------------------------------------------- decoding

    def _worker(self) -> None:
        if not self._ensure_model():
            return
        while not self._cancelled:
            self._work.acquire()
            if self._cancelled:
                return
            with self._lock:
                if not self._queue:
                    continue
                # Only the newest partial is interesting; finals must all run.
                finals = [item for item in self._queue if item[1]]
                partials = [item for item in self._queue if not item[1]]
                self._queue = []
            for audio, _ in finals:
                self._decode(audio, final=True)
            if partials:
                self._decode(partials[-1][0], final=False)

    def _decode(self, audio: bytes, final: bool) -> None:
        if self._model is None or self._cancelled:
            return
        samples = np.frombuffer(audio, dtype=np.int16).astype(np.float32) / 32768.0
        try:
            segments, _ = self._model.transcribe(
                samples,
                language=self.language,
                beam_size=5 if final else 1,   # partials favour latency
                vad_filter=False,              # we already segmented
                condition_on_previous_text=False,
            )
            text = "".join(seg.text for seg in segments).strip()
        except Exception as exc:
            self._emit_error(str(exc))
            return

        if not text or self._cancelled:
            return
        with self._lock:
            if self._suppress:
                return
        if final and self.on_segment_final:
            self.on_segment_final(text)
        elif not final and self.on_partial:
            self.on_partial(text)

    # ---------------------------------------------------------------- control

    def finish(self) -> None:
        with self._lock:
            if self._utterance:
                self._close_utterance()

    def discard_utterance(self) -> None:
        with self._lock:
            self._suppress = True
            self._utterance.clear()
            self._pending.clear()
            self._queue.clear()
            self._speaking = False
            self._silence_ms = 0
        # Results already in flight belong to the discarded utterance; let them
        # drain, then accept new ones.
        def _unsuppress():
            time.sleep(0.4)
            with self._lock:
                self._suppress = False

        threading.Thread(target=_unsuppress, daemon=True).start()

    def cancel(self) -> None:
        self._cancelled = True
        self._work.release()

    # ---------------------------------------------------------------- plumbing

    def _emit_error(self, message: str) -> None:
        if self.on_error:
            self.on_error(message)

    def _status(self, message: str) -> None:
        if self.on_status:
            self.on_status(message)
