import AppKit
import Foundation

/// Replays the loss-of-pending-text cases and verifies native storage mutations,
/// including overlapping utterances, Unicode, and selection through a rewrite.
enum StreamingEditorSelfTest {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { print("  ok   \(name)") }
            else { print("  FAIL \(name)"); failures += 1 }
        }
        print("Streaming editor continuity")
        let buffer = TextBuffer()
        buffer.replace(with: "Already confirmed.")
        buffer.setPartial("Words already heard")
        for preview in ["Al", "Already confirmed.", "Already confirmed. Words"] {
            buffer.setReplacementPreview(preview)
            check("a short rewrite prefix retains the entire pending speech: \(preview)",
                  buffer.displayText == "Already confirmed. Words already heard")
        }
        buffer.setReplacementPreview("Already confirmed. Words already heard and more")
        check("new output beyond the visible draft appears immediately",
              buffer.displayText == "Already confirmed. Words already heard and more")
        buffer.setReplacementPreview(nil)
        buffer.setReplacementPreview("Already")
        check("tool continuation and cleanup cannot shrink unconfirmed output",
              buffer.displayText == "Already confirmed. Words already heard and more")
        check("streaming text cannot be inserted as confirmed text",
              buffer.committedText == "Already confirmed." && buffer.hasUnconfirmedText)
        buffer.replace(with: "Already confirmed. Words already heard and more.", remainingPartial: "Next turn")
        check("confirmation retains a newer unconfirmed utterance",
              buffer.partial == "Next turn" && buffer.displayText.hasSuffix(" Next turn"))
        buffer.clear()
        check("explicit trash clears all pending display state", buffer.isEmpty && !buffer.hasUnconfirmedText)

        // Native text storage checks need AppKit initialized but create no window.
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let renderer = BufferTextView.Coordinator(onEdit: { _ in }, onAdoptAll: { _ in })
        renderer.textView = view
        renderer.update(committed: "hello", suffix: " world", revision: 1)
        let marker = NSAttributedString.Key("streaming-test-preserved")
        view.textStorage?.addAttribute(marker, value: true, range: NSRange(location: 0, length: 11))
        view.setSelectedRange(NSRange(location: 1, length: 3))
        renderer.update(committed: "hello world", suffix: "", revision: 2)
        check("confirmation recolours existing characters without replacing them",
              view.textStorage?.attribute(marker, at: 8, effectiveRange: nil) as? Bool == true)
        check("confirmation leaves the user's selection intact",
              view.selectedRange() == NSRange(location: 1, length: 3))
        renderer.update(committed: "hello world", suffix: " again", revision: 2)
        check("appending speech keeps confirmed glyph storage and selection",
              view.string == "hello world again"
              && view.textStorage?.attribute(marker, at: 8, effectiveRange: nil) as? Bool == true
              && view.selectedRange() == NSRange(location: 1, length: 3))
        check("pending text stays grey while confirmed text is white",
              view.textStorage?.attribute(.foregroundColor, at: 12, effectiveRange: nil) as? NSColor == .secondaryLabelColor
              && view.textStorage?.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .labelColor)
        renderer.update(committed: "A hello world", suffix: " again", revision: 3)
        check("a correction before the selection moves it with its original words",
              view.selectedRange() == NSRange(location: 3, length: 3))

        let examples = [
            ("Meet Monday at eight tomorrow", "Meet Tuesday at nine tomorrow"),
            ("hi 👨‍👩‍👧‍👦 café", "hi 👍🏽 café!"),
            ("café", "cafe\u{301}"), ("cafe\u{301}", "café"),
            ("hi 👍", "hi 👍🏽"), ("hi 👍🏽", "hi 👍"),
            ("", "你好"), ("abc", ""), ("abc", "abc"),
            (String(repeating: "old ", count: 2_000), String(repeating: "new ", count: 2_000)),
        ]
        for (index, pair) in examples.enumerated() {
            let mutable = NSMutableString(string: pair.0)
            let update = TranscriptTextUpdate(from: pair.0, to: pair.1)
            for edit in update.edits.reversed() {
                mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            check("incremental edits reassemble snapshot \(index) exactly",
                  (mutable as String).utf8.elementsEqual(pair.1.utf8))
        }
        let local = TranscriptTextUpdate(from: "Meet Monday at eight tomorrow", to: "Meet Tuesday at nine tomorrow")
        check("separate corrections preserve the unchanged text between them", local.edits.count > 1)
        let combining = TranscriptTextUpdate(from: "hi 👍", to: "hi 👍🏽")
        check("extending an emoji replaces its whole grapheme", combining.edits.first?.range == NSRange(location: 3, length: 2))
        let selection = TranscriptTextUpdate(from: "abcd", to: "👨‍👩‍👧‍👦")
        check("a selection inside rewritten words never splits a replacement emoji",
              selection.selection(after: NSRange(location: 2, length: 0)) == NSRange(location: 0, length: 0))
        let insertion = TranscriptTextUpdate(from: "hello world", to: "hello beautiful world")
        check("inserting at a selection boundary keeps only the original word selected",
              insertion.selection(after: NSRange(location: 6, length: 5)) == NSRange(location: 16, length: 5))

        var randomState: UInt64 = 73
        func random(_ upper: Int) -> Int {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            return Int((randomState >> 32) % UInt64(upper))
        }
        let alphabet: [Character] = ["a", "b", " ", "é", "👍🏽", "中", "\n"]
        var allReassembled = true
        for _ in 0..<150 {
            let old = String((0..<40).map { _ in alphabet[random(alphabet.count)] })
            var changed = Array(old)
            for _ in 0..<6 {
                let offset = random(changed.count)
                if random(2) == 0 { changed.remove(at: offset) }
                else { changed.insert(alphabet[random(alphabet.count)], at: offset) }
            }
            let new = String(changed)
            let mutable = NSMutableString(string: old)
            for edit in TranscriptTextUpdate(from: old, to: new).edits.reversed() {
                mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            allReassembled = allReassembled && (mutable as String).utf8.elementsEqual(new.utf8)
        }
        check("mixed Unicode insertions and deletions reconstruct 150 snapshots exactly", allReassembled)

        // Replay real engine event handling with no socket, microphone, or key use.
        let engine = OpenAIEditorEngine(seedTranscript: "")
        let staged = TextBuffer()
        engine.onPartial = { staged.setPartial($0) }
        engine.onReplacementPreview = { staged.setReplacementPreview($0) }
        engine.onEditorFinal = { staged.replace(with: $0, remainingPartial: $1) }
        func event(_ type: String, _ fields: [String: Any] = [:]) {
            var message = fields
            message["type"] = type
            let data = try! JSONSerialization.data(withJSONObject: message)
            engine.handle(String(decoding: data, as: UTF8.self), connectionGeneration: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        event("input_audio_buffer.speech_started", ["item_id": "first"])
        event("conversation.item.input_audio_transcription.delta", ["item_id": "first", "delta": "First words"])
        event("input_audio_buffer.speech_stopped", ["item_id": "first"])
        event("response.created")
        event("response.output_text.delta", ["delta": "First"])
        check("real response deltas do not erase recognized words", staged.displayText == "First words")
        event("input_audio_buffer.speech_started", ["item_id": "second"])
        event("conversation.item.input_audio_transcription.delta", ["item_id": "second", "delta": "Second words"])
        event("response.output_text.delta", ["delta": " words."])
        event("response.done", ["response": ["status": "completed"]])
        check("an older response cannot consume speech recorded during its processing",
              staged.committedText == "First words." && staged.partial == "Second words")
        event("conversation.item.input_audio_transcription.completed", ["item_id": "first", "transcript": "First words"])
        check("late transcription of confirmed audio cannot resurrect duplicate words", staged.partial == "Second words")
        event("input_audio_buffer.speech_stopped", ["item_id": "second"])
        event("response.created")
        event("response.done", ["response": ["status": "completed", "output": [["type": "function_call"]]]])
        check("a tool-only response preserves gray speech until its continuation", staged.partial == "Second words")
        event("response.created")
        event("response.output_text.delta", ["delta": "First words. Second"])
        event("response.done", ["response": ["status": "incomplete"]])
        check("an incomplete response cannot clear or confirm pending speech",
              staged.committedText == "First words." && staged.partial == "Second words")
        engine.cancel()
        return failures
    }
}
