import AppKit
import SwiftUI

/// An edge-only AppKit overlay that registers native cursor rectangles without
/// interfering with controls in the panel interior.
private final class PanelResizeCursorView: NSView {

    private let zoneInset: CGFloat

    init(zoneInset: CGFloat) {
        self.zoneInset = zoneInset
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let nearEdge = point.x <= zoneInset
            || point.x >= bounds.width - zoneInset
            || point.y <= zoneInset
            || point.y >= bounds.height - zoneInset
        return nearEdge ? self : nil
    }

    /// The panel has an explicit header drag handle. Edge presses belong solely to
    /// resizing and must never fall through to background window movement.
    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()

        let zone = min(zoneInset, bounds.width / 2, bounds.height / 2)
        guard zone > 0 else { return }

        let middleWidth = max(0, bounds.width - 2 * zone)
        let middleHeight = max(0, bounds.height - 2 * zone)

        addCursorRect(
            NSRect(x: 0, y: bounds.height - zone, width: zone, height: zone),
            cursor: NSCursor.frameResize(position: .topLeft, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.width - zone, y: bounds.height - zone, width: zone, height: zone),
            cursor: NSCursor.frameResize(position: .topRight, directions: .all)
        )
        addCursorRect(
            NSRect(x: 0, y: 0, width: zone, height: zone),
            cursor: NSCursor.frameResize(position: .bottomLeft, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.width - zone, y: 0, width: zone, height: zone),
            cursor: NSCursor.frameResize(position: .bottomRight, directions: .all)
        )
        addCursorRect(
            NSRect(x: 0, y: zone, width: zone, height: middleHeight),
            cursor: NSCursor.frameResize(position: .left, directions: .all)
        )
        addCursorRect(
            NSRect(x: bounds.width - zone, y: zone, width: zone, height: middleHeight),
            cursor: NSCursor.frameResize(position: .right, directions: .all)
        )
        addCursorRect(
            NSRect(x: zone, y: 0, width: middleWidth, height: zone),
            cursor: NSCursor.frameResize(position: .bottom, directions: .all)
        )
        addCursorRect(
            NSRect(x: zone, y: bounds.height - zone, width: middleWidth, height: zone),
            cursor: NSCursor.frameResize(position: .top, directions: .all)
        )
    }
}

/// Borderless, non-activating floating panel — the Siri / Accessibility-Keyboard
/// shape. Because it never activates the app, the window the user was typing in
/// keeps its focus ring and its caret while dictation runs.
final class FloatingPanel: NSPanel {

    static let minimumContentSize = NSSize(width: 320, height: 170)

    /// Deliberately wider than AppKit's borderless-window resize strip. This remains
    /// inside the panel, so it needs no global mouse monitor or extra permission.
    private static let resizeZoneInset: CGFloat = 14

    private struct ResizeEdges: OptionSet {
        let rawValue: UInt8

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private struct ResizeSession {
        let edges: ResizeEdges
        let initialFrame: NSRect
        let initialMouseLocation: NSPoint
    }

    var onCancel: (() -> Void)?
    var onUserDrag: (() -> Void)?
    var onFrameChangeFinished: (() -> Void)?

    private var isShowingResizeCursor = false
    private var suspendedCursorRectsForResize = false
    private var resizeSession: ResizeSession?
    private var resizeTrackingArea: NSTrackingArea?
    private weak var resizeTrackingView: NSView?
    private weak var resizeCursorView: PanelResizeCursorView?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        contentMinSize = Self.minimumContentSize
        minSize = Self.minimumContentSize

        isFloatingPanel = true
        level = .floating
        // Follow the user across Spaces and sit over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Movement is owned by the explicit header drag handle. Letting arbitrary
        // background views move the window competes with the enlarged manual resize
        // zone and can translate the panel during a resize drag.
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
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
        // Be defensive if a header/background drag is dispatched while an edge
        // resize session owns the mouse: one gesture must never resize and move.
        guard resizeSession == nil else { return }
        onUserDrag?()
        super.performDrag(with: event)
        onFrameChangeFinished?()
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if beginResizeIfNeeded(with: event) { return }
        case .leftMouseDragged:
            if continueResizeIfNeeded() { return }
        case .leftMouseUp:
            if resizeSession != nil {
                resizeSession = nil
                updateResizeCursor(at: event.locationInWindow)
                onFrameChangeFinished?()
                return
            }
        default:
            break
        }

        super.sendEvent(event)

        switch event.type {
        case .mouseMoved, .cursorUpdate:
            updateResizeCursor(at: event.locationInWindow)
        default:
            break
        }
    }

    /// Tracking areas receive hover updates even while this non-activating panel is
    /// not key. Plain window mouse-moved handling is not reliable in that state.
    func installResizeTracking() {
        if let resizeTrackingArea, let resizeTrackingView {
            resizeTrackingView.removeTrackingArea(resizeTrackingArea)
        }
        resizeCursorView?.removeFromSuperview()

        guard let contentView else { return }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved,
                .cursorUpdate,
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(trackingArea)
        resizeTrackingArea = trackingArea
        resizeTrackingView = contentView

        let cursorView = PanelResizeCursorView(zoneInset: Self.resizeZoneInset)
        cursorView.frame = contentView.bounds
        cursorView.autoresizingMask = [.width, .height]
        contentView.addSubview(cursorView, positioned: .above, relativeTo: nil)
        resizeCursorView = cursorView

        invalidateCursorRects(for: cursorView)
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: event.locationInWindow)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateResizeCursor(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        restoreArrowCursorIfNeeded()
    }

    private func updateResizeCursor(at point: NSPoint) {
        guard
            styleMask.contains(.resizable),
            let position = resizeCursorPosition(for: resizeEdges(at: point))
        else {
            restoreArrowCursorIfNeeded()
            return
        }

        if !suspendedCursorRectsForResize {
            disableCursorRects()
            suspendedCursorRectsForResize = true
        }
        NSCursor.frameResize(position: position, directions: .all).set()
        isShowingResizeCursor = true
    }

    private func restoreArrowCursorIfNeeded() {
        guard isShowingResizeCursor || suspendedCursorRectsForResize else { return }
        NSCursor.arrow.set()
        isShowingResizeCursor = false
        if suspendedCursorRectsForResize {
            enableCursorRects()
            suspendedCursorRectsForResize = false
        }
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        let bounds = NSRect(origin: .zero, size: frame.size)
        guard bounds.contains(point) else { return [] }

        var edges: ResizeEdges = []
        if point.x <= Self.resizeZoneInset { edges.insert(.left) }
        if point.x >= bounds.width - Self.resizeZoneInset { edges.insert(.right) }
        if point.y <= Self.resizeZoneInset { edges.insert(.bottom) }
        if point.y >= bounds.height - Self.resizeZoneInset { edges.insert(.top) }
        return edges
    }

    private func resizeCursorPosition(for edges: ResizeEdges) -> NSCursor.FrameResizePosition? {
        switch edges {
        case [.left, .top]:
            return .topLeft
        case [.right, .top]:
            return .topRight
        case [.left, .bottom]:
            return .bottomLeft
        case [.right, .bottom]:
            return .bottomRight
        case [.left]:
            return .left
        case [.right]:
            return .right
        case [.bottom]:
            return .bottom
        case [.top]:
            return .top
        default:
            return nil
        }
    }

    private func beginResizeIfNeeded(with event: NSEvent) -> Bool {
        guard styleMask.contains(.resizable) else { return false }
        let edges = resizeEdges(at: event.locationInWindow)
        guard !edges.isEmpty else { return false }

        resizeSession = ResizeSession(
            edges: edges,
            initialFrame: frame,
            initialMouseLocation: NSEvent.mouseLocation
        )
        onUserDrag?()
        updateResizeCursor(at: event.locationInWindow)
        return true
    }

    private func continueResizeIfNeeded() -> Bool {
        guard let session = resizeSession else { return false }

        let mouse = NSEvent.mouseLocation
        let deltaX = mouse.x - session.initialMouseLocation.x
        let deltaY = mouse.y - session.initialMouseLocation.y
        let minimum = Self.minimumContentSize
        var next = session.initialFrame

        if session.edges.contains(.left) {
            let right = session.initialFrame.maxX
            next.size.width = max(minimum.width, session.initialFrame.width - deltaX)
            next.origin.x = right - next.width
        } else if session.edges.contains(.right) {
            next.size.width = max(minimum.width, session.initialFrame.width + deltaX)
        }

        if session.edges.contains(.bottom) {
            let top = session.initialFrame.maxY
            next.size.height = max(minimum.height, session.initialFrame.height - deltaY)
            next.origin.y = top - next.height
        } else if session.edges.contains(.top) {
            next.size.height = max(minimum.height, session.initialFrame.height + deltaY)
        }

        setFrame(next, display: true)
        if let resizeCursorView {
            invalidateCursorRects(for: resizeCursorView)
        }
        return true
    }
}

/// Owns the panel, its SwiftUI content, and where it appears on screen.
final class PanelController {

    private static let frameAutosaveName = "BtrVoicePanel"
    private static let frameDefaultsKey = "NSWindow Frame \(frameAutosaveName)"
    /// AppKit's frame autosave is retained for compatibility, but BtrVoice also owns
    /// an explicit rectangle so origin changes cannot be omitted or flushed late.
    private static let persistedFrameKey = "BtrVoicePanelPersistedFrame"

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
    private var framePersistenceObservers: [NSObjectProtocol] = []

    init(controller: DictationController) {
        let explicitlySavedFrame = Self.persistedFrame()
        let hasSavedFrame = explicitlySavedFrame != nil
            || UserDefaults.standard.object(forKey: Self.frameDefaultsKey) != nil

        hosting = NSHostingController(rootView: DictationPanelView(controller: controller))
        // No preferredContentSize sizing: the *user* owns the panel's size now (it's
        // resizable from any edge); SwiftUI just fills whatever they choose.
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.installResizeTracking()
        panel.onCancel = { [weak controller] in controller?.cancel() }
        panel.onUserDrag = { [weak self] in self?.autoPosition = false }
        panel.onFrameChangeFinished = { [weak self] in self?.saveFrame(flush: true) }
        // Remembers the size (and last origin) across launches.
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if let explicitlySavedFrame {
            // Apply our full rectangle *after* AppKit has processed its autosave
            // record. This makes the persisted origin authoritative as well as size.
            panel.setFrame(explicitlySavedFrame, display: false)
        }
        if hasSavedFrame {
            // A saved frame is an intentional user layout. Mark it as positioned so
            // the first show does not immediately replace it with a fresh anchor.
            hasBeenPositioned = true
            autoPosition = false
        }
        // Frame autosave can restore a size written before the current resize floor,
        // after the panel's initializer already applied its limits. Reassert them and
        // repair an undersized saved frame so the controls never launch clipped.
        let minimum = FloatingPanel.minimumContentSize
        panel.contentMinSize = minimum
        panel.minSize = minimum
        if panel.frame.width < minimum.width || panel.frame.height < minimum.height {
            var frame = panel.frame
            frame.size.width = max(frame.width, minimum.width)
            frame.size.height = max(frame.height, minimum.height)
            panel.setFrame(frame, display: false)
        }

        // Capture every path that can alter the frame, including programmatic moves,
        // native window-server adjustments, and manual resize sessions.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.saveFrame()
            }
            framePersistenceObservers.append(observer)
        }
        if hasSavedFrame {
            // Migrates the existing AppKit-only record to the explicit full frame.
            saveFrame(flush: true)
        }

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
        for observer in framePersistenceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func show(reposition: Bool) {
        if !hasBeenPositioned || (reposition && autoPosition) {
            updateAnchor()
        }
        panel.orderFrontRegardless()
        // Force a layout pass so the frame is real before we place it.
        panel.contentView?.layoutSubtreeIfNeeded()
        applyAnchor()
    }

    /// Recovers an unreachable panel without throwing away the user's chosen size.
    /// The reset location becomes the new persisted frame for subsequent launches.
    func resetPosition() {
        anchor = .bottomCentre
        autoPosition = true
        hasBeenPositioned = false

        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        applyAnchor()

        // Treat the reset location as a new manual placement. Otherwise later frame
        // changes could reapply the anchor and make the panel appear to drift.
        autoPosition = false
        hasBeenPositioned = true
        saveFrame(flush: true)
    }

    /// Called during application termination so an immediate development restart
    /// cannot race the preferences daemon and lose the last origin update.
    func persistFrameNow() {
        saveFrame(flush: true)
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
        saveFrame()
    }

    private func saveFrame(flush: Bool = false) {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.persistedFrameKey)
        panel.saveFrame(usingName: Self.frameAutosaveName)
        if flush {
            UserDefaults.standard.synchronize()
        }
    }

    private static func persistedFrame() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: persistedFrameKey) else {
            return nil
        }
        let frame = NSRectFromString(value)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
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
