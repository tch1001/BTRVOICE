# BtrVoice

Voice dictation for macOS that works in **every** app — including the ones Apple's
built-in dictation quietly refuses to type into.

## The problem this solves

macOS dictation inserts text through the accessibility API. That works in native
Cocoa text views and nowhere else, which is why it does nothing useful in Telegram,
Terminal, many Electron apps, and most games.

BtrVoice never tries to insert text that way. Instead it:

1. transcribes your speech into a **buffer inside its own window**,
2. lets you read it, edit it, or throw it away,
3. and only on an explicit commit replays it as **synthetic keyboard events**.

A `CGEvent` carrying a unicode payload is indistinguishable from a real keypress, so
every app accepts it — no cooperation from the target app required. The review step is
the other half of the point: you see what was heard before it lands anywhere.

## Build

```bash
./build.sh --run
```

That produces `build/BtrVoice.app` and launches it. `./build.sh --debug` for a debug
build, `./build.sh` to build without launching. Requires Swift 6 / Xcode 26 and
macOS 15+.

Pure logic (command parsing, buffer arithmetic, event chunking) has a runnable suite:

```bash
./build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test
```

## Permissions

Three grants are needed, and macOS will ask for the first two the first time you
dictate:

| Permission | Why | Where |
| --- | --- | --- |
| Microphone | capture audio | Privacy & Security › Microphone |
| Speech Recognition | transcribe it | Privacy & Security › Speech Recognition |
| **Accessibility** | type into other apps, and read the caret position | Privacy & Security › Accessibility |

Accessibility has to be granted by hand — add `build/BtrVoice.app` under that pane.
Until you do, dictation still works and the buffer still fills; only the commit step
is blocked, and the panel says so. The app polls, so the warning clears within a
second or two of granting — no relaunch needed.

### Making the grant survive rebuilds

Run this **once**, before granting anything:

```bash
./tools/make-signing-cert.sh
```

Without it the app is signed ad-hoc, which makes its designated requirement a hash of
the binary — so every rebuild looks like a different program to macOS. The
Accessibility entry stays in the list, still switched on, but no longer matches
anything. The symptom is "I enabled it and it still says I haven't".

The script creates a local self-signed identity, which `build.sh` then picks up
automatically. The requirement becomes `identifier "com.btr.voice" and certificate
leaf = H"…"`, which doesn't change when the binary does. It runs unattended and only
touches your login keychain.

If you hit the stale-grant state anyway: in Privacy & Security › Accessibility select
BtrVoice, press **−** to remove it, then **+** to add `build/BtrVoice.app` again.
Toggling it off and on is *not* enough — the entry itself is the stale part.

## Using it

The menu-bar item (a waveform) holds every command; the floating panel is the hover
window, and it parks itself next to the caret of whatever you're typing into, falling
back to bottom-centre like Siri.

| Key | Does |
| --- | --- |
| `⌥Space` | tap to start/stop dictating; **hold** for push-to-talk |
| `⌥↩` | commit — type the buffer into the frontmost app |
| `⌥⎋` | discard the buffer and hide the panel |
| `⌘↩` | commit, while the panel's editor has focus |
| `⎋` | discard, while the panel's editor has focus |

Click into the transcript to fix a word by hand — the panel is non-activating, so the
app you were working in keeps its caret the whole time.

### Spoken commands

Recognised instead of being transcribed (toggle off in Settings):

- "new line", "new paragraph", "tab key"
- "scratch that" — delete the last sentence
- "scratch word" — delete the last word
- "clear all" / "start over" — empty the buffer
- "commit that" — type the buffer into the focused app
- "send it" — type it, then press Return

### Settings worth knowing

Under the menu-bar item › Settings:

- **How to insert text** — *Type keystrokes* works everywhere; *Paste (⌘V)* is much
  faster for long passages and restores your clipboard afterwards; *Automatic* types
  short text and pastes anything over 120 characters.
- **How to type newlines** — *Return key* is right for Terminal. In chat apps where
  Return sends the message, switch to *Shift-Return* so multi-line dictation doesn't
  fire off half a message. Also switchable from the panel footer.
- **Prefer on-device recognition** — keeps audio off Apple's servers. Falls back to
  server recognition automatically if the on-device model for your language isn't
  installed.
- **Panel follows the text caret** — off pins the panel to bottom-centre instead.
- **Stop listening after a pause** — hands-free end-of-utterance detection.

### Jarvis Voice and the local owner filter

**Start Jarvis** opens a compact native SwiftUI GPT Realtime console rather than the
ordinary dictation buffer. It uses AVAudioEngine for full-duplex capture and playback;
there is no WKWebView, browser microphone, or AudioWorklet in this path. Only the
conversation scrolls. Voice controls, output mode, the local filter, and a three-row
current-work summary stay visible in one small window; framework events are reduced to
an occasional catch-up/restart banner instead of a separate feed.

The **My voice only** card adds the local owner filter:

1. Start the voice session and choose **Enroll my voice**.
2. The first setup downloads FluidAudio's pinned Core ML Sortformer weights.
3. Speak naturally for six seconds. The sample stays in Application Support on this Mac.
4. With **My voice only** enabled, Apple's native VoiceProcessingIO echo-cancels
   Jarvis's speaker playback and the local model masks non-owner or overlapping speaker
   frames before native PCM reaches Realtime over WebSocket.

Headphones are not required. Filtering adds roughly 1.2 seconds of input delay, and an
enabled filter fails closed if classification fails. **Forget voice** removes the local
enrollment. Voice matching is a conversational filter, not authentication; confirmed
Jarvis actions keep their normal safety checks.

## How it fits together

```
AudioCapture ──buffers──▶ AppleSpeechEngine ──partials/segments──▶ TextBuffer
     │                          ▲                                     │
     └── RMS level ─────┐       │                          user edits ─┤
                        ▼       │                                      ▼
              DictationController (rotation + silence policy)   [ commit ]
                        │                                              │
                        └────── TargetTracker ──focus──▶ TextInjector ─┘
                                                          (CGEvent keystrokes)
```

- **`Audio/AudioCapture`** — `AVAudioEngine` tap; publishes buffers, a smoothed level,
  and how long it has been quiet.
- **`Speech/AppleSpeechEngine`** — `SFSpeechRecognizer` behind the
  `TranscriptionEngine` protocol. `SFSpeechRecognitionTask` stops accepting audio
  after roughly a minute, so long dictation is stitched from consecutive *segments*;
  the controller rolls over during a detected pause so no word straddles a boundary.
  Swap in whisper.cpp or Parakeet by implementing that one protocol.
- **`Dictation/TextBuffer`** — the staging area, with sentence/word deletion, undo,
  and human-looking spacing when fragments are joined.
- **`Inject/TextInjector`** — chunked unicode key events (never splitting a grapheme
  cluster), real Return/Tab key presses, or clipboard paste with save-and-restore.
  Events come from a *private* `CGEventSource` so a still-held `⌥` from the hotkey
  can't corrupt what gets typed.
- **`Inject/CaretLocator`** — reads the focused element's caret rect via the
  accessibility API, purely to place the panel. The write path is deliberately not AX.
- **`Hotkey/HotkeyManager`** — Carbon `RegisterEventHotKey`, which works before
  Accessibility is granted, and consumes the key rather than just observing it.
- **`UI/FloatingPanel`** — non-activating `NSPanel`, anchor-based placement that
  re-runs whenever SwiftUI resizes the panel, and stops fighting you once you drag it.

## Known limits

- Recognition quality is Apple's. The `TranscriptionEngine` seam exists so a local
  Whisper model can be dropped in when you want better accuracy or more languages.
- Caret-following depends on what the focused app exposes over accessibility. Terminal
  and most Electron apps report no caret geometry, so the panel anchors to the text
  element or falls back to bottom-centre.
- Very fast typing into the panel while dictation is still running can reorder text,
  since recognised segments append to the end regardless of where your cursor is.
