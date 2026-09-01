import CoreGraphics
import Foundation

/// Adds the virtual keyboard's logical modifier latches to real pointer events.
///
/// A latched modifier is deliberately not posted as a long-lived synthetic key-down:
/// that can leave macOS with a stuck modifier if the app exits unexpectedly, and it
/// can interfere with a hardware modifier the user is holding. Instead, this narrow
/// session event tap preserves the physical event and adds the requested flags to
/// clicks, drags, pointer movement, and scrolling while the keyboard is visible.
final class StickyModifierPointerBridge {
    static let pointerEventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .mouseMoved, .scrollWheel,
    ]

    static func mergedFlags(
        eventFlags: CGEventFlags,
        activeModifiers: CGEventFlags
    ) -> CGEventFlags {
        eventFlags.union(activeModifiers)
    }

    private static let eventMask = pointerEventTypes.reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << type.rawValue)
    }

    private let lock = NSLock()
    private var activeModifiers: CGEventFlags = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func update(activeModifiers: CGEventFlags) {
        lock.lock()
        self.activeModifiers = activeModifiers
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        update(activeModifiers: [])
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func rewrite(_ event: CGEvent) -> Unmanaged<CGEvent> {
        lock.lock()
        let modifiers = activeModifiers
        lock.unlock()
        if !modifiers.isEmpty {
            event.flags = Self.mergedFlags(
                eventFlags: event.flags,
                activeModifiers: modifiers
            )
        }
        return Unmanaged.passUnretained(event)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let bridge = Unmanaged<StickyModifierPointerBridge>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = bridge.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        return bridge.rewrite(event)
    }
}
