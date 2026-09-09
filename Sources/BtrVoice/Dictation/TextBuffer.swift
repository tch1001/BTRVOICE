import Foundation

/// The staging area. Recognised speech lands here and *stays* here — nothing is
/// pushed to the focused application until the user commits. This is the whole
/// reason BtrVoice works in Terminal, Telegram, or any other app whose text views
/// Apple's dictation refuses to touch.
final class TextBuffer: ObservableObject {

    /// Committed, user-editable text.
    @Published private(set) var text: String = ""
    /// Live in-flight recognition for the current segment, shown greyed out.
    @Published private(set) var partial: String = ""
    /// Incoming editor prefix. Repeated prefixes must not erase words that the
    /// response has not reached yet; destructive edits wait for the final result.
    @Published private(set) var replacementPreview: String?
    /// Bumped whenever `text` changes from *our* side, so the editor knows to reload
    /// without fighting the user's cursor on every keystroke.
    @Published private(set) var revision: Int = 0

    private var undoStack: [String] = []
    private let undoLimit = 25

    var isEmpty: Bool { displayText.isEmpty }

    /// What would be typed if the user committed right now.
    var committedText: String { text }

    /// Recognition that is still represented by the grey UI and therefore must
    /// never satisfy a pending Insert/Send request.
    var hasUnconfirmedText: Bool {
        !partial.isEmpty || replacementPreview != nil
    }

    /// Everything the user can see, live tail included.
    var displayText: String {
        let current = partial.isEmpty ? text : joined(text, partial)
        // A full-transcript response starts by repeating the existing text. Keep
        // that text on screen until the prefix catches up. Extensions can be shown
        // immediately; ambiguous corrections stay pending until the complete
        // replacement arrives, so an unfinished prefix never looks like deletion.
        if let preview = replacementPreview, preview.hasPrefix(current) {
            return preview
        }
        return current
    }

    /// What follows the confirmed prefix in the editor, including model output
    /// received before input transcription. It stays grey until confirmation.
    var displayedUnconfirmedSuffix: String {
        String(displayText.dropFirst(text.count))
    }

    // MARK: - Speech input

    func setPartial(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != partial else { return }
        partial = trimmed
    }

    func setReplacementPreview(_ value: String?) {
        // A transport cleanup is not confirmation. Retain the last visible prefix
        // through tool-only replies, cancellation and timeouts. Explicit buffer
        // clear/adoption/finalization owns its removal.
        guard let value, !value.isEmpty else { return }
        let visible = displayText
        let next = value.hasPrefix(visible) ? value : (replacementPreview ?? "")
        guard next != replacementPreview else { return }
        replacementPreview = next
    }

    /// Applies a finalised segment. Returns any actions the buffer can't perform
    /// itself (commit / commit-and-send) for the controller to handle.
    @discardableResult
    func apply(_ actions: [BufferAction]) -> [BufferAction] {
        var escalated: [BufferAction] = []
        var changed = false

        for action in actions {
            switch action {
            case .insert(let fragment):
                pushUndo()
                text = joined(text, fragment)
                changed = true
            case .pasteInTarget, .copyInTarget, .selectAllInTarget, .clickAtPointer,
                 .jumpToReferences, .commit, .commitAndSend, .jarvis, .pressKeys:
                escalated.append(action)
            }
        }

        partial = ""
        if changed { revision += 1 }
        return escalated
    }

    // MARK: - User editing

    /// Called by the editor when the user types. Deliberately does not bump
    /// `revision` — the view is already showing this exact string.
    func userDidEdit(_ value: String) {
        guard value != text else { return }
        text = value
    }

    /// The user edited *inside* the grey in-flight region: everything on screen
    /// becomes theirs, and the partial is dropped (the controller discards the
    /// utterance in the engine at the same time). No revision bump — the view is
    /// already showing exactly this.
    func adoptDisplayedText(_ value: String) {
        text = value
        partial = ""
        replacementPreview = nil
    }

    /// One press of the backspace button. Whole grapheme clusters at a time, so an
    /// emoji disappears in one press instead of decomposing into broken scalars.
    func deleteLastCharacter() {
        guard !text.isEmpty else { return }
        pushUndo()
        text.removeLast()
        revision += 1
    }

    /// The button's ⌥-click variant — same behaviour as saying "scratch word".
    func deleteLastWord() {
        guard !text.isEmpty else { return }
        pushUndo()
        text = Self.droppingLastWord(from: text)
        revision += 1
    }

    /// Promotes the in-flight partial to committed text. Used when a commit is wanted
    /// but recognition never delivered a final result — the words are on screen, so
    /// the user is entitled to them.
    func flushPartial() {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushUndo()
        text = joined(text, trimmed)
        partial = ""
        revision += 1
    }

    func replace(with value: String, remainingPartial: String = "") {
        if text != value {
            pushUndo()
            text = value
        }
        partial = remainingPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        replacementPreview = nil
        revision += 1
    }

    func clear() {
        guard !isEmpty || replacementPreview != nil else { return }
        pushUndo()
        text = ""
        partial = ""
        replacementPreview = nil
        revision += 1
    }

    /// Drops the committed text but keeps the live grey tail — used after an
    /// insert, which only types confirmed text.
    func clearCommitted() {
        guard !text.isEmpty else { return }
        pushUndo()
        text = ""
        revision += 1
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        text = previous
        partial = ""
        replacementPreview = nil
        revision += 1
    }

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(text)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
    }

    // MARK: - Joining

    /// Concatenation with the spacing a human would use: no space after a newline,
    /// none before closing punctuation, one everywhere else.
    private func joined(_ lhs: String, _ rhs: String) -> String {
        guard !rhs.isEmpty else { return lhs }
        guard let last = lhs.last else { return rhs }
        if last.isWhitespace || last.isNewline { return lhs + rhs }
        guard let first = rhs.first else { return lhs }
        if first.isNewline || first == "\t" { return lhs + rhs }
        if ",.;:!?)]}»".contains(first) { return lhs + rhs }
        return lhs + " " + rhs
    }

    private static func droppingLastWord(from value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return "" }
        guard let cut = trimmed.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return "" }
        return String(trimmed[trimmed.startIndex...cut])
    }
}
