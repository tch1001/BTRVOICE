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
            check("do send it clicks", VoiceCommands.parse("do send it", enabled: true) == [.clickAtPointer])
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
