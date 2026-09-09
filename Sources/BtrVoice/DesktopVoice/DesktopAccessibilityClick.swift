/// A single synthetic click for a locally approved AX target that lacks AXPress.
/// Coordinates come from native geometry, never from the model. Covered, moved,
/// stale, unfocused or modified clicks are rejected instead of retargeted.
import AppKit
import ApplicationServices

enum DesktopAccessibilityClick {
    static let action = "BtrClick"

    static func isUsable(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 1 && frame.height > 1
    }

    static func execute(_ target: DesktopAccessibilityElement, in context: DesktopAccessibilityContext) throws {
        try Task.checkCancellation()
        guard let expected = target.clickFrame, isUsable(expected),
              Date().timeIntervalSince(context.capturedAt) < 60,
              let pid = context.processIdentifier, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = DesktopAccessibilityReader.frame(target.reference), current == expected,
              let window = context.window, let windowFrame = DesktopAccessibilityReader.frame(window),
              windowFrame.contains(current) else { throw DesktopAXError.stale }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right) else {
            throw DesktopAXError.invalid("Release the keyboard modifiers and mouse buttons before selecting this folder.")
        }
        let point = CGPoint(x: current.midX, y: current.midY)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw DesktopAXError.stale }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
              CFEqual(hit, target.reference) else {
            throw DesktopAXError.invalid("The folder is covered or no longer under its recorded position. No click was sent.")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw DesktopAXError.unavailable
        }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              DesktopAccessibilityReader.frame(target.reference) == expected else { throw DesktopAXError.stale }
        // Complete the pair even if cancellation arrives between down and up.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
