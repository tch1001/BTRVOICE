# BtrVoice / Jarvis Voice handoff

Updated: 2026-08-13 14:05 SGT (root cause of "no audio frames" found and fixed; awaiting
hardware confirmation — see "2026-08-13 afternoon session" below)

This document is for the next coding agent. It describes the current native Jarvis Voice
implementation, the latest Core Audio failure, what has and has not been verified, and
how to continue without damaging concurrent work.

## Read this first

- Primary repo: `/Users/fish/btr_voice`
- Jarvis framework repo: `/Users/fish/jarvis`
- Packaged app: `/Users/fish/btr_voice/build/BtrVoice.app`
- Persistent log: `/Users/fish/Library/Logs/BtrVoice.log`
- Both repositories have substantial uncommitted work. Do **not** reset, clean, stash,
  mass-format, or overwrite it. Inspect ownership and diffs file by file.
- The user relies on ordinary BtrVoice dictation. Preserve that workflow while working
  on the separate **Start Jarvis** surface.
- Do not start the microphone or play test speech without telling the user. Compilation
  and `--self-test` are silent; actual route validation requires the user's hardware test.
- Never copy an OpenAI key into source, logs, this handoff, or a shell command. BtrVoice
  stores it through `OpenAIKeyStore`/Keychain.

## Product intent

Start Jarvis is no longer a speech-to-text wrapper or a web preview. It is intended to be
a compact, native, voice-first client for the full Jarvis framework:

- direct, streaming speech conversation through OpenAI Realtime;
- unified conversation history across voice, TUI, Telegram, and other Jarvis surfaces;
- current task summaries and catch-up notices when the voice window is reopened;
- interruption, mute, stop, voice/text output selection, and text fallback;
- named Jarvis tools only, with significant coding/planning delegated to the Jarvis
  orchestrator/development provider rather than performed by the lightweight voice model;
- seamless gateway/provider recovery without closing the SwiftUI conversation window;
- local owner-speaker filtering before audio leaves the Mac;
- app-specific microphone and speaker selection without changing macOS defaults;
- no framework-event firehose and no scrolling except the conversation itself.

The window should remain small (roughly a quarter of the screen or less), flow like Siri,
and keep the important controls visible.

## Recovery snapshot

A pre-speaker-filter snapshot branch exists in BtrVoice:

```text
codex/snapshot-before-speaker-gate-20260813 -> 00185b8
```

`00185b8` is also the current `main`/`origin/main` commit. The deeper native voice,
speaker-filter, and audio-route changes described below are still uncommitted. Use the
snapshot for comparison only; do not destructively switch or reset the dirty checkout.

## Current architecture

```text
Mac microphone
  -> JarvisNativeAudio input-only AUHAL callback
  -> 24 kHz mono PCM16
  -> optional local FluidAudio owner-speaker gate
  -> JarvisRealtimeSocket
  -> OpenAI Realtime
       -> named tool call
       -> local jarvis.voice HTTP gateway
       -> Jarvis task/development/orchestrator providers

OpenAI Realtime PCM response
  -> JarvisNativeAudio response-only AVAudioEngine
  -> selected Jarvis speaker

jarvis.voice timeline/tasks
  -> JarvisVoiceController
  -> compact native JarvisSurfaceWindow
```

Important files:

- `Sources/BtrVoice/Jarvis/JarvisSurfaceWindow.swift`
  Native SwiftUI/AppKit window, conversation, fixed controls, audio-route popover, local
  speaker-filter card, current-work summary, and text fallback.
- `Sources/BtrVoice/Jarvis/JarvisVoiceController.swift`
  Main-actor state machine. Owns Realtime events, history hydration, tasks, named tools,
  interruption, audio selection/restarts, catch-up notices, and speaker-gate flow.
- `Sources/BtrVoice/Jarvis/JarvisNativeAudio.swift`
  Direct AUHAL PCM capture, separate AVAudioEngine playback, conversion,
  VoiceProcessingIO, level reporting, and staged Core Audio errors.
- `Sources/BtrVoice/Jarvis/JarvisAudioDevices.swift`
  Core Audio discovery, per-device UIDs/channels/default flags, route recommendations,
  and live device/default-route notifications.
- `Sources/BtrVoice/Jarvis/JarvisRealtimeSocket.swift`
  Authenticated native WebSocket to `wss://api.openai.com/v1/realtime`.
- `Sources/BtrVoice/Jarvis/JarvisSpeakerGate.swift`
  FluidAudio/Core ML owner-speaker enrollment/classification and PCM frame masking.
- `Sources/BtrVoice/Jarvis/JarvisVoiceService.swift`
  Starts and monitors the trusted local `jarvis.voice` HTTP gateway plus task, notify,
  and development providers. Replaces a failed gateway without unmounting the UI.
- `/Users/fish/jarvis/plugins/jarvis/voice/`
  Local HTTP gateway for shared history, configuration, named tools, task status, and
  lifecycle information. It is not the live microphone implementation.

High-frequency microphone levels deliberately update `JarvisMicrophoneMeter`, a small
separate `ObservableObject`, rather than `JarvisVoiceController`. Updating the whole
controller at audio cadence previously caused transcript redraws and a spinning/hung UI.
Do not merge the meter back into the controller.

## Audio selection behavior now implemented

Jarvis can select devices independently from macOS and other apps:

- Device choices are persisted by Core Audio UID in UserDefaults:
  - `jarvis-native-input-device-uid`
  - `jarvis-native-output-device-uid`
- Current saved route on this Mac:
  - input: `BuiltInMicrophoneDevice`
  - output: `BuiltInSpeakerDevice`
- `JarvisAudioDeviceMonitor` listens for device-list, default-input, and default-output
  changes. The picker refreshes without restarting BtrVoice.
- Changing either picker while connected clears only the pending Realtime input buffer,
  restarts only Jarvis audio, and preserves the Realtime socket/conversation.
- Removed/disconnected devices are detected and the route is refreshed.
- There is no silent fallback to another microphone. A selected-device failure remains
  visible while text mode stays connected.
- Capture and response playback failures are handled separately. Playback failure keeps
  microphone capture alive.
- A two-second health check reports when the selected mic opens but supplies no PCM.
- The audio popover label is now **Last audio issue**, not **Last microphone error**.

### Echo-cancellation constraint

Normal capture/playback can use Jarvis-only devices without changing macOS defaults.
Apple VoiceProcessingIO is different: this implementation enables it only when the
selected Jarvis input and output also equal the current system-default pair. This avoids
Core Audio constructing a broken aggregate route. If the routes differ, Jarvis respects
the app-specific choice and runs without Apple VoiceProcessingIO echo cancellation.

Do not silently change the system input/output to obtain AEC. The user explicitly does
not want Jarvis to disrupt audio routing for music or other apps.

## 2026-08-13 afternoon session: silent-capture root cause found and fixed

The user retried the built-in route with the 13:12 build and still got
`microphone health check failed — no PCM from MacBook Air Microphone` (log 13:46:10).
So the AUHAL rewrite below opened the device but never produced a callback.

**Root cause (confirmed, not speculative):** `startCaptureUnit` read the *client* format
from `(kAudioUnitScope_Output, bus 1)` — which was still AUHAL's 44.1 kHz default — and
never set it. Per Apple TN2091, AUHAL performs **no sample-rate conversion on the input
side**; a Core Audio property dump on this Mac (scratch tool, see below) shows device 101
`MacBook Air Microphone` runs **48000 Hz / 3ch (Float32)**. With a 44.1 kHz client format
the unit initializes and starts cleanly but the input callback simply never fires. This
also explains the inconsistent `44100Hz/2ch` vs `44100Hz/3ch` log lines: those were the
default client format, not the device's.

**Fix applied in `JarvisNativeAudio.startCaptureUnit`:**

1. Read the *device-side* format from `(kAudioUnitScope_Input, bus 1)` after binding the
   device.
2. Build the client format as standard Float32 deinterleaved at the device's own sample
   rate and channel count, and set it on `(kAudioUnitScope_Output, bus 1)` — new staged
   error `matching the microphone sample rate`. The existing `AVAudioConverter` in
   `convert()` already handles 48 kHz/3ch → 24 kHz mono PCM16, so nothing downstream
   changed.
3. Added one-shot diagnostics so the next failure names its boundary in the log:
   `first microphone callback arrived — frames=N` and, on render failure,
   `microphone render failed — OSStatus N`. Flags reset on every start (all three start
   paths).

Verified after the change: `swift build` clean, full `--self-test` suite passes, packaged
and relaunched via `./build.sh --debug --run` (signature valid). **Hardware test still
pending** — the user must click Start Jarvis; expected log sequence is now
`first microphone callback arrived` → `first microphone PCM reached Realtime boundary`
within two seconds, level meter moving, then the start-stop-start cycle without a crash.

If it still fails: `matching the microphone sample rate` in the error banner means the
format set was refused; `microphone render failed — OSStatus …` means callbacks fire but
`AudioUnitRender` rejects the buffer (suspect the AVAudioPCMBuffer's buffer list vs
frames — set `frameLength` before render or hand-build the AudioBufferList); no new log
line at all means callbacks genuinely never fire — recheck device binding order and
whether the quarantined VoiceProcessingIO graph wedges the HAL (try the ordinary route
with `preferVoiceProcessing` false to isolate).

Device-format probe used (rebuild if needed):
Core Audio property dump listing every device's nominal rate + input stream format —
originally at `/private/tmp/claude-501/…/scratchpad/devrate.swift`; trivial to recreate:
enumerate `kAudioHardwarePropertyDevices`, print `kAudioDevicePropertyNominalSampleRate`
and input-scope `kAudioDevicePropertyStreamFormat`.

Also still open, unchanged by this session:

- VoiceProcessingIO now fails with `-10875` (`kAudioUnitErr_FailedInitialization`) at
  stage `starting microphone capture` and the code falls back to ordinary capture
  (`voiceProcessingUnavailable = true`). Echo cancellation is therefore OFF on the
  default route. Investigate after basic capture is confirmed; transcript-level echo
  suppression still applies.
- Duplicate `tasks`/`notify`/`development` provider-registration noise at every launch
  (`BusError: rejected … already provided`) — harmless, previously documented, but worth
  a "check before launch" cleanup in `JarvisVoiceService`.

## Previous session: latest failures and fix awaiting hardware confirmation

The user selected:

```text
MacBook Air Microphone -> MacBook Air Speakers
```

Jarvis showed:

```text
com.apple.coreaudio.avfaudio -10868
```

`-10868` is `kAudioUnitErr_FormatNotSupported`. The initial mitigation explicitly
disabled AVAudioEngine's unused output side. That allowed the device and graph to open,
but the user then got `MacBook Air Microphone opened, but no audio frames arrived`, and
the second Start attempt crashed the whole process.

The crash is captured in:

```text
/Users/fish/Library/Logs/DiagnosticReports/BtrVoice-2026-08-13-130540.ips
```

The crash stack is definitive: `AVAudioEngineImpl::InstallTapOnNode` raised an Objective-C
exception from `JarvisNativeAudio.startEngine` while handling the second
`session.updated`. AVFAudio still considered the old silent tap installed. Swift `do`/
`catch` cannot catch this Objective-C exception.

The silent stream and crash had the same root: an AVAudioEngine input tap is driven by
the engine's output render loop. Disabling output made the app-specific input-only graph
start without `-10868`, but it produced no callbacks. Re-enabling output would return to
invalid format negotiation on the input-only built-in microphone.

Replacement fix in `JarvisNativeAudio.swift`:

1. Ordinary app-specific capture no longer installs an AVAudioEngine tap at all.
2. Create a fresh HAL Output Audio Unit (`kAudioUnitSubType_HALOutput`) for every start.
3. Disable its output bus 0, enable input bus 1, and bind the selected microphone.
4. Read the device stream format and install
   `kAudioOutputUnitProperty_SetInputCallback`.
5. In the callback, call `AudioUnitRender`, wrap the native frames in
   `AVAudioPCMBuffer`, and feed the existing 24 kHz PCM converter/gate/Realtime path.
6. On stop, synchronously stop, uninitialize, and dispose that capture unit. A retry gets
   a completely fresh unit and cannot collide with an old AVAudioEngine tap.
7. Keep response playback on a second AVAudioEngine configured output-only.
8. Staged errors now identify:
   - creating/initializing microphone capture;
   - opening the selected microphone;
   - reading its stream format;
   - installing its callback;
   - starting microphone capture;
   - configuring/opening/starting response playback.

This is the Core Audio input-only topology described by Apple's
`kAudioOutputUnitProperty_EnableIO` and
`kAudioOutputUnitProperty_SetInputCallback` contracts. The code compiles and silent tests
pass, but **the user has not yet confirmed direct AUHAL capture or a start-stop-start
cycle on real hardware**. Those are the next actions, not more speculative refactoring.

Ask the user to click Start Jarvis with the saved built-in route. Expected results:

- no `-10868` banner;
- the level meter moves;
- within two seconds the log records first PCM;
- spoken words are transcribed once, without Jarvis hearing its own response;
- response audio uses MacBook Air Speakers;
- changing a picker does not require restarting BtrVoice.
- Stop, then Start a second time; the app must not crash.

If it fails, request the exact new **Last audio issue** text and immediately inspect the
tail of the log. The stage prefix should identify the next boundary to fix.

## Diagnostics

```bash
cd /Users/fish/btr_voice

# Persistent application trace
tail -200 "$HOME/Library/Logs/BtrVoice.log"

# Only Jarvis Voice audio lines
rg "jarvis voice:" "$HOME/Library/Logs/BtrVoice.log" | tail -120

# Saved app-specific route
defaults read com.btr.voice jarvis-native-input-device-uid
defaults read com.btr.voice jarvis-native-output-device-uid

# Confirm the most recent packaged launch
rg "launched /Users/fish/btr_voice/build/BtrVoice.app" \
  "$HOME/Library/Logs/BtrVoice.log" | tail -1
```

Useful success messages:

```text
jarvis voice: microphone active ...
jarvis voice: first microphone PCM reached Realtime boundary ...
jarvis voice: first PCM append sent to Realtime ...
jarvis voice: response playback active ...
```

Duplicate `tasks`, `notify`, or `development` provider-registration errors currently
appear when providers already exist. They are noisy but generally harmless: exclusive
providers reject the duplicate and the already-running provider remains available. Do
not confuse these lines with the microphone failure.

## Verification completed before this handoff

The following passed after the input-only/output-only change:

```bash
cd /Users/fish/btr_voice
swift build
.build/debug/BtrVoice --self-test
```

The entire self-test suite passed, including device catalog separation, app-only route
rules, echo-route logic, owner filtering, overlap rejection, PCM masking, Jarvis command
routing, buffer behavior, and dictation tests.

The app was packaged, signed with the existing local signing identity, and relaunched:

```bash
./build.sh --debug --run
```

After changing any source, rerun all three commands. Packaging kills and relaunches the
app but does not itself start Jarvis Voice. The FluidAudio package emits a known harmless
warning about its unhandled `benchmark.md`. A strict trust-chain `codesign` check may say
the local certificate is not trusted; the build script's designated-requirement check
passes and the app launches with the persistent local identity.

## Dirty worktrees and change ownership

### `/Users/fish/btr_voice`

Current native voice work includes modifications/new files in:

```text
Package.swift
Package.resolved
README.md
Sources/BtrVoice/AppDelegate.swift
Sources/BtrVoice/Jarvis/JarvisAudioDevices.swift
Sources/BtrVoice/Jarvis/JarvisNativeAudio.swift
Sources/BtrVoice/Jarvis/JarvisRealtimeSocket.swift
Sources/BtrVoice/Jarvis/JarvisSpeakerGate.swift
Sources/BtrVoice/Jarvis/JarvisSurfaceWindow.swift
Sources/BtrVoice/Jarvis/JarvisVoiceController.swift
Sources/BtrVoice/Jarvis/JarvisVoiceService.swift
Sources/BtrVoice/Support/SelfTest.swift
```

These dirty files contain concurrent dictation/commit-UX work and must not be overwritten
as part of audio work:

```text
Sources/BtrVoice/Dictation/DictationController.swift
Sources/BtrVoice/UI/BufferTextView.swift
Sources/BtrVoice/UI/DictationPanelView.swift
```

Those changes publish pending-commit state, freeze/recolor recognizer-owned grey text
while Insert/Send finalizes, and remove an artificial render delay. Preserve them.

`HANDOFF.md` itself is untracked unless the user or next agent deliberately commits it.
Do not blindly run `git add -A`.

### `/Users/fish/jarvis`

The Jarvis repo is also heavily dirty with ongoing unified-engine, development-provider,
task, notification, Telegram, Codex engine, remote-engine, and voice-gateway work. Its
HEAD is `aea32ee` (`/engine on Telegram: tap to switch, no model call`). Preserve all
working-tree changes. Read `/Users/fish/jarvis/AGENTS.md` and
`/Users/fish/jarvis/docs/architecture.md` before changing architecture.

If modifying Jarvis mesh/router/bus/tmux paths, follow its mandatory test rules,
including `./scripts/two-node-check.sh` where applicable.

## Safety and design constraints for the next agent

- Do not turn the voice model into the primary coding planner. It understands the spoken
  intent, keeps the conversation flowing, and dispatches heavy work to named Jarvis
  capabilities/orchestrators.
- Do not create a raw model-output-to-shell or model-output-to-bus path. Named tools go
  through the local trusted gateway and existing Jarvis authorization boundaries.
- Do not let assistant playback feed back into Realtime as user input. Preserve
  VoiceProcessingIO when available, local speaker gating, interruption handling, and the
  separate capture/playback graphs.
- Do not reintroduce WKWebView/browser audio. The user chose native Swift specifically
  because the web AudioWorklet/module path was unreliable.
- Do not force macOS audio defaults, pause music, or silently choose another microphone.
- Do not redraw the entire conversation at microphone-meter cadence.
- Destructive actions require clear confirmation. Self-edit/restart should announce the
  restart while keeping the UI mounted and recovering providers underneath it.
- Unified history is a product requirement. Do not reduce Voice back to one-shot
  transcription or a stateless command relay.

## Recommended next sequence

1. Have the user perform the built-in microphone/speaker hardware test above.
2. Inspect the staged error/log if it fails; change only the failing boundary.
3. Verify live picker switching in both directions while the Realtime conversation stays
   connected.
4. Verify music continues when ordinary capture starts.
5. Verify one full spoken turn and interruption without self-echo.
6. Only after hardware confirmation, review and commit the native voice work in coherent
   pieces. Keep concurrent dictation changes separate.
7. Then address lower-priority cleanup: duplicate provider log noise, unused audio graph
   state, longer route stress tests, and docs that still describe every route as fully
   echo-cancelled.
