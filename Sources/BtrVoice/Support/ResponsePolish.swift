import Foundation

/// Strips the tells of an LLM reply from text that is supposed to be *only* the
/// user's dictated words.
///
/// The prompts already say "return the transcript and nothing else", and models
/// mostly obey — but "Sure, here's the edited text: …" still slips through, and
/// when it does it gets typed into a chat window as if the user had said it.
/// Prompting is the first line of defence; this is the second.
///
/// Everything here is deliberately conservative. Dictated speech can legitimately
/// begin with "Sure," or contain a colon, so a rule only fires when the leading
/// clause is *both* addressed-to-the-user in shape (an acknowledgement, "here
/// is…", "I've…") *and* refers to the artefact itself (text, transcript, edit,
/// version…). A sentence the user actually dictated will essentially never be
/// both at once.
enum ResponsePolish {

    /// Words a model opens with when it is talking *to* the user rather than
    /// producing their text.
    private static let acknowledgements = [
        "sure", "certainly", "of course", "absolutely", "got it", "okay", "ok",
        "alright", "no problem", "understood", "here you go", "happy to help",
    ]

    /// Nouns that mean the model is describing its own output.
    private static let metaNouns = [
        "text", "transcript", "version", "edit", "edited", "edits", "rewrite",
        "rewritten", "revised", "revision", "update", "updated", "correction",
        "corrected", "buffer", "message", "draft", "result", "requested",
        "changes", "cleaned", "polished",
    ]

    /// Shapes that mean the clause is addressed to the user.
    private static let addressedForms = [
        "here'", "here is", "here are", "i've", "i have", "this is", "below is",
        "the following", "as requested",
    ]

    /// Removes assistant preamble, trailing offers of further help, code fences
    /// and whole-string quoting. Expects (and returns) a single line.
    static func strip(_ raw: String) -> String {
        var text = stripCodeFences(raw)
        text = stripLeadingPreamble(text)
        text = stripTrailingOffer(text)
        text = unwrapQuotes(text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// ```text … ``` — never something a person dictated.
    private static func stripCodeFences(_ text: String) -> String {
        text.replacingOccurrences(
            of: "```[a-zA-Z0-9_-]*", with: " ", options: .regularExpression
        )
    }

    /// Drops a leading "Sure, here's the edited text:" style clause.
    ///
    /// The clause must end at a colon, sit within the first 100 characters, carry
    /// no sentence-ending punctuation of its own, name the artefact, and read as
    /// addressed to the user. It also must not be the entire string — "note:" on
    /// its own line is the user's content, not a preamble.
    private static func stripLeadingPreamble(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return text }
        let lead = String(trimmed[trimmed.startIndex..<colon])
        guard lead.count <= 100, !lead.isEmpty else { return text }

        // A colon inside a real sentence ("I said: stop") comes after prose that
        // ends sentences; a preamble clause never does.
        guard lead.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) == nil else { return text }

        let lowered = lead.lowercased()
        let namesArtefact = metaNouns.contains { lowered.containsWord($0) }
        let isAddressed = addressedForms.contains { lowered.contains($0) }
            || acknowledgements.contains { lowered.hasPrefix($0) }
        guard namesArtefact, isAddressed else { return text }

        let rest = trimmed[trimmed.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        // Never strip everything: if the preamble was the whole reply, the reply
        // is all we have and mangling it helps nobody.
        return rest.isEmpty ? text : rest
    }

    /// "Let me know if you'd like anything changed." and friends, at the end.
    ///
    /// The offer must be its **own sentence** — preceded by `.`, `!` or `?` — not
    /// merely a phrase that happens to run to the end of the buffer. Without that
    /// requirement this ate dictated speech: "For BtrVoice, feel free to add X"
    /// became "For BtrVoice,". A model's sign-off always follows a finished
    /// sentence; a user's clause mid-thought does not.
    private static func stripTrailingOffer(_ text: String) -> String {
        let patterns = [
            "let me know if[^.!?]*[.!?]?",
            "hope (this|that) helps[.!?]?",
            "would you like me to[^.!?]*\\??",
            "feel free to (ask|let me know|reach out)[^.!?]*[.!?]?",
        ]
        var result = text
        for pattern in patterns {
            let stripped = result.replacingOccurrences(
                of: "(?<=[.!?])\\s+" + pattern + "\\s*$",
                with: "", options: [.regularExpression, .caseInsensitive]
            )
            // Same guard as above — a reply that is *only* the offer stays put.
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty { result = stripped }
        }
        return result
    }

    /// Models like to quote the answer back. Only unwraps when the quotes wrap
    /// the whole string, so dialogue the user dictated keeps its quoting.
    private static func unwrapQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        for (open, close) in pairs where trimmed.count >= 2
            && trimmed.first == open && trimmed.last == close {
            let inner = String(trimmed.dropFirst().dropLast())
            // "he said "yes" and left" — inner quotes mean this isn't a wrapper.
            guard !inner.contains(open), !inner.contains(close) else { continue }
            return inner
        }
        return trimmed
    }
}

private extension String {
    /// Substring match with word boundaries, so "edit" doesn't fire on "credit".
    func containsWord(_ word: String) -> Bool {
        range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b",
              options: [.regularExpression]) != nil
    }
}
