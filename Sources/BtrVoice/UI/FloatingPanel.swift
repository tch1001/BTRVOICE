import AppKit
import SwiftUI

/// Borderless, non-activating floating panel — the Siri / Accessibility-Keyboard
/// shape. Because it never activates the app, the window the user was typing in
/// keeps its focus ring and its caret while dictation runs.
final class FloatingPanel: NSPanel {

    var onCancel: (() -> Void)?
    var onUserDrag: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        contentMinSize = NSSize(width: 320, height: 170)

        isFloatingPanel = true
        level = .floating
        // Follow the user across Spaces and sit over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        // Only steal keyboard focus when the user actually clicks into the editor.
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Once the user has placed the panel by hand, stop moving it for them.
    override func performDrag(with event: NSEvent) {
        onUserDrag?()
        super.performDrag(with: event)
    }
}

/// Owns the panel, its SwiftUI content, and where it appears on screen.
final class PanelController {

    /// Where the panel wants to sit. Kept separate from the frame because the panel
    /// resizes as the transcript grows, and the anchor is what should stay put.
    private enum Anchor {
        /// Just below (or above) the caret of the focused text field.
        case caret(CGRect)
        /// Siri's spot: bottom-centre of the active screen.
        case bottomCentre
    }

    private let panel = FloatingPanel()
    private let hosting: NSHostingController<DictationPanelView>
    private var anchor: Anchor = .bottomCentre
    private var hasBeenPositioned = false
    /// Cleared once the user drags the panel somewhere they prefer.
    private var autoPosition = true
    private var resizeObserver: NSObjectProtocol?

    init(controller: DictationController) {
        hosting = NSHostingController(rootView: DictationPanelView(controller: controller))
        // No preferredContentSize sizing: the *user* owns the panel's size now (it's
        // resizable from any edge); SwiftUI just fills whatever they choose.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.onCancel = { [weak controller] in controller?.cancel() }
        panel.onUserDrag = { [weak self] in self?.autoPosition = false }
        // Remembers the size (and last origin) across launches.
        panel.setFrameAutosaveName("BtrVoicePanel")

        // Re-run placement when the frame changes under us — but never while the
        // user is dragging an edge, or we'd yank the window out of their hands.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.inLiveResize == false else { return }
            self.applyAnchor()
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    var isVisible: Bool { panel.isVisible }

    func show(reposition: Bool) {
        if reposition || !hasBeenPositioned {
            updateAnchor()
        }
        panel.orderFrontRegardless()
        // Force a layout pass so the frame is real before we place it.
        panel.contentView?.layoutSubtreeIfNeeded()
        applyAnchor()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle(reposition: Bool) {
        if panel.isVisible {
            hide()
        } else {
            show(reposition: reposition)
        }
    }

    /// Drops keyboard focus without hiding, so posted key events go to the target app.
    func releaseFocus() {
        panel.makeFirstResponder(nil)
        if panel.isKeyWindow { panel.resignKey() }
    }

    /// Re-reads the caret position and moves the panel there.
    func positionAtCaret() {
        updateAnchor()
        applyAnchor()
    }

    private func updateAnchor() {
        autoPosition = true
        if Settings.shared.followCaret, let caret = CaretLocator.caretRect(), caret.height > 0 {
            anchor = .caret(caret)
        } else {
            anchor = .bottomCentre
        }
    }

    /// Places the panel from the current anchor and the current size. Safe to call
    /// repeatedly — it's idempotent for a given size.
    private func applyAnchor() {
        guard autoPosition else { return }
        let size = panel.frame.size
        guard size.width > 1, size.height > 1 else { return }
        hasBeenPositioned = true

        let origin: CGPoint
        switch anchor {
        case .caret(let caret):
            guard let visible = (screenContaining(point: CGPoint(x: caret.midX, y: caret.midY))
                                 ?? NSScreen.main)?.visibleFrame else { return }
            let gap: CGFloat = 14
            var candidate = CGPoint(x: caret.minX - 8, y: caret.minY - gap - size.height)
            // Flip above the caret when there's no room below it.
            if candidate.y < visible.minY {
                let above = caret.maxY + gap
                candidate.y = above + size.height > visible.maxY ? visible.minY + 12 : above
            }
            origin = clamp(candidate, size: size, within: visible)

        case .bottomCentre:
            guard let visible = (screenContaining(point: NSEvent.mouseLocation)
                                 ?? NSScreen.main)?.visibleFrame else { return }
            origin = clamp(
                CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 24),
                size: size,
                within: visible
            )
        }

        guard origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin)
    }

    private func clamp(_ origin: CGPoint, size: NSSize, within visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visible.minX + 12), max(visible.minX + 12, visible.maxX - size.width - 12)),
            y: min(max(origin.y, visible.minY + 12), max(visible.minY + 12, visible.maxY - size.height - 12))
        )
    }

    private func screenContaining(point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
