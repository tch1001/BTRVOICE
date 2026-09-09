/// Reads the active window's semantic text and controls without changing focus or UI.
/// Work is bounded because another application's accessibility server can stop replying.
import ApplicationServices
import Foundation

struct DesktopAccessibilityContext {
    let text: String
    let elementCount: Int
    let truncated: Bool
    var snapshotID = UUID().uuidString
    var capturedAt = Date()
    var processIdentifier: pid_t?
    var window: AXUIElement?
    var elements: [String: DesktopAccessibilityElement] = [:]

    static let empty = DesktopAccessibilityContext(text: "", elementCount: 0, truncated: false)
}

struct DesktopAccessibilityElement {
    let id: String
    let reference: AXUIElement
    var parentID: String?
    let role: String
    let label: String
    let actions: [String]
    let writable: [String: DesktopAXValueKind]
    let enabled: Bool?
    var minimum: Double?
    var maximum: Double?
    var characterCount: Int?
    var value: String?
    var selected: Bool?
}

enum DesktopUIScope: String { case window, menus, windows }

enum DesktopAccessibilityReader {
    enum Purpose { case controls, content, tabs }
    static func describe(role: String, label: String, value: String?, actions: [String],
                         enabled: Bool?, secure: Bool) -> String {
        guard !secure else { return "\(role): [secure text hidden]" }
        var fields = ["\(role): \(String(label.prefix(500)))"]
        if let value, !value.isEmpty, value != label { fields.append(String(value.prefix(1800))) }
        if enabled == false { fields.append("disabled") }
        if !actions.isEmpty { fields.append("available actions: \(actions.joined(separator: ", "))") }
        return fields.joined(separator: " | ")
    }

    static func read(processIdentifier: pid_t, scope: DesktopUIScope = .window,
                     root: AXUIElement? = nil, offset: Int = 0, purpose: Purpose = .controls) -> DesktopAccessibilityContext {
        guard AXIsProcessTrusted() else { return .empty }
        let deadline = Date().addingTimeInterval(2)
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        // Menus and freshly launched apps can temporarily omit focused/main
        // window even though their visible window still exists.
        let window = focusedWindow(app)
        let windowFrame = window.flatMap { frame($0) }
        var roots: [AXUIElement]
        if let root {
            var pid: pid_t = 0
            guard AXUIElementGetPid(root, &pid) == .success, pid == processIdentifier else { return .empty }
            roots = [root]
        }
        else if purpose == .tabs {
            roots = Array((attribute("AXWindows", app) as? [AXUIElement] ?? []).prefix(20))
        } else {
            switch scope {
            case .window:
                roots = [window, elementAttribute("AXFocusedUIElement", app)].compactMap { $0 }
            case .menus:
                roots = [elementAttribute("AXMenuBar", app), elementAttribute("AXFocusedUIElement", app)].compactMap { $0 }
            case .windows:
                roots = attribute("AXWindows", app) as? [AXUIElement] ?? []
            }
        }
        guard !roots.isEmpty else { return .empty }
        var queue: [(AXUIElement, Int, String?)] = roots.map { ($0, 0, nil) }
        var seen = Set<AXUIElement>()
        var cursor = 0
        var lines: [String] = []
        var characters = 0
        var elements: [String: DesktopAccessibilityElement] = [:]

        var traversalClipped = false
        while cursor < queue.count, seen.count < 500, characters < 32_000, Date() < deadline, !Task.isCancelled {
            let (element, depth, parentID) = queue[cursor]
            cursor += 1
            guard seen.insert(element).inserted else { continue }
            AXUIElementSetMessagingTimeout(element, 0.15)
            let values = attributes(["AXRole", "AXSubrole", "AXProtected", "AXHidden", "AXVisible",
                "AXTitle", "AXDescription", "AXHelp", "AXEnabled"], element)
            guard values["AXHidden"] as? Bool != true,
                  values["AXVisible"] as? Bool != false else { continue }
            if purpose != .tabs, scope == .window, root == nil, let bounds = frame(element), let windowFrame,
               !bounds.isEmpty, !bounds.intersects(windowFrame) { continue }
            let role = text(values["AXRole"]) ?? "AXUnknown"
            // Tab enumeration must not spend its entire budget walking page text.
            if purpose == .tabs, role == "AXWebArea" { continue }
            if (role + (text(values["AXSubrole"]) ?? "")).localizedCaseInsensitiveContains("secure")
                || values["AXProtected"] as? Bool == true {
                let line = describe(role: role, label: "", value: nil, actions: [], enabled: nil, secure: true)
                lines.append(line)
                characters += line.count + 1
                continue // Never read the value or descend into a protected control.
            }
            let label = text(values["AXTitle"]) ?? text(values["AXDescription"]) ?? text(values["AXHelp"]) ?? ""
            // The value batch happens only after the secure-field check.
            let stateNamesToRead = purpose == .controls ? ["AXValue", "AXMinValue", "AXMaxValue", "AXNumberOfCharacters",
                "AXSelected", "AXFocused", "AXExpanded", "AXMinimized", "AXOrientation", "AXValueDescription",
                "AXSelectedText", "AXSelectedTextRange", "AXURL", "AXDocument"] : ["AXValue", "AXSelected", "AXURL", "AXDocument"]
            let state = attributes(stateNamesToRead, element)
            let value = text(state["AXValue"])
            let actions = purpose == .controls || ["AXRow", "AXCell", "AXTab", "AXRadioButton", "AXButton", "AXWindow"].contains(role) ? actions(element) : []
            let names = purpose == .controls ? attributeNames(element) : []
            let writable = DesktopAccessibilityControl.writableKinds(role: role).filter {
                names.contains($0.key) && isSettable($0.key, element)
            }
            let id = "e\(elements.count + 1)"
            let enabled = values["AXEnabled"] as? Bool
            var entry = DesktopAccessibilityElement(id: id, reference: element, parentID: parentID,
                role: role, label: label, actions: actions, writable: writable, enabled: enabled)
            entry.value = value.map { String($0.prefix(5_000)) }
            entry.selected = (state["AXSelected"] as? Bool)
                ?? (role == "AXRadioButton" ? state["AXValue"] as? Bool : nil)
            if DesktopAccessibilityControl.writableKinds(role: role)["AXValue"] == .number {
                entry.minimum = (state["AXMinValue"] as? NSNumber)?.doubleValue
                entry.maximum = (state["AXMaxValue"] as? NSNumber)?.doubleValue
            }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) {
                entry.characterCount = (state["AXNumberOfCharacters"] as? NSNumber)?.intValue
            }
            elements[id] = entry
            var line = "[\(id)\(parentID.map { " parent=" + $0 } ?? "")] "
                + describe(role: role, label: label, value: value, actions: actions, enabled: enabled, secure: false)
            if ["AXWebArea", "AXWindow"].contains(role), let document = text(state["AXURL"]) ?? text(state["AXDocument"]) {
                line += " | document URL: " + String(document.prefix(2_000))
            }
            if !writable.isEmpty {
                line += " | writable: " + writable.keys.sorted().map { "\($0)=\(writable[$0]!.rawValue)" }.joined(separator: ", ")
            }
            var stateNames = ["AXValueDescription"]
            if ["AXRow", "AXCell", "AXRadioButton", "AXCheckBox", "AXTab", "AXMenuItem"].contains(role) { stateNames.append("AXSelected") }
            if state["AXFocused"] as? Bool == true { stateNames.append("AXFocused") }
            if ["AXRow", "AXDisclosureTriangle", "AXPopUpButton", "AXMenuItem"].contains(role) { stateNames.append("AXExpanded") }
            if role == "AXWindow" { stateNames.append("AXMinimized") }
            if ["AXSlider", "AXScrollBar", "AXSplitter"].contains(role) { stateNames.append("AXOrientation") }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) { stateNames.append("AXSelectedText") }
            for name in stateNames {
                if let value = text(state[name]) { line += " | \(name)=\(String(value.prefix(1800)))" }
            }
            if let selectedRange = state["AXSelectedTextRange"], CFGetTypeID(selectedRange as CFTypeRef) == AXValueGetTypeID() {
                var range = CFRange()
                if AXValueGetValue(selectedRange as! AXValue, .cfRange, &range) {
                    line += " | selection: location=\(range.location) length=\(range.length)"
                }
            }
            if let min = entry.minimum { line += " | min=\(min)" }
            if let max = entry.maximum { line += " | max=\(max)" }
            if let count = entry.characterCount { line += " | characters=\(count)" }
            if role == "AXWindow", let bounds = frame(element) {
                line += " | x=\(bounds.minX) y=\(bounds.minY) width=\(bounds.width) height=\(bounds.height)"
            }
            lines.append(line)
            characters += line.count + 1
            if purpose != .tabs, scope == .windows, depth >= 1 { continue }
            guard depth < 24 else { traversalClipped = true; continue }
            // Prefer visible children. Paging bounds custom apps with enormous trees.
            for name in ["AXVisibleChildren", "AXChildren", "AXRows", "AXTabs", "AXContents"] {
                var raw: CFArray?
                let start = depth == 0 ? offset : 0
                if AXUIElementCopyAttributeValues(element, name as CFString, start, 500, &raw) == .success,
                   let children = raw as? [AXUIElement], !children.isEmpty {
                    let remaining = max(0, 1_000 - queue.count)
                    if children.count == 500 || children.count > remaining { traversalClipped = true }
                    queue.append(contentsOf: children.prefix(remaining).map { ($0, depth + 1, id) })
                    break
                }
            }
        }
        // A focused row/field can be visited as a root before its container. Repair
        // that relationship so selected-rows/children validation still works.
        let idsByReference = Dictionary(uniqueKeysWithValues: elements.values.map { ($0.reference, $0.id) })
        for container in elements.values.filter({ ["AXTabGroup", "AXList", "AXOutline", "AXTable"].contains($0.role) }) {
            guard Date() < deadline, !Task.isCancelled else { traversalClipped = true; break }
            for name in ["AXSelectedChildren", "AXSelectedRows"] {
                for child in attribute(name, container.reference) as? [AXUIElement] ?? [] {
                    if let id = idsByReference[child] { elements[id]?.selected = true }
                }
            }
        }
        for entry in elements.values.filter({ $0.parentID == nil }) {
            guard Date() < deadline, !Task.isCancelled else { traversalClipped = true; break }
            if let parent = elementAttribute("AXParent", entry.reference), let parentID = idsByReference[parent] {
                elements[entry.id]?.parentID = parentID
                if let lineIndex = lines.firstIndex(where: { $0.hasPrefix("[\(entry.id)] ") }) {
                    lines[lineIndex] = lines[lineIndex].replacingOccurrences(of: "[\(entry.id)] ", with: "[\(entry.id) parent=\(parentID)] ")
                }
            }
        }
        let truncated = traversalClipped || cursor < queue.count || characters >= 32_000 || Date() >= deadline
        var text = lines.joined(separator: "\n")
        if truncated { text += "\n[Partial view: inspect a specific container to read more. Child offsets are zero-based.]" }
        var context = DesktopAccessibilityContext(text: text, elementCount: lines.count, truncated: truncated)
        context.processIdentifier = processIdentifier
        context.window = scope == .windows ? nil : window
        context.elements = elements
        return context
    }

    static func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func attributes(_ names: [String], _ element: AXUIElement) -> [String: Any] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
              let values = raw as? [Any], values.count == names.count else {
            // A few older/custom apps implement only individual attribute reads.
            return names.reduce(into: [:]) { result, name in result[name] = attribute(name, element) }
        }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }

    static func elementAttribute(_ name: String, _ element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        elementAttribute("AXFocusedWindow", app) ?? elementAttribute("AXMainWindow", app)
            ?? (attribute("AXWindows", app) as? [AXUIElement])?.first(where: { attribute("AXMinimized", $0) as? Bool != true })
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        ((string("AXRole", element) ?? "") + (string("AXSubrole", element) ?? "")).localizedCaseInsensitiveContains("secure")
            || attribute("AXProtected", element) as? Bool == true
    }

    static func label(_ element: AXUIElement) -> String {
        string("AXTitle", element) ?? string("AXDescription", element) ?? string("AXHelp", element) ?? ""
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        AXUIElementCopyActionNames(element, &raw)
        return raw as? [String] ?? []
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        AXUIElementCopyAttributeNames(element, &raw)
        return raw as? [String] ?? []
    }

    static func isSettable(_ name: String, _ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    static func string(_ name: String, _ element: AXUIElement) -> String? {
        guard let value = attribute(name, element) else { return nil }
        return text(value)
    }

    private static func text(_ value: Any?) -> String? {
        let text: String?
        if let value = value as? String { text = value }
        else if let value = value as? NSAttributedString { text = value.string }
        else if let value = value as? NSNumber { text = value.stringValue }
        else if let value = value as? URL { text = value.absoluteString }
        else { text = nil }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute("AXPosition", element), let size = attribute("AXSize", element),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
