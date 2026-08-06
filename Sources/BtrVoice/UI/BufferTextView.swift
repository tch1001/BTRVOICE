import AppKit
import SwiftUI

/// The single staging editor. Committed text and the live in-flight tail share one
/// text view: committed is normal label-coloured text the user can edit freely —
/// select, retype, cursor anywhere — while the tail is rendered grey at the end and
/// is owned by the recogniser until it finalises (at which point it simply turns
/// into normal text in place).
///
/// If the user edits *into* the grey region, the whole visible text becomes theirs:
/// `onAdoptAll` fires, and the controller tells the engine to discard the utterance
/// so the recogniser can't finish it later and duplicate words.
struct BufferTextView: NSViewRepresentable {

    let text: String
    let partial: String
    let revision: Int
    let placeholder: String
    let onEdit: (String) -> Void
    let onAdoptAll: (String) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// The grey suffix as it appears in the view: separator + partial.
    private var partialSuffix: String {
        guard !partial.isEmpty else { return "" }
        guard let last = text.last, !last.isWhitespace else { return partial }
        return " " + partial
    }

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
        context.coordinator.reload(committed: text, suffix: partialSuffix, revision: revision)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? EditorTextView else { return }
        textView.placeholder = placeholder
        textView.onCommit = onCommit
        textView.onCancel = onCancel
        context.coordinator.onEdit = onEdit
        context.coordinator.onAdoptAll = onAdoptAll

        if context.coordinator.appliedRevision != revision {
            // Committed text changed on our side (segment landed, clear, undo…):
            // rebuild the whole view content.
            context.coordinator.reload(committed: text, suffix: partialSuffix, revision: revision)
        } else if context.coordinator.displayedSuffix != partialSuffix {
            // Only the live tail moved: surgically replace the grey suffix so the
            // user's cursor and selection in the committed region stay put.
            context.coordinator.replaceSuffix(with: partialSuffix)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: (String) -> Void
        var onAdoptAll: (String) -> Void
        var appliedRevision: Int = -1
        /// Exactly what the grey region currently shows, separator included.
        var displayedSuffix: String = ""
        weak var textView: NSTextView?
        /// True while we mutate the view programmatically, so textDidChange ignores it.
        private var mutating = false

        init(onEdit: @escaping (String) -> Void, onAdoptAll: @escaping (String) -> Void) {
            self.onEdit = onEdit
            self.onAdoptAll = onAdoptAll
        }

        private static let partialAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        private static let committedAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]

        func reload(committed: String, suffix: String, revision: Int) {
            guard let textView else { return }
            appliedRevision = revision
            displayedSuffix = suffix

            let wasAtEnd = textView.selectedRange().location >= (textView.string as NSString).length
            let content = NSMutableAttributedString(string: committed, attributes: Self.committedAttributes)
            content.append(NSAttributedString(string: suffix, attributes: Self.partialAttributes))

            mutating = true
            textView.textStorage?.setAttributedString(content)
            textView.typingAttributes = Self.committedAttributes
            mutating = false

            if wasAtEnd {
                let end = content.length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            }
            textView.needsDisplay = true
        }

        func replaceSuffix(with newSuffix: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = textView.string as NSString
            let oldLength = (displayedSuffix as NSString).length

            // The grey region must still be intact at the end; if not, fall back to a
            // full reload on the next revision rather than corrupting user text.
            guard full.length >= oldLength,
                  full.substring(from: full.length - oldLength) == displayedSuffix
            else {
                displayedSuffix = newSuffix
                return
            }

            let range = NSRange(location: full.length - oldLength, length: oldLength)
            let selection = textView.selectedRange()
            let followTail = selection.location >= range.location && selection.length == 0

            mutating = true
            storage.replaceCharacters(
                in: range,
                with: NSAttributedString(string: newSuffix, attributes: Self.partialAttributes)
            )
            textView.typingAttributes = Self.committedAttributes
            mutating = false

            displayedSuffix = newSuffix
            let end = (textView.string as NSString).length
            if followTail {
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            textView.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard !mutating, let textView = notification.object as? NSTextView else { return }
            let s = textView.string

            if displayedSuffix.isEmpty {
                onEdit(s)
            } else if s.hasSuffix(displayedSuffix) {
                // Edit stayed within the committed region.
                onEdit(String(s.dropLast(displayedSuffix.count)))
            } else {
                // The user reached into the live grey text: it's all theirs now.
                displayedSuffix = ""
                mutating = true
                textView.textStorage?.setAttributes(
                    Self.committedAttributes,
                    range: NSRange(location: 0, length: (s as NSString).length)
                )
                textView.typingAttributes = Self.committedAttributes
                mutating = false
                onAdoptAll(s)
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
