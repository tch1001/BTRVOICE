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
