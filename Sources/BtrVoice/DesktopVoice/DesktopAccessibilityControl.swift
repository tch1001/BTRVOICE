/// Turns model-selected, snapshot-local controls into native AX operations. Model
/// text never supplies a process, pointer, or arbitrary attribute to the executor.
import AppKit
import ApplicationServices

enum DesktopAXValueKind: String {
    case boolean, number, point, size, range, elements
}

struct DesktopUIInspection: Equatable {
    let scope: DesktopUIScope
    let snapshotID: String?
    let elementID: String?
    let offset: Int

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["scope", "snapshot_id", "element_id", "offset"]),
              let raw = arguments["scope"] as? String, let scope = DesktopUIScope(rawValue: raw),
              let offset = arguments["offset"] as? Int, (0...100_000).contains(offset),
              ["snapshot_id", "element_id"].allSatisfy({ arguments[$0] == nil || arguments[$0] is NSNull || arguments[$0] is String }) else {
            throw DesktopAXError.invalid("The UI inspection request is incomplete.")
        }
        self.scope = scope; self.offset = offset
        elementID = arguments["element_id"] as? String
        // A full fresh read has no target handle. Redundant snapshot metadata is
        // harmless here; a targeted or paged read still requires both real IDs.
        snapshotID = elementID == nil ? nil : arguments["snapshot_id"] as? String
        guard (snapshotID == nil) == (elementID == nil), offset == 0 || elementID != nil else {
            throw DesktopAXError.invalid("Inspect a container using both its snapshot and element IDs.")
        }
    }
}

enum DesktopAXValue: Equatable {
    case boolean(Bool), number(Double), point(Double, Double), size(Double, Double)
    case range(Int, Int), elements([String])

    static func decode(_ json: String, as kind: DesktopAXValueKind) throws -> Self {
        guard let data = json.data(using: .utf8), data.count <= 8_000,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw DesktopAXError.invalid("The control value is not valid JSON.")
        }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        switch kind {
        case .boolean:
            if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return .boolean(n.boolValue) }
        case .number:
            if let n = number(value) { return .number(n) }
        case .point, .size, .range:
            let keys = kind == .point ? ["x", "y"] : kind == .size ? ["width", "height"] : ["location", "length"]
            if let dict = value as? [String: Any], Set(dict.keys) == Set(keys),
               let a = number(dict[keys[0]]), let b = number(dict[keys[1]]) {
                if kind == .point, abs(a) <= 100_000, abs(b) <= 100_000 { return .point(a, b) }
                if kind == .size, a > 0, b > 0, a <= 100_000, b <= 100_000 { return .size(a, b) }
                if kind == .range, a >= 0, b >= 0, a + b <= Double(Int32.max), a.rounded() == a, b.rounded() == b {
                    return .range(Int(a), Int(b))
                }
            }
        case .elements:
            if let ids = value as? [String], ids.count <= 100, Set(ids).count == ids.count { return .elements(ids) }
        }
        throw DesktopAXError.invalid("That value does not match the control's \(kind.rawValue) format.")
    }
}

struct DesktopUICommand: Equatable {
    let snapshotID: String
    let elementID: String
    let action: String?
    let attribute: String?
    let valueJSON: String?
    var observation: String?

    init(snapshotID: String, elementID: String, action: String? = nil, attribute: String? = nil, valueJSON: String? = nil) {
        self.snapshotID = snapshotID; self.elementID = elementID
        self.action = action; self.attribute = attribute; self.valueJSON = valueJSON
    }

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).isSubset(of: ["snapshot_id", "element_id", "action", "attribute", "value_json", "observation"]),
              let snapshot = arguments["snapshot_id"] as? String, !snapshot.isEmpty,
              let element = arguments["element_id"] as? String, !element.isEmpty,
              ["action", "attribute", "value_json", "observation"].allSatisfy({ arguments[$0] == nil || arguments[$0] is NSNull || arguments[$0] is String }) else {
            throw DesktopAXError.invalid("The control request is incomplete.")
        }
        self.init(snapshotID: snapshot, elementID: element, action: arguments["action"] as? String,
                  attribute: arguments["attribute"] as? String, valueJSON: arguments["value_json"] as? String)
        observation = (arguments["observation"] as? String).map { String($0.prefix(3_000)) }
        guard (action != nil && attribute == nil && valueJSON == nil)
                || (action == nil && attribute != nil && valueJSON != nil) else {
            throw DesktopAXError.invalid("Request one action or one attribute change at a time.")
        }
    }

    func description(for element: DesktopAccessibilityElement?) -> String {
        let label = element.flatMap { $0.label.isEmpty ? nil : $0.label } ?? "control"
        let verb: String
        switch action ?? attribute {
        case "AXPress", DesktopAccessibilityClick.action: verb = "Press"
        case "AXPick", "AXSelected", "AXSelectedChildren", "AXSelectedRows": verb = "Select"
        case "AXShowMenu": verb = "Open menu for"
        case "AXRaise", "AXMain": verb = "Bring forward"
        case "AXIncrement": verb = "Increase"
        case "AXDecrement": verb = "Decrease"
        case "AXConfirm": verb = "Confirm"
        case "AXCancel": verb = "Cancel"
        case "AXFocused": verb = "Focus"
        case "AXExpanded": verb = valueJSON == "false" ? "Collapse" : "Expand"
        case "AXMinimized": verb = valueJSON == "false" ? "Restore" : "Minimize"
        case "AXFullScreen": verb = valueJSON == "false" ? "Leave full screen for" : "Enter full screen for"
        case "AXPosition": verb = "Move"
        case "AXSize": verb = "Resize"
        case "AXSelectedTextRange": verb = "Select text in"
        case "AXValue": return "Set “\(label)” to \(valueJSON ?? "the requested value")"
        default: verb = "Use"
        }
        return "\(verb) “\(label)”"
    }
}

enum DesktopAXError: LocalizedError {
    case invalid(String), stale, permission, unavailable, failed(AXError)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .stale: return "The app or control changed. Read the current screen again before acting."
        case .permission: return "Enable BtrVoice's Accessibility access in System Settings to control other apps."
        case .unavailable: return "This app does not expose that operation through Accessibility."
        case .failed(let code):
            return code == .cannotComplete
                ? "The app did not confirm the operation in time. It may have happened; inspect the screen before deciding what to do next."
                : "The app refused the Accessibility operation (\(code.rawValue))."
        }
    }
}

enum DesktopAccessibilityControl {
    /// Only advertise writes with a known non-text representation. Dictation text
    /// continues through BtrVoice's reviewed buffer and synthetic keyboard path.
    static func writableKinds(role: String) -> [String: DesktopAXValueKind] {
        var kinds: [String: DesktopAXValueKind] = [
            "AXFocused": .boolean, "AXSelected": .boolean, "AXExpanded": .boolean,
            "AXSelectedChildren": .elements, "AXSelectedRows": .elements,
        ]
        if role == "AXWindow" {
            kinds.merge(["AXMinimized": .boolean, "AXMain": .boolean, "AXFullScreen": .boolean,
                         "AXPosition": .point, "AXSize": .size], uniquingKeysWith: { _, new in new })
        }
        if ["AXSlider", "AXScrollBar", "AXIncrementor", "AXProgressIndicator", "AXSplitter"].contains(role) {
            kinds["AXValue"] = .number
        }
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) { kinds["AXSelectedTextRange"] = .range }
        return kinds
    }

    static func validate(_ command: DesktopUICommand, in context: DesktopAccessibilityContext,
                         activePID: pid_t?, now: Date = Date()) throws -> DesktopAccessibilityElement {
        guard command.snapshotID == context.snapshotID, now.timeIntervalSince(context.capturedAt) < 60,
              context.processIdentifier == activePID, activePID != nil,
              let element = context.elements[command.elementID] else { throw DesktopAXError.stale }
        guard element.enabled != false else { throw DesktopAXError.invalid("That control is disabled.") }
        if let action = command.action {
            guard command.attribute == nil, command.valueJSON == nil, element.actions.contains(action) else { throw DesktopAXError.unavailable }
        } else {
            guard let attribute = command.attribute, let kind = element.writable[attribute],
                  let json = command.valueJSON else { throw DesktopAXError.unavailable }
            let value = try DesktopAXValue.decode(json, as: kind)
            if case .number(let number) = value {
                if let min = element.minimum, number < min { throw DesktopAXError.invalid("The value is below the control's minimum.") }
                if let max = element.maximum, number > max { throw DesktopAXError.invalid("The value is above the control's maximum.") }
            }
            if case .boolean(false) = value, attribute == "AXFocused" { throw DesktopAXError.invalid("Focus another control instead.") }
            if case .range(let start, let length) = value, let count = element.characterCount, start + length > count {
                throw DesktopAXError.invalid("The selection extends past the field's text.")
            }
            if case .elements(let ids) = value {
                for id in ids {
                    var current = context.elements[id]
                    var visited = Set<String>()
                    while let entry = current, entry.parentID != element.id, visited.insert(entry.id).inserted {
                        current = entry.parentID.flatMap { context.elements[$0] }
                    }
                    guard current?.parentID == element.id else { throw DesktopAXError.invalid("Select only items belonging to this control.") }
                }
            }
        }
        return element
    }

    /// Runs off the main thread. Every OS message has a timeout; cancellation is
    /// checked again immediately before the single mutating call. Never retry it.
    static func execute(_ command: DesktopUICommand, in context: DesktopAccessibilityContext) throws -> String {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else { throw DesktopAXError.permission }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let focused = DesktopAccessibilityReader.elementAttribute("AXFocusedApplication", system) else { throw DesktopAXError.stale }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else { throw DesktopAXError.stale }
        // A non-activating BtrVoice command field may own keyboard focus while
        // macOS still reports the external application as frontmost.
        if pid == ProcessInfo.processInfo.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processIdentifier,
           let targetPID = context.processIdentifier {
            pid = targetPID
        }
        let target = try validate(command, in: context, activePID: pid)
        let ref = target.reference
        AXUIElementSetMessagingTimeout(ref, 0.3)
        guard AXUIElementGetPid(ref, &pid) == .success, pid == context.processIdentifier,
              DesktopAccessibilityReader.string("AXRole", ref) == target.role,
              DesktopAccessibilityReader.label(ref) == target.label,
              !DesktopAccessibilityReader.isSecure(ref),
              DesktopAccessibilityReader.attribute("AXEnabled", ref) as? Bool != false else { throw DesktopAXError.stale }
        if let window = context.window {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            guard let current = DesktopAccessibilityReader.focusedWindow(app), CFEqual(current, window) else { throw DesktopAXError.stale }
        }
        let result: AXError
        if let action = command.action {
            if action == DesktopAccessibilityClick.action {
                // The model cannot invent a mouse coordinate or widen this
                // adapter to arbitrary page text. Recheck the live list identity.
                guard DesktopTelegramSemantics.isItem(target, in: context, list: "Folders"),
                      NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.tdesktop.Telegram",
                      let parent = DesktopAccessibilityReader.elementAttribute("AXParent", ref),
                      DesktopAccessibilityReader.string("AXRole", parent) == "AXList",
                      DesktopAccessibilityReader.label(parent) == "Folders" else { throw DesktopAXError.unavailable }
                try DesktopAccessibilityClick.execute(target, in: context)
                return "Posted one click on the exact folder: \(target.label). Read the updated UI to verify; do not assume it opened."
            }
            guard DesktopAccessibilityReader.actions(ref).contains(action) else { throw DesktopAXError.unavailable }
            try Task.checkCancellation()
            result = AXUIElementPerformAction(ref, action as CFString)
        } else {
            guard let attribute = command.attribute, let kind = target.writable[attribute], let json = command.valueJSON,
                  DesktopAccessibilityReader.isSettable(attribute, ref) else { throw DesktopAXError.unavailable }
            let value = try DesktopAXValue.decode(json, as: kind)
            let native: CFTypeRef
            switch value {
            case .boolean(let flag): native = flag ? kCFBooleanTrue! : kCFBooleanFalse!
            case .number(let n): native = NSNumber(value: n)
            case .point(let x, let y):
                var point = CGPoint(x: x, y: y); native = AXValueCreate(.cgPoint, &point)!
            case .size(let width, let height):
                var size = CGSize(width: width, height: height); native = AXValueCreate(.cgSize, &size)!
            case .range(let start, let length):
                var range = CFRange(location: start, length: length); native = AXValueCreate(.cfRange, &range)!
            case .elements(let ids): native = ids.compactMap { context.elements[$0]?.reference } as CFArray
            }
            try Task.checkCancellation()
            result = AXUIElementSetAttributeValue(ref, attribute as CFString, native)
        }
        guard result == .success else { throw DesktopAXError.failed(result) }
        return "The app accepted: \(command.description(for: target)). Read the updated UI to verify the outcome."
    }
}
