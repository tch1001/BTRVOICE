# Better Voice

Better Voice is an AI listening editor for macOS and iOS. It turns natural speech into
the text you meant to write—not just a literal transcript.

Speak normally, correct yourself out loud, request edits, and review the finished draft
before inserting it into Telegram, email, a terminal, or any other app.

## Video demo

> 🎥 **Coming soon:** add the Better Voice demo video here.

## What it does

- Maintains a polished draft while you speak.
- Applies corrections such as “scratch that” or “make the last sentence warmer.”
- Fixes obvious recognition errors and punctuation while preserving your voice.
- Remembers standing spelling, tone, and formatting rules.
- Shows raw heard text separately from the AI-edited result.
- Inserts text only when you explicitly approve it.
- Offers literal GPT transcription and Apple Speech as alternatives to the AI editor.

## Example

**You say:**

> Hey Sarah, just checking in about the launch next Friday—actually, make that Thursday.
> Remove “just checking in” and make it more direct.

**Better Voice writes:**

> Hey Sarah, can we confirm the launch for next Thursday?

The correction and editing instruction never appear in the final text.

## macOS

Better Voice keeps the draft in a small floating editor. When you approve it, the app
types or pastes it into the previously focused application.

```bash
./build.sh --run
```

Requires macOS 15+, Swift 6, and Xcode 26. Grant Microphone and Accessibility access;
Apple Speech mode also requires Speech Recognition permission.

Useful shortcuts:

| Shortcut | Action |
| --- | --- |
| `⌥Space` | Start or stop listening; hold for push-to-talk |
| `⌥↩` | Insert the edited draft |
| `⌥⎋` | Clear the draft |

### Screen reading in Voice Control

In **Voice Control**, say “Read my screen,” “What am I looking at?” or “Explain
the error on this page.” BtrVoice reads the active window's Accessibility text,
button labels, roles, states, and supported actions, then answers in the existing
activity panel. The microphone, live transcription,
keyboard commands, and learned skills work as before.

Structured reading uses BtrVoice's existing **Accessibility** permission. When
**Screen & System Audio Recording** access is also available, the assistant can
request an image if the question needs visual detail. Only structured text is read first;
screenshots are captured lazily. Apps that
expose no useful text fall back to the screenshot directly.

If an image is needed and permission is missing, macOS may ask for **Screen & System
Audio Recording** access under **System Settings → Privacy & Security**. Grant it
and retry; macOS may require an app restart. No screen access is requested during
normal startup.

Each question gets fresh context, excluding BtrVoice's overlay from screenshots,
using the existing OpenAI API key. Images are held in memory, are not saved to disk
or reused for subsequent questions, and use `store: false` requests. Protected
Accessibility fields are omitted. Slow or oversized Accessibility trees return a
bounded partial view so an unresponsive app cannot stall Voice Control.
Read-only screen questions return answers without executing actions or saving skills.
Explicit interaction requests use the Accessibility controls described below.
Accessibility coverage varies by app. This feature is specific to macOS Voice Control.

For a local capture check without sending an image to OpenAI:

```bash
build/BtrVoice.app/Contents/MacOS/BtrVoice --check-screen
```

### Desktop interaction through Accessibility

Speak naturally: “Click Unread,” “Select that tab,” “Open the View menu,” “Turn the
volume slider down,” “Expand that row,” or “Resize this window.” Voice Control can
perform the actions exposed by each control, including app-specific actions, and
change supported selection, focus, expansion, numeric values, text selection, and
window position, size, minimized, and full-screen state. Menu and window inspection
also works outside the main content tree. No mouse movement is needed for AX actions.

Multi-step requests can act, read the resulting screen, and continue. For example,
“Open the browser and tell me how many tabs I have” now continues after launching
the browser. Explicit requests to review multiple pages can select tabs and retain
observations as they go. Partial inventories and unread badges are not treated as
total item counts. Large trees can be inspected by container and child offset.

Each operation uses an expiring ID from the latest snapshot, checks the foreground
app and window, and validates the control's current label, role, enabled state,
supported action, or writable attribute. Operations run off the UI thread with OS
message timeouts. A timeout is treated as uncertain and followed by inspection,
not an automatic retry. Stop cancels remaining steps. A task is bounded to 32 model
steps and three minutes; completed work remains in History if more turns are needed.

Corrections such as “No, no,” “Wait,” or a replacement command interrupt remaining
actions immediately, including when a clear correction appears in the live transcript.
“Stop” pauses the task while keeping the microphone available; “Stop listening” stops
Voice Control. “Go ahead” resumes the current unfinished user task for up to ten minutes.
Read-only questions do not inherit permission to act merely because an older task did.

Repeated actions in the same observed state are blocked, including cycles that return
to an earlier state. Page loading can be checked without clicking again. Task completion
requires a separate outcome and evidence from the current view; a successful OS call
alone is recorded as dispatch, not verified navigation. History records result checks
and whether the accessible view was partial, without saving full screen inventories.

Website navigation uses complete HTTP/HTTPS URLs through the browser. It does not
spell addresses through keyboard shortcuts. Other text can be prepared for a selected
field in a Voice Control review draft, then inserted by button or a natural voice
instruction such as “Insert that.” “Insert & Enter” additionally submits it. The field
and target are rechecked before synthetic Unicode keyboard events are sent; the AX
writer never sets text values. Existing dictation behavior is unchanged.

These capabilities use the existing Accessibility grant and OpenAI API setup.
Text insertion retains the existing reviewed dictation buffer and explicit commit;
the new AX attribute writer does not insert text. Arbitrary coordinate clicking is
not part of this executor, so custom interfaces must expose accessible controls.

For cross-process checks against a disposable native test window:

```bash
build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test-accessibility
# Also tests a real model request against the fixture slider (uses the API key):
build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test-accessibility-model
```

Command-flow regression checks require no fixture windows or desktop input:

```bash
build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test-voice-flow
# Uses the configured API key, but screen state and all effects remain simulated:
build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test-voice-flow-model
```

### Voice Control history and natural requests

Use the clock/history menu in Voice Control to see the five latest transcripts.
Selecting one puts it in the command field for review; it does not run it. **Browse
saved history** opens searchable transcripts, replies, and action outcomes with copy
controls. The menu-bar app also has **Voice Control History…**. You can ask naturally,
such as “Show me what I said earlier” or “What did we decide about the browser?”

Assistant replies render common Markdown formatting in both the live panel and
saved history, including headings, bold/italic text, lists, links, and code.
Transcripts and copied replies retain their original text.

Finalized speech and typed requests are saved as soon as they are submitted. Replies,
plans, actual results, errors, and interrupted commands are recorded separately.
Recent conversation is available to the slow path after an app restart, so natural
follow-ups can refer to earlier turns. Exact command phrases are optional shortcuts:
requests such as “bring back the tab I just closed” are interpreted by the model and
dispatched through the same supported action tools.

History begins with this update; earlier unsaved conversations cannot be recovered.
The live panel's trash button resets active context while retaining saved history.
The recent view loads at most 2,000 events from a bounded archive tail; the full
append-only archive remains on disk.

Local coding assistants can read:

- `~/Library/Application Support/BtrVoice/VoiceControl/recent.md` — the latest 60 events.
- `~/Library/Application Support/BtrVoice/VoiceControl/transcripts.jsonl` — the full archive.

Both are owner-only files inside an owner-only directory. Diagnostic traces also save
bounded model requests/responses, raw Accessibility text, tool failures, and timings in
`Diagnostics/events.jsonl` (three rotating files, approximately 24 MB total). They may
contain private chat/page text; audio, images and API credentials are excluded/redacted.
The assistant receives bounded conversation
text as context and can search recent history when needed.

```bash
build/BtrVoice.app/Contents/MacOS/BtrVoice --voice-history
build/BtrVoice.app/Contents/MacOS/BtrVoice --voice-history browser
build/BtrVoice.app/Contents/MacOS/BtrVoice --voice-trace
```

### Read messages and tabs

Try “Summarize my unread Telegram messages, especially DMs” or “Summarize my browser
tabs by topic.” Bounded local Accessibility batches gather evidence, followed by one
lightweight-model summary. Opening chats may mark them read. Hidden/unsupported
content is reported as missing, not invented. “List the first five tabs” reads titles
without selecting them. Categories are in the answer; tabs are not reorganized.
See [the reading harness and diagnostics](docs/voice-control-harness.md) for limits and tests.

## iOS

The iOS app runs the listening editor while its compact custom keyboard displays the
shared draft inside apps such as Telegram. The keyboard provides microphone/stop,
Insert, Trash, Space, and Backspace controls without covering the destination text box.

```bash
cd ios
xcodegen generate
open BtrVoice.xcodeproj
```

Sign the app and keyboard extension with the same App Group, install them, then enable
**Better Voice Keyboard** and **Allow Full Access** under iOS keyboard settings.

iOS does not give custom keyboard extensions direct microphone access. Better Voice
therefore keeps the containing app's audio session active in the background and shares
only draft state and keyboard commands through the App Group. Paused audio is discarded
locally rather than sent for processing.

## OpenAI and privacy

Add your OpenAI API key in Better Voice Settings. It is stored in the platform Keychain
and is never exposed to the keyboard extension. GPT modes stream microphone audio to
OpenAI; choose Apple Speech when you prefer the available local recognition path.

## License

[MIT](LICENSE)
