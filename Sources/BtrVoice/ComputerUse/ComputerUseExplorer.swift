import AppKit
import ApplicationServices
import SwiftUI

/// A transparent Computer Use workbench: it explains the model's action surface,
/// inventories the frontmost app through macOS Accessibility, and keeps every real
/// UI action behind a confirmation so exploration cannot silently change user data.

private struct ComputerUseCapability: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let summary: String

    static let all: [ComputerUseCapability] = [
        .init(id: "screenshot", title: "Screenshot", symbol: "camera.viewfinder", summary: "Read the current visual state"),
        .init(id: "click", title: "Click", symbol: "cursorarrow.click", summary: "Click a point on screen"),
        .init(id: "double_click", title: "Double-click", symbol: "cursorarrow.rays", summary: "Double-click a point"),
        .init(id: "move", title: "Move", symbol: "arrow.up.left.and.arrow.down.right", summary: "Move the pointer"),
        .init(id: "drag", title: "Drag", symbol: "hand.draw", summary: "Drag across a path"),
        .init(id: "scroll", title: "Scroll", symbol: "scroll", summary: "Scroll vertically or horizontally"),
        .init(id: "type", title: "Type", symbol: "text.cursor", summary: "Enter text into a field"),
        .init(id: "keypress", title: "Keypress", symbol: "command", summary: "Press keys or shortcuts"),
        .init(id: "wait", title: "Wait", symbol: "clock", summary: "Pause while the UI changes"),
    ]
}

private enum ComputerUseElementKind: String, CaseIterable, Identifiable {
    case control
    case input
    case text
    case structure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "Controls"
        case .input: return "Text inputs"
        case .text: return "Visible text"
        case .structure: return "Structure"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "cursorarrow.click.2"
        case .input: return "character.cursor.ibeam"
        case .text: return "text.alignleft"
        case .structure: return "square.3.layers.3d"
        }
    }
}

private enum ComputerUseInventoryFilter: String, CaseIterable, Identifiable {
    case all
    case controls
    case inputs
    case text
    case structure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .controls: return "Controls"
        case .inputs: return "Inputs"
        case .text: return "Text"
        case .structure: return "Structure"
        }
    }

    func includes(_ kind: ComputerUseElementKind) -> Bool {
        switch self {
        case .all: return true
        case .controls: return kind == .control
        case .inputs: return kind == .input
        case .text: return kind == .text
        case .structure: return kind == .structure
        }
    }
}

private struct ComputerUseElementSnapshot: Identifiable, @unchecked Sendable {
    let id: Int
    let element: AXUIElement
    let kind: ComputerUseElementKind
    let label: String
    let detail: String?
    let role: String
    let subrole: String?
    let actions: [String]
    let frame: CGRect?
    let depth: Int
    let isVisible: Bool

    var searchText: String {
        ([label, detail, role, subrole] + actions)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

private struct ComputerUseScanResult: @unchecked Sendable {
    let elements: [ComputerUseElementSnapshot]
    let visitedCount: Int
    let wasTruncated: Bool
}

/// Reads the semantic UI tree that macOS exposes to assistive technologies. This
/// complements Computer Use's screenshots: it supplies inspectable labels, text,
/// roles, bounds, and native actions without sending the screen off the device.
private enum ComputerUseAccessibilityScanner {
    private static let fallbackTraversalAttributes = [
        "AXVisibleChildren", "AXRows", "AXColumns", "AXTabs",
    ]

    static func scan(processIdentifier: pid_t, limit: Int = 2_500) -> ComputerUseScanResult {
        let root = AXUIElementCreateApplication(processIdentifier)
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var cursor = 0
        var seen = Set<CFHashCode>()
        var snapshots: [ComputerUseElementSnapshot] = []

        while cursor < queue.count, seen.count < limit {
            let current = queue[cursor]
            cursor += 1

            let identity = CFHash(current.element)
            guard seen.insert(identity).inserted else { continue }

            let role = stringAttribute("AXRole", from: current.element) ?? "AXUnknown"
            let subrole = stringAttribute("AXSubrole", from: current.element)
            let secure = role.localizedCaseInsensitiveContains("secure")
                || subrole?.localizedCaseInsensitiveContains("secure") == true
            let title = stringAttribute("AXTitle", from: current.element)
            let description = stringAttribute("AXDescription", from: current.element)
            let help = stringAttribute("AXHelp", from: current.element)
            let value = secure ? "Secure text hidden" : stringAttribute("AXValue", from: current.element)
            let roleDescription = stringAttribute("AXRoleDescription", from: current.element)
            let actions = actionNames(for: current.element)
            let visible = boolAttribute("AXVisible", from: current.element) ?? true
            let frame = frame(for: current.element)
            let label = firstUseful([title, description, value, help, roleDescription])
                ?? humanize(role)
            let detail = firstUseful([value, description, help].filter { candidate in
                candidate?.trimmingCharacters(in: .whitespacesAndNewlines) != label
            })

            snapshots.append(ComputerUseElementSnapshot(
                id: snapshots.count,
                element: current.element,
                kind: classify(role: role, actions: actions),
                label: clipped(label, limit: 500),
                detail: detail.map { clipped($0, limit: 1_500) },
                role: role,
                subrole: subrole,
                actions: actions,
                frame: frame,
                depth: current.depth,
                isVisible: visible
            ))

            guard current.depth < 30 else { continue }
            var children = elementsAttribute("AXChildren", from: current.element)
            if current.depth == 0 {
                children += elementsAttribute("AXWindows", from: current.element)
                children += elementsAttribute("AXMenuBar", from: current.element)
            }
            if children.isEmpty {
                // A few custom controls omit AXChildren but expose one of these
                // equivalent collections. Stop at the first useful fallback to
                // avoid making seven cross-process calls for every ordinary node.
                for attribute in fallbackTraversalAttributes {
                    children = elementsAttribute(attribute, from: current.element)
                    if !children.isEmpty { break }
                }
            }
            for child in children {
                queue.append((child, current.depth + 1))
            }
        }

        return ComputerUseScanResult(
            elements: snapshots,
            visitedCount: seen.count,
            wasTruncated: cursor < queue.count
        )
    }

    private static func classify(role: String, actions: [String]) -> ComputerUseElementKind {
        let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        let textRoles: Set<String> = ["AXStaticText", "AXHeading", "AXLabel"]
        let controlRoles: Set<String> = [
            "AXButton", "AXCheckBox", "AXColorWell", "AXDisclosureTriangle", "AXLink",
            "AXMenuItem", "AXPopUpButton", "AXRadioButton", "AXSlider", "AXStepper",
            "AXTab", "AXToolbarButton",
        ]

        if inputRoles.contains(role) { return .input }
        // Some apps expose contextual actions even on static labels. Keep those in
        // the text bucket so the inventory summary remains meaningful; their
        // actions are still listed in the inspector.
        if textRoles.contains(role) { return .text }
        if controlRoles.contains(role) || !actions.isEmpty { return .control }
        return .structure
    }

    private static func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    private static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        guard let raw = copyAttribute(name, from: element) else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let attributed = raw as? NSAttributedString {
            let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
        copyAttribute(name, from: element) as? Bool
    }

    private static func elementsAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        guard let raw = copyAttribute(name, from: element),
              let values = raw as? [AXUIElement] else { return [] }
        return values
    }

    private static func actionNames(for element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names = names as? [String] else { return [] }
        return names.sorted()
    }

    private static func frame(for element: AXUIElement) -> CGRect? {
        guard let positionRaw = copyAttribute("AXPosition", from: element),
              let sizeRaw = copyAttribute("AXSize", from: element),
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func firstUseful(_ candidates: [String?]) -> String? {
        candidates.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }.first
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func humanize(_ token: String) -> String {
        let withoutPrefix = token.hasPrefix("AX") ? String(token.dropFirst(2)) : token
        var result = ""
        for character in withoutPrefix {
            if character.isUppercase,
               let last = result.last,
               !last.isWhitespace,
               !last.isUppercase {
                result.append(" ")
            }
            result.append(character)
        }
        return result.isEmpty ? token : result
    }
}

@MainActor
private final class ComputerUseExplorerModel: ObservableObject {
    @Published private(set) var elements: [ComputerUseElementSnapshot] = []
    @Published private(set) var targetName = "No target app"
    @Published private(set) var status = "Choose Start Computer Use while another app is active."
    @Published private(set) var isScanning = false
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published var query = ""
    @Published var filter: ComputerUseInventoryFilter = .all
    @Published var selectedID: Int?

    private var target: NSRunningApplication?
    private var scanGeneration = UUID()

    var filteredElements: [ComputerUseElementSnapshot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return elements.filter { element in
            filter.includes(element.kind) && (needle.isEmpty || element.searchText.contains(needle))
        }
    }

    var selectedElement: ComputerUseElementSnapshot? {
        guard let selectedID else { return nil }
        return elements.first { $0.id == selectedID }
    }

    func count(for kind: ComputerUseElementKind) -> Int {
        elements.lazy.filter { $0.kind == kind }.count
    }

    func setTarget(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else {
            target = nil
            targetName = "No target app"
            elements = []
            selectedID = nil
            status = "Open the menu from the app you want to inspect, then choose Start Computer Use."
            return
        }
        target = app
        targetName = app.localizedName ?? "PID \(app.processIdentifier)"
        rescan()
    }

    func rescan() {
        accessibilityGranted = Permissions.accessibilityGranted
        guard accessibilityGranted else {
            elements = []
            selectedID = nil
            status = "Accessibility access is required to read controls and visible text."
            return
        }
        guard let target, !target.isTerminated else {
            status = "The target app is no longer running."
            return
        }

        let generation = UUID()
        scanGeneration = generation
        let pid = target.processIdentifier
        isScanning = true
        status = "Scanning \(targetName)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = ComputerUseAccessibilityScanner.scan(processIdentifier: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.elements = result.elements
                self.selectedID = result.elements.first(where: {
                    $0.role == "AXButton"
                        && $0.isVisible
                        && ($0.frame?.width ?? 0) > 0
                        && ($0.frame?.height ?? 0) > 0
                        && !$0.actions.isEmpty
                })?.id
                    ?? result.elements.first(where: { !$0.actions.isEmpty })?.id
                    ?? result.elements.first?.id
                self.isScanning = false
                let suffix = result.wasTruncated ? " (first \(result.visitedCount); limit reached)" : ""
                self.status = "Found \(result.elements.count) accessible items\(suffix)."
            }
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    func perform(_ action: String, on snapshot: ComputerUseElementSnapshot) {
        guard let target, !target.isTerminated else {
            status = "The target app is no longer running."
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Run \(ComputerUseAccessibilityScanner.humanize(action)) in \(targetName)?"
        alert.informativeText = "Target: \(snapshot.label)\n\nThis is a real macOS Accessibility action and may change the app."
        alert.addButton(withTitle: "Run Action")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            let error = AXUIElementPerformAction(snapshot.element, action as CFString)
            DispatchQueue.main.async {
                guard let self else { return }
                if error == .success {
                    self.status = "Ran \(ComputerUseAccessibilityScanner.humanize(action)) on \(snapshot.label)."
                } else {
                    self.status = "macOS refused the action (Accessibility error \(error.rawValue))."
                }
            }
        }
    }
}

/// The first Computer Use demo deliberately shows the raw surface before product
/// decisions hide it: official model actions above, semantic app inventory below.
private struct ComputerUseExplorerView: View {
    @ObservedObject var model: ComputerUseExplorerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            capabilityStrip
            Divider()
            inventoryToolbar
            Divider()
            HSplitView {
                inventory
                    .frame(minWidth: 390, idealWidth: 500)
                inspector
                    .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 700, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.accentColor.opacity(0.14))
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Computer Use Explorer")
                    .font(.title3.weight(.semibold))
                Text("Inspecting \(model.targetName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning { ProgressView().controlSize(.small) }
            Button {
                model.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var capabilityStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Computer Use action catalog")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("9 model actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(ComputerUseCapability.all) { capability in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(capability.title, systemImage: capability.symbol)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(capability.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(width: 135, height: 48, alignment: .topLeading)
                        .padding(9)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(height: 76)
            Text("Catalog above is the OpenAI action surface. Inventory below is gathered locally from macOS Accessibility; no screen content is sent to OpenAI in this demo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var inventoryToolbar: some View {
        VStack(spacing: 8) {
            if !model.accessibilityGranted {
                HStack {
                    Label("Allow Accessibility access to inspect controls and text.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings") { model.requestAccessibility() }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                TextField("Filter controls and text", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Picker("Inventory", selection: $model.filter) {
                    ForEach(ComputerUseInventoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 112)
            }
            HStack(spacing: 14) {
                ForEach(ComputerUseElementKind.allCases) { kind in
                    Label("\(model.count(for: kind)) \(kind.title.lowercased())", systemImage: kind.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var inventory: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(ComputerUseElementKind.allCases) { kind in
                    let rows = model.filteredElements.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { snapshot in
                                inventoryRow(snapshot)
                            }
                        } header: {
                            HStack {
                                Label(kind.title, systemImage: kind.symbol)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(rows.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
                if model.filteredElements.isEmpty, !model.isScanning {
                    ContentUnavailableView(
                        model.elements.isEmpty ? "No accessible items" : "No matching items",
                        systemImage: "rectangle.and.text.magnifyingglass",
                        description: Text(model.status)
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func inventoryRow(_ snapshot: ComputerUseElementSnapshot) -> some View {
        Button {
            model.selectedID = snapshot.id
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: snapshot.kind.symbol)
                    .foregroundStyle(snapshot.actions.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(ComputerUseAccessibilityScanner.humanize(snapshot.role))
                        if !snapshot.actions.isEmpty {
                            Text("• \(snapshot.actions.count) action\(snapshot.actions.count == 1 ? "" : "s")")
                        }
                        if !snapshot.isVisible { Text("• hidden") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if !snapshot.actions.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                model.selectedID == snapshot.id ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
    }

    private var inspector: some View {
        ScrollView {
            if let snapshot = model.selectedElement {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Selected item", systemImage: snapshot.kind.symbol)
                        .font(.headline)
                    Text(snapshot.label)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)

                    if let detail = snapshot.detail, detail != snapshot.label {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Divider()
                    detailLine("Role", ComputerUseAccessibilityScanner.humanize(snapshot.role))
                    if let subrole = snapshot.subrole {
                        detailLine("Subrole", ComputerUseAccessibilityScanner.humanize(subrole))
                    }
                    detailLine("Visible", snapshot.isVisible ? "Yes" : "No")
                    detailLine("Tree depth", "\(snapshot.depth)")
                    if let frame = snapshot.frame {
                        detailLine(
                            "Bounds",
                            String(format: "x %.0f, y %.0f · %.0f × %.0f", frame.minX, frame.minY, frame.width, frame.height)
                        )
                    }

                    Divider()
                    Text("Available macOS actions")
                        .font(.subheadline.weight(.semibold))
                    if snapshot.actions.isEmpty {
                        Text("This item exposes information, but no direct Accessibility action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.actions, id: \.self) { action in
                            Button {
                                model.perform(action, on: snapshot)
                            } label: {
                                HStack {
                                    Text(ComputerUseAccessibilityScanner.humanize(action))
                                    Spacer()
                                    Image(systemName: "play.fill")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Every real action asks for confirmation before it runs.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                ContentUnavailableView(
                    "Select an item",
                    systemImage: "cursorarrow.click",
                    description: Text("Choose a control or text row to inspect its details and actions.")
                )
                .padding(.vertical, 40)
            }
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: model.isScanning ? "arrow.triangle.2.circlepath" : "info.circle")
                .foregroundStyle(.secondary)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("Local discovery demo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// Owns one resizable explorer window and preserves the inspected app even after
/// BtrVoice becomes frontmost to show the window.
@MainActor
final class ComputerUseWindowController: NSObject, NSWindowDelegate {
    static let shared = ComputerUseWindowController()

    private var window: NSWindow?
    private var model: ComputerUseExplorerModel?
    private var lastTarget: NSRunningApplication?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func show(target: NSRunningApplication?) {
        if let target, target.processIdentifier != selfPID, !target.isTerminated {
            lastTarget = target
        }
        let resolvedTarget = lastTarget

        if let window, let model {
            model.setTarget(resolvedTarget)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = ComputerUseExplorerModel()
        self.model = model
        let hosting = NSHostingController(rootView: ComputerUseExplorerView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "BtrVoice Computer Use"
        window.setContentSize(NSSize(width: 860, height: 720))
        window.minSize = NSSize(width: 700, height: 560)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        model.setTarget(resolvedTarget)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        window = nil
    }
}
