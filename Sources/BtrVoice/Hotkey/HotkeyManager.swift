import AppKit
import Carbon.HIToolbox

enum HotkeyAction: UInt32, CaseIterable {
    case toggleDictation = 1
    case commit = 2
    case cancel = 3

    var label: String {
        switch self {
        case .toggleDictation: return "Dictate"
        case .commit: return "Commit buffer"
        case .cancel: return "Cancel"
        }
    }

    var displayShortcut: String {
        switch self {
        case .toggleDictation: return "⌥Space"
        case .commit: return "⌥↩"
        case .cancel: return "⌥⎋"
        }
    }

    fileprivate var keyCode: UInt32 {
        switch self {
        case .toggleDictation: return UInt32(kVK_Space)
        case .commit: return UInt32(kVK_Return)
        case .cancel: return UInt32(kVK_Escape)
        }
    }

    fileprivate var modifiers: UInt32 { UInt32(optionKey) }
}

/// System-wide hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Deliberately not an `NSEvent` global monitor: Carbon hotkeys work without
/// Accessibility permission, so dictation can be started before the user has
/// granted anything, and they're consumed rather than merely observed.
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// `(action, isKeyDown)`. Both edges are reported so callers can tell a tap from
    /// a press-and-hold.
    var handler: ((HotkeyAction, Bool) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var registrations: [EventHotKeyRef?] = []
    private var registered = false
    private var failures: [HotkeyAction] = []
    private var lastFired: (action: HotkeyAction, at: Date)?

    private init() {}

    /// For the diagnostics sheet: did every shortcut actually get claimed?
    var registrationSummary: String {
        guard registered else { return "not registered" }
        guard !failures.isEmpty else {
            return HotkeyAction.allCases.map(\.displayShortcut).joined(separator: "  ") + " registered"
        }
        return "FAILED to claim \(failures.map(\.displayShortcut).joined(separator: ", ")) — another app already owns it"
    }

    var lastFiredDescription: String {
        guard let lastFired else { return "none seen since launch" }
        let ago = Int(Date().timeIntervalSince(lastFired.at))
        return "\(lastFired.action.displayShortcut) (\(ago)s ago)"
    }

    func register() {
        guard !registered else { return }
        registered = true

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), btrVoiceHotkeyCallback, specs.count, &specs, nil, &eventHandler)

        for action in HotkeyAction.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x42545652 /* 'BTVR' */), id: action.rawValue)
            let status = RegisterEventHotKey(action.keyCode, action.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr {
                registrations.append(ref)
            } else {
                failures.append(action)
                Log.write("hotkey: FAILED to register \(action.displayShortcut) (OSStatus \(status)) — another app likely owns it")
            }
        }
        Log.write("hotkey: \(registrationSummary)")
    }

    func unregister() {
        for ref in registrations.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        registered = false
    }

    fileprivate func dispatch(id: UInt32, isDown: Bool) {
        guard let action = HotkeyAction(rawValue: id) else { return }
        if isDown {
            lastFired = (action, Date())
            Log.write("hotkey: \(action.displayShortcut) pressed")
        }
        handler?(action, isDown)
    }
}

/// Top-level so it converts to a C function pointer (no captured context).
private func btrVoiceHotkeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    DispatchQueue.main.async {
        HotkeyManager.shared.dispatch(id: hotkeyID.id, isDown: isDown)
    }
    return noErr
}
