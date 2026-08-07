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
    /// Editor-mode streaming: the incoming full-transcript rewrite, shown in
    /// place of everything while it streams. Nil outside editor responses.
    @Published private(set) var replacementPreview: String?
    /// Bumped whenever `text` changes from *our* side, so the editor knows to reload
    /// without fighting the user's cursor on every keystroke.
    @Published private(set) var revision: Int = 0

    private var undoStack: [String] = []
    private let undoLimit = 25

    var isEmpty: Bool { text.isEmpty && partial.isEmpty }

    /// What would be typed if the user committed right now.
    var committedText: String { text }

    /// Everything the user can see, live tail included.
    var displayText: String {
        partial.isEmpty ? text : joined(text, partial)
    }

    // MARK: - Speech input

    func setPartial(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != partial else { return }
        partial = trimmed
    }

    func setReplacementPreview(_ value: String?) {
        guard value != replacementPreview else { return }
        replacementPreview = value
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
            case .pasteInTarget, .copyInTarget, .selectAllInTarget, .clickAtPointer, .commit, .commitAndSend, .jarvis, .pressKeys:
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

    func replace(with value: String) {
        pushUndo()
        text = value
        partial = ""
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

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        text = previous
        partial = ""
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
