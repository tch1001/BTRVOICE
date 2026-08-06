import AppKit
import ApplicationServices

/// Finds the insertion point of the focused text field via the accessibility API so
/// the panel can hover next to what the user is typing into, the way Siri and the
/// Accessibility Keyboard do.
///
/// Read-only AX use: we ask for the caret rect, we never try to *set* text this way.
/// That distinction is the point of the project — the write path is synthetic key
/// events, which every app understands.
enum CaretLocator {

    /// Caret rect in Cocoa screen coordinates (origin bottom-left), or nil when the
    /// focused element exposes nothing useful.
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement?
        else { return nil }

        if let rect = boundsOfSelection(in: element), rect.height > 0 {
            return convertFromAX(rect)
        }
        if let rect = frame(of: element), rect.height > 0 {
            // No caret geometry (Terminal, many Electron views): anchor to the element.
            return convertFromAX(rect)
        }
        return nil
    }

    private static func boundsOfSelection(in element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue
        else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &bounds
        ) == .success, let bounds else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }
        // A collapsed caret reports zero width; keep it, we only need the position.
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// AX reports top-left-origin, y-down coordinates on the primary display;
    /// Cocoa windows want bottom-left-origin, y-up.
    private static func convertFromAX(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let flippedY = primary.frame.maxY - rect.maxY
        return CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
    }
}
