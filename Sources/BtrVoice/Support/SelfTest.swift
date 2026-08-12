import Foundation

/// `BtrVoice --self-test` exercises the parts that don't need a microphone, a screen,
/// or TCC permission: command parsing, buffer arithmetic, and event chunking.
/// Run it after changing any of those; the injection path itself can only be verified
/// interactively, since posting key events requires Accessibility access.
enum SelfTest {

    static func run() -> Int32 {
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
            if condition() {
                print("  ok   \(name)")
            } else {
                failures += 1
                let extra = detail()
                print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            }
        }

        print("VoiceCommands")
        do {
            let actions = VoiceCommands.parse("hello world do paste goodbye", enabled: true)
            check("splits literals around a command",
                  actions == [.insert("hello world"), .pasteInTarget, .insert("goodbye")],
                  "\(actions)")
        }
        do {
            let actions = VoiceCommands.parse("hello do paste there", enabled: false)
            check("passes everything through when disabled",
                  actions == [.insert("hello do paste there")], "\(actions)")
        }
        do {
            // The recogniser punctuates and capitalises; commands must survive that.
            let actions = VoiceCommands.parse("Do paste.", enabled: true)
            check("matches despite capitalisation and punctuation",
                  actions == [.pasteInTarget], "\(actions)")
        }
        do {
            check("do paste presses ⌘V", VoiceCommands.parse("do paste", enabled: true) == [.pasteInTarget])
            check("do copy presses ⌘C", VoiceCommands.parse("do copy", enabled: true) == [.copyInTarget])
            check("do select all presses ⌘A", VoiceCommands.parse("do select all", enabled: true) == [.selectAllInTarget])
            check("do click clicks", VoiceCommands.parse("do click", enabled: true) == [.clickAtPointer])
            check("do insert commits", VoiceCommands.parse("do insert", enabled: true) == [.commit])
            check("do send it inserts and sends", VoiceCommands.parse("do send it", enabled: true) == [.commitAndSend])
            check("insert waits for finalized buffer", BufferAction.commit.requiresFinalizedBuffer)
            check("send waits for finalized buffer", BufferAction.commitAndSend.requiresFinalizedBuffer)
            check("non-insert command does not wait for buffer", !BufferAction.pasteInTarget.requiresFinalizedBuffer)
        }
        do {
            let (text, actions) = VoiceCommands.extractEditorCommands("hello world [[cmd:send]]")
            check("editor marker extracted", text == "hello world" && actions == [.commitAndSend],
                  "\(text) \(actions)")
            let (text2, actions2) = VoiceCommands.extractEditorCommands("just prose, no markers")
            check("no markers passes through", text2 == "just prose, no markers" && actions2.isEmpty)
            let (text3, actions3) = VoiceCommands.extractEditorCommands("[[cmd:paste]]")
            check("bare marker leaves empty text", text3.isEmpty && actions3 == [.pasteInTarget])
            let (text4, _) = VoiceCommands.extractEditorCommands("keep this [[unknown junk]] clean")
            check("unknown bracket junk is stripped", text4 == "keep this clean", text4)
        }
        do {
            let combo = TextInjector.parseCombo("cmd+shift+p")
            check("cmd+shift+p parses", combo?.key == 35 && combo?.display == "⇧⌘P",
                  "\(String(describing: combo))")
            check("bare key parses", TextInjector.parseCombo("escape")?.display == "Escape")
            check("space separators work", TextInjector.parseCombo("ctrl c")?.display == "⌃C")
            check("unknown key rejected", TextInjector.parseCombo("cmd+banana") == nil)
            check("two plain keys rejected", TextInjector.parseCombo("a+b") == nil)
            check("modifier only rejected", TextInjector.parseCombo("cmd+shift") == nil)
        }
        do {
            check("command words without the trigger stay literal",
                  VoiceCommands.parse("please paste the text", enabled: true)
                  == [.insert("please paste the text")])
            check("bare trigger stays literal",
                  VoiceCommands.parse("what should I do", enabled: true)
                  == [.insert("what should I do")])
            check("trigger followed by a non-command stays literal",
                  VoiceCommands.parse("do the dishes", enabled: true)
                  == [.insert("do the dishes")])
        }
        do {
            let actions = VoiceCommands.parse("", enabled: true)
            check("empty input yields nothing", actions.isEmpty, "\(actions)")
        }

        print("Jarvis")
        do {
            let bundle = URL(fileURLWithPath: "/Users/example/btr_voice/build/BtrVoice.app")
            let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            let expected = "/Users/example/jarvis/plugins/jarvis/voice/__main__.py"
            let plugins = JarvisVoiceInstallation.findPlugins(
                environment: [:], bundleURL: bundle, homeDirectory: home,
                fileExists: { $0 == expected }
            )
            check("Start Jarvis finds a sibling voice provider",
                  plugins?.path == "/Users/example/jarvis/plugins", plugins?.path ?? "nil")

            let configured = JarvisVoiceInstallation.findPlugins(
                environment: ["JARVIS_PLUGIN_DIR": "/opt/jarvis/plugins"],
                bundleURL: bundle, homeDirectory: home,
                fileExists: { $0 == "/opt/jarvis/plugins/jarvis/voice/__main__.py" }
            )
            check("Start Jarvis honors an explicit plugin directory",
                  configured?.path == "/opt/jarvis/plugins", configured?.path ?? "nil")
        }
        do {
            let plugins = URL(fileURLWithPath: "/opt/jarvis/plugins", isDirectory: true)
            let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
            let python = JarvisVoiceInstallation.findPython(
                environment: [:], pluginsDirectory: plugins, homeDirectory: home,
                isExecutable: { $0 == "/opt/jarvis/plugins/.venv/bin/python" }
            )
            check("Start Jarvis prefers its project Python",
                  python?.path == "/opt/jarvis/plugins/.venv/bin/python", python?.path ?? "nil")
        }
        do {
            check("jarvis gets the whole utterance verbatim",
                  VoiceCommands.parse("Hey Jarvis, clean this up", enabled: true)
                  == [.jarvis("Hey Jarvis, clean this up")])
            check("text before the wake word is part of the utterance",
                  VoiceCommands.parse("hello world jarvis fix the last sentence", enabled: true)
                  == [.jarvis("hello world jarvis fix the last sentence")])
            check("bare jarvis with nothing after it stays literal",
                  VoiceCommands.parse("Jarvis.", enabled: true) == [.insert("Jarvis.")])
            check("jarvis utterance keeps command words verbatim",
                  VoiceCommands.parse("jarvis remember do paste means control v", enabled: true)
                  == [.jarvis("jarvis remember do paste means control v")])
        }
        do {
            check("remember is classified as a note",
                  JarvisEngine.classify("Hey Jarvis, remember that github dot com means tch1001.github.io")
                  == .remember("github dot com means tch1001.github.io"))
            check("remember drops the filler word to",
                  JarvisEngine.classify("jarvis remember to spell my name as Fish")
                  == .remember("spell my name as Fish"))
            check("everything else is an edit with the full utterance",
                  JarvisEngine.classify("Jarvis, replace github dot com with the real URL")
                  == .edit("Jarvis, replace github dot com with the real URL"))
        }
        do {
            check("sanitize strips echoed tags and newlines",
                  JarvisEngine.sanitize("<text>\nhello\nworld\n</text>") == "hello world")
            check("sanitize collapses whitespace runs",
                  JarvisEngine.sanitize("  a   b\t\tc \n d ") == "a b c d")
            check("sanitize keeps math comparisons intact",
                  JarvisEngine.sanitize("x < 3 and y > 5") == "x < 3 and y > 5")
            check("sanitize leaves clean text alone",
                  JarvisEngine.sanitize("already clean") == "already clean")
        }
        do {
            // Assistant chatter would otherwise be typed as if the user said it.
            check("polish strips an acknowledgement preamble",
                  JarvisEngine.sanitize("Sure, here's the edited text: meet me at six")
                  == "meet me at six")
            check("polish strips a first-person preamble",
                  JarvisEngine.sanitize("I've updated the transcript: meet me at six")
                  == "meet me at six")
            check("polish strips a trailing offer of help",
                  JarvisEngine.sanitize("meet me at six. Let me know if you'd like changes.")
                  == "meet me at six.")
            check("polish strips code fences",
                  JarvisEngine.sanitize("```text meet me at six ```") == "meet me at six")
            check("polish unwraps a fully quoted reply",
                  JarvisEngine.sanitize("\"meet me at six\"") == "meet me at six")

            // Conservative by design: dictated speech that merely resembles
            // preamble must survive untouched.
            check("polish keeps a dictated colon sentence",
                  JarvisEngine.sanitize("shopping list: eggs and milk")
                  == "shopping list: eggs and milk")
            check("polish keeps a dictated Sure opener",
                  JarvisEngine.sanitize("Sure, I'll be there at six")
                  == "Sure, I'll be there at six")
            check("polish keeps inner quotes",
                  JarvisEngine.sanitize("he said \"yes\" and left")
                  == "he said \"yes\" and left")
            check("polish never strips the reply to nothing",
                  JarvisEngine.sanitize("Here's the edited text:")
                  == "Here's the edited text:")

            // Regression: an offer-shaped phrase mid-sentence is the user's own
            // speech and must survive. This once truncated dictation to its head.
            check("polish keeps a dictated feel-free clause",
                  JarvisEngine.sanitize("For BtrVoice, feel free to add a setting for this")
                  == "For BtrVoice, feel free to add a setting for this")
            check("polish keeps a dictated let-me-know clause",
                  JarvisEngine.sanitize("Ask him and let me know if he agrees")
                  == "Ask him and let me know if he agrees")
            check("polish keeps a dictated would-you-like clause",
                  JarvisEngine.sanitize("Tell me would you like me to come along")
                  == "Tell me would you like me to come along")
            check("polish still strips a sign-off after a full stop",
                  JarvisEngine.sanitize("Meet me at six. Let me know if that works.")
                  == "Meet me at six.")
        }
        do {
            // Extras cost a ⌘C or expose the clipboard, so they are opt-in per
            // utterance rather than gathered every time.
            check("selection is requested by highlight wording",
                  JarvisEngine.wants(.selection, in: "Jarvis, summarise what I highlighted"))
            check("selection is requested by selected wording",
                  JarvisEngine.wants(.selection, in: "Jarvis, translate the selected text"))
            check("clipboard is requested by clipboard wording",
                  JarvisEngine.wants(.clipboard, in: "Jarvis, paste in what's on my clipboard"))
            check("a plain edit asks for neither",
                  !JarvisEngine.wants(.selection, in: "Jarvis, make that more formal")
                  && !JarvisEngine.wants(.clipboard, in: "Jarvis, make that more formal"))
        }

        print("TextBuffer")
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Hello there.")])
            buffer.apply([.insert("How are you?")])
            check("inserts a separating space",
                  buffer.committedText == "Hello there. How are you?", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Line one"), .insert("\n"), .insert("Line two")])
            check("no space around newlines",
                  buffer.committedText == "Line one\nLine two", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Wait")])
            buffer.apply([.insert(", actually")])
            check("no space before punctuation",
                  buffer.committedText == "Wait, actually", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("alpha beta gamma")])
            buffer.deleteLastWord()
            check("delete word drops one word",
                  buffer.committedText == "alpha beta ", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("something")])
            buffer.clear()
            check("clear empties the buffer", buffer.committedText.isEmpty)
            buffer.undo()
            check("undo restores the cleared text",
                  buffer.committedText == "something", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Committed.")])
            buffer.setPartial("in flight")
            check("display text includes the live partial",
                  buffer.displayText == "Committed. in flight", buffer.displayText)
            check("committed text excludes the live partial",
                  buffer.committedText == "Committed.", buffer.committedText)
            let escalated = buffer.apply([.pasteInTarget])
            check("commands are escalated to the controller", escalated == [.pasteInTarget], "\(escalated)")
            check("finalising clears the partial", buffer.partial.isEmpty)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("confirmed words")])
            buffer.setPartial("still in flight")
            buffer.clearCommitted()
            check("clearCommitted drops confirmed text only",
                  buffer.committedText.isEmpty && buffer.partial == "still in flight",
                  "\(buffer.committedText.debugDescription) / \(buffer.partial)")
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("hi 👍🏽")])
            buffer.deleteLastCharacter()
            check("backspace removes a whole emoji", buffer.committedText == "hi ", buffer.committedText.debugDescription)
            buffer.deleteLastCharacter()
            buffer.deleteLastCharacter()
            buffer.deleteLastCharacter()
            check("backspace stops at empty", buffer.committedText.isEmpty)
            buffer.deleteLastCharacter() // must not crash on empty
            buffer.undo()
            check("backspace is undoable", buffer.committedText == "h", buffer.committedText)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("alpha beta")])
            buffer.deleteLastWord()
            check("backspace ⌥ variant drops the last word",
                  buffer.committedText == "alpha ", buffer.committedText.debugDescription)
        }
        do {
            let buffer = TextBuffer()
            buffer.apply([.insert("Already committed.")])
            buffer.setPartial("still in flight")
            buffer.flushPartial()
            check("flushPartial promotes the live tail",
                  buffer.committedText == "Already committed. still in flight", buffer.committedText)
            check("flushPartial empties the partial", buffer.partial.isEmpty)
            buffer.flushPartial()
            check("flushPartial is a no-op when there is no partial",
                  buffer.committedText == "Already committed. still in flight")
        }
        do {
            let buffer = TextBuffer()
            buffer.setPartial("visible unfinished words")
            buffer.finalizePendingRecognition()
            check("commit fallback promotes visible partial",
                  buffer.committedText == "visible unfinished words" && buffer.partial.isEmpty,
                  buffer.displayText)
        }
        do {
            let buffer = TextBuffer()
            buffer.setPartial("raw speech")
            buffer.setReplacementPreview("the editor's finished rewrite")
            buffer.finalizePendingRecognition()
            check("commit fallback prefers editor preview",
                  buffer.committedText == "the editor's finished rewrite"
                      && buffer.partial.isEmpty
                      && buffer.replacementPreview == nil,
                  buffer.displayText)
        }
        do {
            let buffer = TextBuffer()
            let before = buffer.revision
            buffer.apply([.insert("speech")])
            check("speech bumps the revision", buffer.revision > before)
            let afterSpeech = buffer.revision
            buffer.userDidEdit("typed by hand")
            check("user edits do not bump the revision", buffer.revision == afterSpeech)
            check("user edits are kept", buffer.committedText == "typed by hand")
        }

        print("TextInjector.chunked")
        do {
            let line = String(repeating: "abcde ", count: 12)
            let chunks = TextInjector.chunked(line)
            check("chunks reassemble losslessly", chunks.joined() == line)
            check("every chunk fits the payload limit",
                  chunks.allSatisfy { $0.utf16.count <= 16 },
                  "\(chunks.map { $0.utf16.count })")
        }
        do {
            // Surrogate pairs and ZWJ sequences must never be cut in half.
            let line = "ok 👍🏽 done 👨‍👩‍👧‍👦 end 🇯🇵"
            let chunks = TextInjector.chunked(line)
            check("emoji survive chunking", chunks.joined() == line, chunks.joined())
            check("no chunk is empty", chunks.allSatisfy { !$0.isEmpty })
        }
        do {
            check("empty line yields no chunks", TextInjector.chunked("").isEmpty)
        }

        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) self-test(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
