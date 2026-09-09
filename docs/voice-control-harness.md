# Voice Control reading harness

The existing `gpt-5.6-luna` planner remains in use. Familiar app/shortcut commands run
locally; explicit tab/unread-chat requests can skip planning, collect native evidence,
then use one tool-free model call to summarize. Plain lists return locally with zero
model calls. Other requests retain the validated
action → fresh observation → next decision loop. This is not a general desktop cache:
process-bound snapshots are fresh, and element IDs expire with their snapshot.

## Reading operations

- “List the first five tabs”: exposed tab titles, no tab selection.
- “Summarize my browser tabs by topic”: page evidence where available; titles otherwise.
- “Check unread Telegram messages”: exposed unread chat rows/list previews.
- “Summarize my unread Telegram messages, especially DMs”: prioritize explicitly
  identified DMs; select readable conversations and summarize their exposed content.

`collect_reading` takes `kind` (`browser_tabs` or `unread_messages`), `application`,
`limit` (1–30), and `include_content`. Common explicit phrases have a local accelerator;
ambiguous requests use the model. Default local inventory limit is 30. Content reads
open at most eight items and have a 20-second batch budget. Tab enumeration walks up
to 20 exposed windows, skipping page subtrees; each AX read is bounded to 500 nodes,
32,000 text characters, and roughly two seconds plus any in-flight OS call.

The collector uses native tab/row selection only. It never types, sends, deletes,
archives, follows page instructions, or reorganizes browser tabs. Opening a chat may
mark it read. Preview-only collection does not select chats. Batches stop on focus
changes, cancellation, or uncertain selection; they retain remaining previews.

Content requires the selected source to be identifiable and two stable content reads.
After changing selection, unchanged previous content is not attributed to the new
source. This reduces asynchronous loading races; it cannot make an app's AX tree
transactional. Apps with weak selection/content semantics return previews only.

Coverage is deliberately explicit: virtualized/hidden rows, overflow tabs, background
window contents, and unlabeled chat panes may not be available. An empty inventory
does **not** mean zero unread messages. Names alone do not prove a DM. Chat summaries
may include surrounding visible conversation, not just unread messages; unread badge
counts are not chat counts. Topic categories are textual, not mutations of tab groups.

Telegram Desktop (`com.tdesktop.Telegram`) exposes English chat/folder lists as
`AXStaticText`, not rows/buttons. The adapter recognizes incoming “N new messages”
in **Chats**; it excludes **Folders** badges and outgoing “Not seen” receipts.
Group/channel prefixes classify those chats, while untyped chats remain unknown.
Localized labels and versions with different AX structures may still be unsupported.
Where Telegram omits selected-chat evidence, summaries use labeled list previews.

For an explicitly requested Telegram folder lacking `AXPress`, the inventory can
offer `BtrClick`: one synthetic mouse click at its native AX frame, not model-supplied
coordinates. Live app/list identity, unchanged geometry, window bounds, and a
system-wide topmost hit test must all agree. Held modifiers/buttons reject the click.
Covered or moved controls are not clicked; posted clicks require fresh observation
before claiming success. A simple “click the Unread folder” request is pinned to that
folder so a failed attempt cannot turn into an unrelated chat press.

## Reliability and latency

- Incomplete Responses API output never executes. Token-budget exhaustion retries
  the same request once with a larger bounded budget; other incomplete statuses stop.
- Malformed calls receive matching no-action tool feedback. Retries, steps and overall
  time are bounded; completed tool-call/result pairs remain in continuation context.
- Same-app stale handles prompt a fresh read and a new decision, not a blind replay.
  Switching foreground apps pauses actions rather than retargeting them.
- Screenshots are lazy and discarded if focus changes during capture. Structured
  read-only questions do not gain action permissions from page text.
- An initially empty lazy AX inventory gets one local read-only retry after 100 ms.
  Populated inventories do not pay this delay.
- The bounded live conversation uses eager layout and deferred, unanimated scroll
  updates. Removing gray partial text on Stop must not trigger lazy-stack relayout
  loops. Retired transcription callbacks cannot alter stopped/restarted sessions.
- AX batch error/null slots are treated as absent attributes, and native value types
  are checked before decoding ranges or geometry.
- No model upgrade or extra speech service is required. There is no sub-second
  guarantee for cloud summaries or multi-page collection: measure the phases below.

The incomplete-response check follows the official [Responses API contract](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).

## Observability

Open **Voice Control History → Diagnostics**, or read:

```text
~/Library/Application Support/BtrVoice/VoiceControl/recent.md
~/Library/Application Support/BtrVoice/VoiceControl/Diagnostics/events.jsonl
```

```bash
build/BtrVoice.app/Contents/MacOS/BtrVoice --voice-trace [turn-id]
```

Schema version 1 records `event`, Unix `at`, `session_id`, `turn_id`, `span_id`, and
extensible `fields`. Start with `conversation.failure`, then follow the turn's
`model.request`/`model.response` (HTTP status, request ID, raw JSON, usage, duration),
`tool.rejected`, `ui.snapshot`/`ax.read`, `ui.action_*`, `ui.stale_recovery`, and
`collection.*`. `turn.finished.duration_ms` measures queue-entry-to-completion;
`turn.received.at` and `turn.finished.at` also expose the boundaries. Neither includes
speech recognition/endpointing time. Model spans isolate network/model latency; AX spans
isolate desktop latency. A snapshot is bounded raw semantic text, not a full AX dump.

`listening.stop_requested` / `listening.stopped` bracket microphone teardown.
An independent run-loop watchdog records `ui.unresponsive` after a three-second
missed heartbeat and `ui.responsive_again` on recovery. It reports once per stall,
never kills the app, and records neither screen contents nor audio. A hang can
therefore leave evidence even without a macOS crash report.

The asynchronous diagnostic writer keeps disk work off the interaction thread.
Files rotate at 8 MB, retaining two previous files. Individual events over 256 KB
are explicitly clipped. Correlation lasts within retained files; this is not an
unlimited replay archive. An abrupt process kill may lose recently queued diagnostics.

Directories are owner-only (0700), files owner-only (0600). No HTTP authorization
headers, audio or screenshot bytes enter diagnostic payloads; known credential fields
and token patterns are redacted, including JSON-string arguments. Page/chat text is
still private, and pattern redaction cannot recognize every secret a person writes.
Review before sharing. Never commit these logs. The readable conversation archive is
separate and append-only; clearing the live panel does not erase it or diagnostics.

## Regression checks

```bash
swift build
.build/debug/BtrVoice --self-test
.build/debug/BtrVoice --self-test-voice-flow
.build/debug/BtrVoice --self-test-reading
.build/debug/BtrVoice --self-test-voice-panel
# Optional: uses the saved key, synthetic evidence only; incurs a small API charge.
.build/debug/BtrVoice --self-test-reading-model
# Signed bundle: disposable cross-process native fixture, never personal apps.
build/BtrVoice.app/Contents/MacOS/BtrVoice --self-test-accessibility
```

Tests cover incomplete/malformed calls, stale recovery, strict collection arguments,
DM evidence, source-selection races, preview-only reads, focus loss, bounded retry,
credential/media redaction, retention, and one-batch/one-summary orchestration.
Fixtures are not a compatibility certification for Telegram, Slack, or every browser.
The panel replay opens only a synthetic non-activating overlay, exercises long
Markdown/partial/Stop/resize transitions, and has an independent timeout. Native
fixtures also verify a static-text click without AXPress and reject moved geometry.
