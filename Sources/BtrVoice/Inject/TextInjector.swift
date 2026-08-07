import AppKit
import CoreGraphics

/// Writes text into whatever app is frontmost by synthesising keyboard input.
///
/// This is the part that makes BtrVoice work where Apple's dictation doesn't: a
/// `CGEvent` carrying a unicode payload is indistinguishable from a real keypress,
/// so Terminal, Telegram, Electron apps and games all accept it — none of them need
/// to implement the accessibility text-insertion protocol.
enum TextInjector {

    /// Above this many characters, `.auto` switches from typing to pasting.
    static let pasteThreshold = 120

    /// Max UTF-16 units per event. Larger payloads get silently truncated by some apps.
    private static let chunkLimit = 16
    /// Gap between events. Too fast and Terminal/Electron drop characters.
    private static let interKeyDelay: useconds_t = 1_200

    private static let returnKeyCode: CGKeyCode = 36
    private static let tabKeyCode: CGKeyCode = 48
    private static let vKeyCode: CGKeyCode = 9
    private static let cKeyCode: CGKeyCode = 8
    private static let aKeyCode: CGKeyCode = 0
    private static let deleteKeyCode: CGKeyCode = 51

    /// A private event source does not inherit the real hardware modifier state, so
    /// a still-held ⌥ from the hotkey can't corrupt what we type.
    private static func makeSource() -> CGEventSource? {
        CGEventSource(stateID: .privateState)
    }

    // MARK: - Entry point

    /// Types (or pastes) `text`, then optionally presses Return to send.
    /// Runs the event posting off the main thread because of the inter-key sleeps.
    static func inject(
        _ text: String,
        mode: InjectionMode,
        newlineMode: NewlineMode,
        pressReturnAfter: Bool,
        completion: @escaping (Result<Void, InjectionError>) -> Void
    ) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.notTrusted))
            return
        }
        guard !text.isEmpty || pressReturnAfter else {
            completion(.success(()))
            return
        }

        let resolved: InjectionMode
        switch mode {
        case .auto: resolved = text.count > pasteThreshold ? .paste : .typing
        case .typing, .paste: resolved = mode
        }

        // Pasteboard work has to happen on main; the key posting does not.
        var restore: (() -> Void)?
        if resolved == .paste, !text.isEmpty {
            restore = stashPasteboard(replacingWith: text)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeSource() else {
                DispatchQueue.main.async {
                    restore?()
                    completion(.failure(.eventSourceUnavailable))
                }
                return
            }

            if !text.isEmpty {
                switch resolved {
                case .paste:
                    postChord(keyCode: vKeyCode, flags: .maskCommand, source: source)
                    // The receiving app reads the pasteboard asynchronously.
                    usleep(250_000)
                case .typing, .auto:
                    typeOut(text, newlineMode: newlineMode, source: source)
                }
            }

            if pressReturnAfter {
                usleep(30_000)
                postKey(returnKeyCode, flags: [], source: source)
            }

            DispatchQueue.main.async {
                restore?()
                completion(.success(()))
            }
        }
    }

    /// Presses the real Backspace key in the frontmost app — deletes at *its* cursor,
    /// exactly like tapping the key on the keyboard. `wordwise` sends ⌥⌫ (delete the
    /// previous word), which every macOS text field understands.
    static func pressBackspace(wordwise: Bool, completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.notTrusted))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeSource() else {
                DispatchQueue.main.async { completion(.failure(.eventSourceUnavailable)) }
                return
            }
            if wordwise {
                postChord(keyCode: deleteKeyCode, flags: .maskAlternate, source: source)
            } else {
                postKey(deleteKeyCode, flags: [], source: source)
            }
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    enum Shortcut {
        /// ⌘V
        case paste
        /// ⌘C
        case copy
        /// ⌘A
        case selectAll

        var keyCode: CGKeyCode {
            switch self {
            case .paste: return vKeyCode
            case .copy: return cKeyCode
            case .selectAll: return aKeyCode
            }
        }
    }

    /// Presses a ⌘-shortcut in the frontmost app, exactly like the real keys.
    static func pressShortcut(_ shortcut: Shortcut, completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.notTrusted))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeSource() else {
                DispatchQueue.main.async { completion(.failure(.eventSourceUnavailable)) }
                return
            }
            postChord(keyCode: shortcut.keyCode, flags: .maskCommand, source: source)
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    // MARK: - Arbitrary key combos ("cmd+shift+p")

    /// Key names → virtual keycodes for combo parsing.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
    ]

    /// Parses "cmd+shift+p" (order-insensitive, case-insensitive). Returns nil
    /// for unknown keys, no key, or more than one non-modifier key.
    /// Internal rather than private so `--self-test` can exercise it.
    static func parseCombo(_ text: String) -> (key: CGKeyCode, flags: CGEventFlags, display: String)? {
        var flags: CGEventFlags = []
        var key: (name: String, code: CGKeyCode)?
        for part in text.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            let name = String(part).trimmingCharacters(in: .whitespaces)
            if let modifier = modifierFlags[name] {
                flags.insert(modifier)
            } else if let code = keyCodes[name] {
                guard key == nil else { return nil }
                key = (name, code)
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        var display = ""
        if flags.contains(.maskControl) { display += "⌃" }
        if flags.contains(.maskAlternate) { display += "⌥" }
        if flags.contains(.maskShift) { display += "⇧" }
        if flags.contains(.maskCommand) { display += "⌘" }
        display += key.name.count == 1 ? key.name.uppercased() : key.name.capitalized
        return (key.code, flags, display)
    }

    /// Presses an arbitrary chord in the frontmost app — every modifier goes
    /// down as its own event first, for apps that watch flagsChanged.
    static func pressCombo(key: CGKeyCode, flags: CGEventFlags, completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.notTrusted))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeSource() else {
                DispatchQueue.main.async { completion(.failure(.eventSourceUnavailable)) }
                return
            }
            let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
                (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
            ]
            let held = modifierKeys.filter { flags.contains($0.0) }
            for (_, code) in held {
                if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
                    down.flags = flags
                    down.post(tap: .cgSessionEventTap)
                    usleep(8_000)
                }
            }
            postKey(key, flags: flags, source: source)
            for (_, code) in held.reversed() {
                if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                    up.flags = []
                    up.post(tap: .cgSessionEventTap)
                }
            }
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    /// Left-clicks at wherever the pointer currently is. The panel is non-activating,
    /// so the click lands on whatever app is under the pointer.
    static func clickAtPointer(completion: @escaping (Result<Void, InjectionError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.notTrusted))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = makeSource(),
                  let position = CGEvent(source: nil)?.location,
                  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: position, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: position, mouseButton: .left)
            else {
                DispatchQueue.main.async { completion(.failure(.eventSourceUnavailable)) }
                return
            }
            down.post(tap: .cgSessionEventTap)
            usleep(30_000)
            up.post(tap: .cgSessionEventTap)
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    // MARK: - Typing

    private static func typeOut(_ text: String, newlineMode: NewlineMode, source: CGEventSource) {
        // Split on newlines so each one can become a real key press; apps disagree
        // wildly about whether a literal \n in a unicode payload means anything.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                switch newlineMode {
                case .returnKey:
                    postKey(returnKeyCode, flags: [], source: source)
                case .shiftReturn:
                    postChord(keyCode: returnKeyCode, flags: .maskShift, source: source)
                case .literal:
                    postUnicode("\n", source: source)
                }
                usleep(interKeyDelay)
            }
            for chunk in chunked(line) {
                if chunk == "\t" {
                    postKey(tabKeyCode, flags: [], source: source)
                } else {
                    postUnicode(chunk, source: source)
                }
                usleep(interKeyDelay)
            }
        }
    }

    /// Splits on character boundaries so grapheme clusters and surrogate pairs stay
    /// intact, while keeping each chunk within the event payload limit.
    /// Internal rather than private so `--self-test` can exercise it.
    static func chunked(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        var count = 0
        for character in line {
            let width = character.utf16.count
            if count + width > chunkLimit, !current.isEmpty {
                chunks.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += width
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func postUnicode(_ string: String, source: CGEventSource) {
        var utf16 = Array(string.utf16)
        guard !utf16.isEmpty else { return }

        // virtualKey 0 is a placeholder — the unicode payload is what apps read.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Modifier-down, key, modifier-up. Sending the modifier as its own event is
    /// necessary for apps that watch flagsChanged rather than the event flags.
    private static func postChord(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource) {
        let modifierKey: CGKeyCode
        switch flags {
        case .maskCommand: modifierKey = 55   // Left Command
        case .maskShift: modifierKey = 56     // Left Shift
        case .maskAlternate: modifierKey = 58 // Left Option
        default: modifierKey = 0
        }

        if modifierKey != 0, let modDown = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: true) {
            modDown.flags = flags
            modDown.post(tap: .cgSessionEventTap)
            usleep(8_000)
        }
        postKey(keyCode, flags: flags, source: source)
        if modifierKey != 0, let modUp = CGEvent(keyboardEventSource: source, virtualKey: modifierKey, keyDown: false) {
            modUp.flags = []
            modUp.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Pasteboard

    /// Replaces the pasteboard contents and returns a closure that puts the user's
    /// data back. Losing someone's clipboard to a dictation tool is unforgivable.
    private static func stashPasteboard(replacingWith text: String) -> () -> Void {
        let pasteboard = NSPasteboard.general
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            if !entry.isEmpty { saved.append(entry) }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        return {
            // Delay so the target app has definitely read what we put there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                guard !saved.isEmpty else { return }
                let items: [NSPasteboardItem] = saved.map { entry in
                    let item = NSPasteboardItem()
                    for (type, data) in entry { item.setData(data, forType: type) }
                    return item
                }
                pasteboard.writeObjects(items)
            }
        }
    }

    enum InjectionError: LocalizedError {
        case notTrusted
        case eventSourceUnavailable

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Accessibility access is required to type into other apps."
            case .eventSourceUnavailable:
                return "Could not create a keyboard event source."
            }
        }
    }
}
