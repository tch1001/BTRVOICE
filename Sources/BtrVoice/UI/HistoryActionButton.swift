import AppKit
import SwiftUI

/// History is operated while another app owns the caret. Native controls opt in
/// to the first click and never need to make the history panel key to act.
struct HistoryActionButton: NSViewRepresentable {
    let title: String
    var symbol: String?
    var prominent = false
    var destructive = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HistoryActionControl {
        let button = HistoryActionControl()
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: HistoryActionControl, context: Context) {
        button.title = title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        button.bezelColor = prominent ? .controlAccentColor : nil
        button.contentTintColor = destructive ? .systemRed : (prominent ? .white : nil)
        button.isEnabled = isEnabled
        button.onPress = action
        button.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HistoryActionControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Explicit first-mouse behavior also applies to controls inside SwiftUI List rows.
final class HistoryActionControl: NSButton {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func pressed() {
        guard isEnabled else { return }
        // Selecting a transcript can legitimately give history keyboard focus.
        // Return it before sending, just as the dictation overlay does.
        if let window, window.isKeyWindow {
            window.makeFirstResponder(nil)
            window.resignKey()
        }
        onPress?()
    }
}
