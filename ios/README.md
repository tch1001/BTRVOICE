# Better Voice for iOS

The iOS port keeps the Mac app's core value proposition in the containing app and uses
a deliberately small keyboard extension only for handoff.

## Listening and editing

The app offers three engines:

- **Listening Editor** uses `gpt-realtime-2.1` with `gpt-realtime-whisper` for its raw
  heard feed, matching the Mac engine. Each response is the complete current draft, so
  spoken corrections and editing requests revise the buffer instead of being transcribed
  literally.
- **GPT Transcript** uses `gpt-live-transcribe` for low-latency literal transcription.
- **Apple Local** uses Speech framework as a no-key fallback.

An OpenAI API key can be entered under the gear button. It is stored in the iOS Keychain
with `ThisDeviceOnly` protection and is not shared with the keyboard extension.

Standing rules use the same pattern as the Mac app: numbered, versioned JSON rules are
included in new editor sessions. The model can invoke `remember_rule` and `update_rule`,
and the Settings UI can add, edit, inspect, or delete them.

## Compact keyboard

The extension is about 139 points high and has no QWERTY rows. It contains:

- a scrollable text area with the edited draft and gray raw-heard text;
- **Listen/Pause** for the active background session;
- **Insert**, which inserts the edited draft, clears it, and pauses processing;
- **Trash**, which clears the current shared draft without pausing listening;
- **Space**, which inserts a space into the active document; and
- **Backspace**, which deletes from the active document.

The controls appear in exactly that order from left to right and use icons only. The
extension declares its own dictation control so iOS disables the separate system
dictation key when Better Voice is active.

iOS does not give custom keyboard extensions microphone access, even with Full Access.
Recording therefore stays in the containing app. Start a Listening Editor session once,
then switch to Telegram: the app continues its active recording session using the audio
background mode and publishes the edited draft, raw heard text, and processing state to
the shared App Group. The keyboard sends Listen/Pause/finish commands back through the
same App Group. While paused, the microphone session remains armed so iOS can keep the
app alive, but audio buffers are discarded locally and are not sent to GPT. Text is
inserted only after an explicit **Insert** tap.

## Build

```bash
cd /Users/fish/btr_voice/ios
xcodegen generate
xcodebuild -project BtrVoice.xcodeproj -scheme BtrVoice \
  -destination 'generic/platform=iOS' build
```

The project uses automatic signing for team `R4JXK6ZVPU`. Bundle IDs and the App Group
are declared in `project.yml` and the two entitlement files.

## Enable the keyboard on a device

Open **Settings › General › Keyboard › Keyboards › Add New Keyboard**, choose **Better
Voice Keyboard**, then enable **Allow Full Access**. Third-party keyboards do not appear
in secure password fields, phone-pad fields, or apps that explicitly reject custom
keyboards.
