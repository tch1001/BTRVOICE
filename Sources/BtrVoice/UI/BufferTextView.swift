import AppKit
import SwiftUI

/// Confirmed text and the pending suffix share one native editor. Cloud snapshots
/// are applied as small edits; confirmation recolours existing glyphs in place.
struct BufferTextView: NSViewRepresentable {
    let text: String
    /// Exact suffix (including its separator), as presented by TextBuffer.
    let partial: String
    let revision: Int
    let placeholder: String
    let onEdit: (String) -> Void
    let onAdoptAll: (String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, onAdoptAll: onAdoptAll)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.onCommit = onCommit
        textView.onCancel = onCancel

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.update(committed: text, suffix: partial, revision: revision)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? EditorTextView else { return }
        textView.placeholder = placeholder
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        context.coordinator.onEdit = onEdit
        context.coordinator.onAdoptAll = onAdoptAll
        context.coordinator.update(committed: text, suffix: partial, revision: revision)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (String) -> Void
        var onAdoptAll: (String) -> Void
        var appliedRevision = -1
        var displayedSuffix = ""
        weak var textView: NSTextView?
        private var mutating = false

        init(onEdit: @escaping (String) -> Void, onAdoptAll: @escaping (String) -> Void) {
            self.onEdit = onEdit
            self.onAdoptAll = onAdoptAll
        }

        private static let committedAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]

        func update(committed: String, suffix: String, revision: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let previous = textView.string
            let content = committed + suffix
            guard !previous.utf8.elementsEqual(content.utf8) || displayedSuffix != suffix else {
                appliedRevision = revision
                return
            }

            let selections = textView.selectedRanges.map(\.rangeValue)
            let previousLength = previous.utf16.count
            let caretAtEnd = selections.count == 1
                && selections[0] == NSRange(location: previousLength, length: 0)
            let wasAtBottom = textView.enclosingScrollView.map {
                $0.documentVisibleRect.maxY >= textView.bounds.maxY - 24
            } ?? true
            let update = TranscriptTextUpdate(from: previous, to: content)

            mutating = true
            storage.beginEditing()
            for edit in update.edits.reversed() {
                storage.replaceCharacters(
                    in: edit.range,
                    with: NSAttributedString(string: edit.replacement, attributes: Self.committedAttributes)
                )
            }
            // Recolour only runs that actually changed state. Identical grey text
            // becoming confirmed is an attribute edit, never a text replacement.
            recolour(storage, range: NSRange(location: 0, length: committed.utf16.count),
                     color: .labelColor)
            recolour(storage, range: NSRange(location: committed.utf16.count, length: suffix.utf16.count),
                     color: .secondaryLabelColor)
            storage.endEditing()
            textView.typingAttributes = Self.committedAttributes
            if !update.edits.isEmpty {
                if caretAtEnd {
                    textView.setSelectedRange(NSRange(location: storage.length, length: 0))
                } else {
                    textView.selectedRanges = selections.map { NSValue(range: update.selection(after: $0)) }
                }
                if caretAtEnd && wasAtBottom {
                    textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                }
            }
            displayedSuffix = suffix
            appliedRevision = revision
            mutating = false
            if previous.isEmpty != content.isEmpty { textView.needsDisplay = true }
        }

        private func recolour(_ storage: NSTextStorage, range: NSRange, color: NSColor) {
            guard range.length > 0 else { return }
            var changes: [NSRange] = []
            storage.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                if (value as? NSColor) != color { changes.append(run) }
            }
            for run in changes { storage.addAttribute(.foregroundColor, value: color, range: run) }
        }

        func textDidChange(_ notification: Notification) {
            guard !mutating, let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            if displayedSuffix.isEmpty {
                onEdit(value)
            } else if value.hasSuffix(displayedSuffix) {
                onEdit(String(value.dropLast(displayedSuffix.count)))
            } else {
                displayedSuffix = ""
                mutating = true
                if let storage = textView.textStorage {
                    recolour(storage, range: NSRange(location: 0, length: storage.length), color: .labelColor)
                }
                textView.typingAttributes = Self.committedAttributes
                mutating = false
                onAdoptAll(value)
            }
            textView.needsDisplay = true
        }
    }
}

/// Adds a placeholder and the two keyboard shortcuts that matter while reviewing:
/// ⌘↩ to insert, ⎋ to discard.
private final class EditorTextView: NSTextView {

    var placeholder: String = ""
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The empty staging area is window chrome until there is text to edit. Once
    /// content exists, normal NSTextView selection wins so the editor keeps its
    /// core review-and-rewrite behavior.
    override var mouseDownCanMoveWindow: Bool { string.isEmpty }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 53 = Escape
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let inset = textContainerInset
        let rect = NSRect(
            x: inset.width + 5,
            y: inset.height,
            width: max(0, bounds.width - inset.width * 2 - 10),
            height: max(0, bounds.height - inset.height * 2)
        )
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}
