import Foundation

/// What a finalised segment asks the buffer to do.
enum BufferAction: Equatable {
    case insert(String)
    /// "do paste" — press ⌘V in the focused app.
    case pasteInTarget
    /// "do copy" — press ⌘C in the focused app.
    case copyInTarget
    /// "do select all" — press ⌘A in the focused app.
    case selectAllInTarget
    /// "do send it" / "do click" — left-click at the current pointer position.
    case clickAtPointer
}

/// Turns spoken control phrases into buffer actions, so the user never has to
/// reach for the keyboard mid-thought.
enum VoiceCommands {

    /// The keyword that arms a command. Anything not prefixed with it is just words,
    /// so ordinary sentences containing "paste" or "copy" transcribe untouched.
    private static let trigger = "do"

    /// Phrase after the trigger (already lowercased, punctuation-stripped) → action.
    private static let table: [[String]: BufferAction] = [
        ["paste"]: .pasteInTarget,
        ["copy"]: .copyInTarget,
        ["select", "all"]: .selectAllInTarget,
        ["click"]: .clickAtPointer,
        ["send", "it"]: .clickAtPointer,
    ]

    private static let maxPhraseLength = 2

    /// Splits `segment` into literal text and commands, preserving order. A command
    /// is the trigger word followed by a known phrase — "do paste" anywhere in the
    /// utterance fires; a bare "do" (or "paste" without "do") stays literal.
    /// With `enabled == false` the whole segment is one literal insert.
    static func parse(_ segment: String, enabled: Bool) -> [BufferAction] {
        guard enabled else {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.insert(trimmed)]
        }

        let words = segment.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var actions: [BufferAction] = []
        var literal: [String] = []

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            actions.append(.insert(literal.joined(separator: " ")))
            literal.removeAll()
        }

        var index = 0
        while index < words.count {
            var matched = false
            if normalise(words[index]) == trigger {
                // Longest phrase wins, so "do send it" beats a hypothetical "do send".
                var length = min(maxPhraseLength, words.count - index - 1)
                while length >= 1 {
                    let slice = words[(index + 1)..<(index + 1 + length)].map(normalise)
                    if let action = table[slice] {
                        // Trailing punctuation on the last spoken word ("do paste.")
                        // is a recogniser artefact and is dropped with the command.
                        flushLiteral()
                        actions.append(action)
                        index += 1 + length
                        matched = true
                        break
                    }
                    length -= 1
                }
            }
            if !matched {
                literal.append(words[index])
                index += 1
            }
        }
        flushLiteral()
        return actions
    }

    private static func normalise(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'’“”()"))
    }
}
