import Foundation

/// What a finalised segment asks the buffer to do.
enum BufferAction: Equatable {
    case insert(String)
    /// "paste" — press ⌘V in the focused app.
    case pasteInTarget
    /// "copy" — press ⌘C in the focused app.
    case copyInTarget
    /// "send it" — left-click at the current pointer position.
    case clickAtPointer
}

/// Turns spoken control phrases inside a transcript into buffer actions, so the
/// user never has to reach for the keyboard mid-thought.
enum VoiceCommands {

    /// Phrase (already lowercased, punctuation-stripped) → action.
    private static let table: [[String]: BufferAction] = [
        ["paste"]: .pasteInTarget,
        ["copy"]: .copyInTarget,
        ["click"]: .clickAtPointer,
        ["send", "it"]: .clickAtPointer,
    ]

    private static let maxPhraseLength = 2

    /// Splits `segment` into literal text and commands, preserving order.
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
            // Longest phrase wins, so "send it" beats a hypothetical "send".
            var length = min(maxPhraseLength, words.count - index)
            while length >= 1 {
                let slice = words[index..<(index + length)].map(normalise)
                if let action = table[slice] {
                    // Trailing punctuation on the last spoken word ("new line.") is a
                    // recogniser artefact and is dropped with the command.
                    flushLiteral()
                    actions.append(action)
                    index += length
                    matched = true
                    break
                }
                length -= 1
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
