# BtrVoice for Linux (X11)

The Ubuntu port of BtrVoice. Same premise as the macOS app: speech goes into a
review buffer you can read and fix, and only an explicit commit replays it as
**synthetic keyboard events** — so it lands in terminals, Electron apps, games and
anything else that ignores accessibility-based insertion.

## Run

```bash
cd linux
.venv/bin/python -m btrvoice                  # large-v3 on the GPU
.venv/bin/python -m btrvoice --model small    # faster, less accurate
.venv/bin/python -m btrvoice --language auto  # detect instead of forcing English
.venv/bin/python -m btrvoice --list-sources   # what can we capture from?
.venv/bin/python -m btrvoice --self-test      # pure-logic suite, no GPU/mic/X needed
```

| Key | Action |
| --- | --- |
| `F9` | start / stop dictating |
| `F10` | commit the buffer into the focused window |
| `F8` | discard the buffer |
| `F7` | hide / show the panel (the app stays in the tray) |

## The tray menu

The tray icon is the app's real home — the panel is just a view onto it, and
hiding the panel doesn't stop anything.

| Item | Notes |
| --- | --- |
| Start / Stop dictating | mirrors `F9`, label follows the state |
| Commit to focused app | mirrors `F10` |
| Hide / Show panel | mirrors `F7`, label follows the state |
| Restart BtrVoice | re-execs with the same arguments; cheap, since the model cache is warm |
| Quit BtrVoice | terminates `parec` and releases the hotkey grab before exiting |

Restart and quit both go through the same teardown. That matters more than it
sounds: `parec` is a real child process and the hotkey listener owns an X grab,
and neither is cleaned up by process exit alone. On restart in particular,
`execv` replaces the process image — an un-terminated `parec` would be reparented
to init and hold the capture stream open against the incoming instance.

Requires a system-tray host. GNOME needs the **AppIndicator** extension
(`ubuntu-appindicators` on Ubuntu); without it the icon never appears and `F7`
becomes the only way to get the panel back.

## How it maps onto the macOS app

| macOS | Linux |
| --- | --- |
| `CGEvent` unicode keystrokes | XTEST via `xdotool` |
| `SFSpeechRecognizer` / OpenAI Realtime | `faster-whisper`, on-device |
| `AVAudioEngine` capture | `parec` (PulseAudio) |
| non-activating `NSPanel` | Qt `WA_ShowWithoutActivating` + `WindowDoesNotAcceptFocus` |
| `NSStatusItem` | `QSystemTrayIcon` |
| `Inject/TargetTracker.swift` | `btrvoice/inject.py` |
| `Dictation/TextBuffer.swift` | `btrvoice/buffer.py` |
| `Support/SelfTest.swift` | `btrvoice/selftest.py` |

## The two things that are load-bearing

**The panel must not take focus.** If it does, the target window is lost and a
commit types into the wrong place. Qt's `WindowDoesNotAcceptFocus` plus
`WA_ShowWithoutActivating` is the X11 equivalent of a non-activating `NSPanel`.
A consequence worth knowing before you "fix" it: because the panel can't be
focused it can't receive key events, so the buffer is read-only and every control
is driven from the tray, the hotkeys, or the mouse.

**The previous window must be tracked.** `TargetTracker` polls the focused window
and skips our own, so `windowactivate --sync` can restore it before typing. The
`--sync` is not optional — without it the first characters race the focus change
into whatever was focused before.

## Segmentation

macOS gets this free from OpenAI's server-side VAD. Locally:

- `webrtcvad` closes an utterance after **700 ms** of silence, producing a *final*
- the open utterance is re-decoded every **~550 ms**, producing a *partial*

Partials are re-decoded from the top rather than spliced incrementally — whisper
has no streaming mode, and on a 3090 a two-second decode costs tens of
milliseconds, well under the repaint interval. Trailing silence is kept in the
utterance on purpose: clipping at the exact VAD edge chops final consonants.

Only *confirmed* (final) text is ever committed. A partial is a guess, shown
greyed out, and `take_confirmed()` deliberately leaves it behind.

## Requirements

Already present on this machine; listed for a fresh install.

- `xdotool` — injection (`apt install xdotool`)
- `pulseaudio-utils` — provides `parec`
- An X11 session. **Wayland will not work**: XTEST can't reach other clients
  there, and a port would need `ydotool` with `/dev/uinput` access.
- NVIDIA GPU optional — the engine falls back to CPU `int8` if CUDA fails.

Python dependencies live in `.venv` (uv-managed): PySide6, faster-whisper,
webrtcvad-wheels, numpy, scipy, pynput.

## Not yet ported

The macOS app has these; the Linux port doesn't:

- **Jarvis / GPT editor** (`Sources/BtrVoice/Jarvis/`, `OpenAIEditorEngine.swift`) —
  semantic app commands, the activity feed, versioned rules
- **Voice commands** (`VoiceCommands.swift`) — spoken "new line", "scratch that"
- **Caret location** (`CaretLocator.swift`) — needs AT-SPI2 rather than the AX API
- **Settings UI and persistence** (`Settings.swift`)
- **Waveform view**
- An **OpenAI backend** as an alternative to local whisper — the engine contract
  in `stt/base.py` is where it would slot in
