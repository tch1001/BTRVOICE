/// Exercises real cross-process AX messages against a disposable native window,
/// never against the user's documents, chats, or browser tabs.
import AppKit
import ApplicationServices

@MainActor
enum DesktopAccessibilityIntegrationTest {
    private static var fixture: AccessibilityFixture?

    static func showFixture() {
        NSApplication.shared.setActivationPolicy(.regular)
        fixture = AccessibilityFixture()
        NSApplication.shared.run()
    }

    static func run(checkModel: Bool = false) async -> Int32 {
        guard AXIsProcessTrusted() else { print("Accessibility test requires the existing Accessibility permission."); return 1 }
        let previous = NSWorkspace.shared.frontmostApplication
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--accessibility-fixture"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { print(error.localizedDescription); return 1 }
        defer { if process.isRunning { process.terminate() }; previous?.activate(options: []) }
        let pid = process.processIdentifier
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "ok" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func read(_ scope: DesktopUIScope = .window) async -> DesktopAccessibilityContext {
            await Task.detached { DesktopAccessibilityReader.read(processIdentifier: pid, scope: scope) }.value
        }
        func find(_ context: DesktopAccessibilityContext, label: String, role: String? = nil) throws -> DesktopAccessibilityElement {
            let matches = context.elements.values.filter { $0.label == label && (role == nil || $0.role == role) }
            guard matches.count == 1, let element = matches.first else {
                throw DesktopAXError.invalid("Expected one fixture control: \(label); found \(matches.count). Inventory:\n\(context.text)")
            }
            return element
        }
        func execute(_ context: DesktopAccessibilityContext, element: DesktopAccessibilityElement,
                     action: String? = nil, attribute: String? = nil, json: String? = nil) async throws {
            let command = DesktopUICommand(snapshotID: context.snapshotID, elementID: element.id,
                action: action, attribute: attribute, valueJSON: json)
            do { _ = try await Task.detached { try DesktopAccessibilityControl.execute(command, in: context) }.value }
            catch {
                if case DesktopAXError.stale = error {
                    let system = AXUIElementCreateSystemWide()
                    var actualPID: pid_t = 0
                    if let focused = DesktopAccessibilityReader.elementAttribute("AXFocusedApplication", system) { AXUIElementGetPid(focused, &actualPID) }
                    print("Fixture focus: expected=\(pid), workspace=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), accessibility=\(actualPID)")
                    print("Fixture control identity: role=\(DesktopAccessibilityReader.string("AXRole", element.reference) == element.role), label=\(DesktopAccessibilityReader.label(element.reference) == element.label)")
                }
                throw error
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        do {
            let deadline = Date().addingTimeInterval(6)
            func hasFocus() -> Bool {
                let system = AXUIElementCreateSystemWide()
                var current: pid_t = 0
                if let app = DesktopAccessibilityReader.elementAttribute("AXFocusedApplication", system) { AXUIElementGetPid(app, &current) }
                return current == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }
            while !hasFocus(), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard hasFocus() else { throw DesktopAXError.invalid("The fixture did not become the foreground app; no controls were operated.") }
            var context = await read()
            while !context.elements.values.contains(where: { $0.label == "Unread" }), Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                context = await read()
            }
            if let application = NSRunningApplication(processIdentifier: pid) {
                let collection = try await DesktopCollectionReader.collect(
                    .init(kind: .browserTabs, limit: 5, includeContent: false), application: "Native fixture",
                    backend: DesktopCollectionReader.liveBackend(application: application, token: DesktopVoiceCancellation(), trace: nil, turnID: nil))
                check("native tab collection reads exposed titles without a model", Set(collection.items.map(\.title)) == ["Research", "Shopping"])
                if Set(collection.items.map(\.title)) != ["Research", "Shopping"] {
                    let tabs = await Task.detached { DesktopAccessibilityReader.read(processIdentifier: pid, purpose: .tabs) }.value
                    print("Fixture tabs: \(collection.json)\n\(tabs.text)")
                }
            }
            let unread = try find(context, label: "Unread", role: "AXCheckBox")
            try await execute(context, element: unread, action: "AXPress")
            context = await read()
            check("pressing an exposed control updates the other process", context.text.contains("Unread selected"))
            let slider = try find(context, label: "Test volume", role: "AXSlider")
            try await execute(context, element: slider, attribute: "AXValue", json: "75")
            context = await read()
            let updated = try find(context, label: "Test volume", role: "AXSlider")
            check("a writable slider changes through AX", DesktopAccessibilityReader.string("AXValue", updated.reference) == "75")
            let field = try find(context, label: "Test search", role: "AXTextField")
            try await execute(context, element: field, attribute: "AXFocused", json: "true")
            context = await read()
            let focused = try find(context, label: "Test search", role: "AXTextField")
            check("focus moves to the requested field", DesktopAccessibilityReader.attribute("AXFocused", focused.reference) as? Bool == true)
            try await execute(context, element: focused, attribute: "AXSelectedTextRange", json: "{\"location\":0,\"length\":5}")
            context = await read()
            let selected = try find(context, label: "Test search", role: "AXTextField")
            check("text selection works without inserting text", DesktopAccessibilityReader.string("AXSelectedText", selected.reference) == "hello")
            let disabled = try find(context, label: "Disabled control", role: "AXButton")
            do {
                try await execute(context, element: disabled, action: "AXPress")
                check("disabled controls stay blocked", false)
            } catch { check("disabled controls stay blocked", true) }
            context = await read(.windows)
            let window = try find(context, label: "BtrVoice Accessibility Test", role: "AXWindow")
            try await execute(context, element: window, attribute: "AXSize", json: "{\"width\":640,\"height\":420}")
            context = await read(.windows)
            check("windows can be resized through their exposed attributes", context.text.contains("width=640.0 height=420.0"))
            context = await read(.menus)
            let menu = try find(context, label: "Test Menu", role: "AXMenuBarItem")
            try await execute(context, element: menu, action: "AXPress")
            context = await read(.menus)
            let item = try find(context, label: "Show details", role: "AXMenuItem")
            try await execute(context, element: item, action: "AXPress")
            context = await read()
            let menuDeadline = Date().addingTimeInterval(2)
            while !context.text.contains("Details selected"), Date() < menuDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                context = await read()
            }
            check("menu discovery and menu-item activation work across processes", context.text.contains("Details selected"))
            let control = try find(context, label: "Unread", role: "AXCheckBox")
            let cancelledContext = context
            let pending = Task.detached {
                try await Task.sleep(nanoseconds: 500_000_000)
                return try DesktopAccessibilityControl.execute(DesktopUICommand(snapshotID: cancelledContext.snapshotID,
                    elementID: control.id, action: "AXPress"), in: cancelledContext)
            }
            pending.cancel()
            do { _ = try await pending.value; check("cancelled work does not reach an AX action", false) }
            catch { check("cancelled work does not reach an AX action", true) }
            if checkModel {
                let assistant = DesktopVoiceAssistant(resolveApplication: { _ in nil })
                let request = "Set the Test volume slider to 35."
                var conversation = DesktopVoiceAssistant.Context(targetName: "BtrVoice Accessibility Test", recentActivity: [])
                let first = try await assistant.respond(to: request, context: conversation)
                guard first == .beginUIControl else { throw DesktopAXError.invalid("The model did not start a UI task: \(first)") }
                context = await read()
                conversation.allowsUIActions = true
                var screen = DesktopScreenSnapshot(jpeg: nil, width: 0, height: 0, displayID: 0,
                    application: "BtrVoice Accessibility Test", capturedAt: Date(), accessibility: context)
                let next = try await assistant.respond(to: request, context: conversation, screen: screen,
                    toolResult: "Started the UI task and read the current fixture controls.")
                guard case .controlUI(let command) = next else { throw DesktopAXError.invalid("The model did not choose a control: \(next)") }
                // This model-backed check may affect only the designated fixture slider.
                let testSlider = try find(context, label: "Test volume", role: "AXSlider")
                guard command.elementID == testSlider.id, command.attribute == "AXValue", command.valueJSON == "35" else {
                    throw DesktopAXError.invalid("The model selected an unexpected fixture action.")
                }
                let before = context
                check("the model preserves the current snapshot identifier", command.snapshotID == context.snapshotID)
                check("the fixture remains foreground before the model-selected action", NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
                let result = try await Task.detached { try DesktopAccessibilityControl.execute(command, in: before) }.value
                context = await read()
                conversation.recentActivity = ["Executed UI operation: " + result]
                screen.accessibility = context
                let final = try await assistant.respond(to: request, context: conversation, screen: screen, toolResult: result)
                if case .answer = final { check("the model acts on a native control and answers after verifying the new value", true) }
                else { check("the model acts on a native control and answers after verifying the new value", false) }
                check("the model-requested numeric value reached the fixture",
                    DesktopAccessibilityReader.string("AXValue", try find(context, label: "Test volume", role: "AXSlider").reference) == "35")
                let historyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("btrvoice-ax-history-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: historyDirectory) }
                let coordinator = DesktopVoiceCoordinator(history: DesktopVoiceHistoryStore(directory: historyDirectory))
                coordinator.setTarget(NSRunningApplication(processIdentifier: pid))
                coordinator.submit("Press Command-A in the current app, then tell me what text is selected.", source: "integration test")
                let finishBy = Date().addingTimeInterval(55)
                while coordinator.isCommandRunning, Date() < finishBy {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if coordinator.isCommandRunning { coordinator.stop() }
                let replies = coordinator.activities.filter { $0.kind == .answer }.map(\.title).joined(separator: " ")
                let completed = coordinator.activities.contains { $0.kind == .success }
                        && !coordinator.activities.contains { $0.kind == .failure }
                        && replies.localizedCaseInsensitiveContains("hello world")
                check("the actual coordinator completes an action and its follow-up screen question in one turn", completed)
                if !completed {
                    print("Coordinator result: \(coordinator.status)")
                    for activity in coordinator.activities { print("\(activity.kind): \(activity.title) \(String((activity.detail ?? "").prefix(300)))") }
                }
            }
        } catch {
            print("FAIL native Accessibility integration: \(error.localizedDescription)")
            failures += 1
        }
        print(failures == 0 ? "Native Accessibility tests passed." : "\(failures) native Accessibility checks failed.")
        return failures == 0 ? 0 : 1
    }
}

@MainActor
private final class AccessibilityFixture: NSObject {
    private let window = NSWindow(contentRect: NSRect(x: 150, y: 180, width: 520, height: 470),
        styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    private let state = NSTextField(labelWithString: "Ready")

    override init() {
        super.init()
        window.title = "BtrVoice Accessibility Test"
        window.isReleasedWhenClosed = false
        let unread = NSButton(checkboxWithTitle: "Unread", target: self, action: #selector(pressUnread))
        let disabled = NSButton(title: "Disabled control", target: self, action: #selector(pressUnread))
        disabled.isEnabled = false
        let slider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.setAccessibilityLabel("Test volume")
        let field = NSTextField(string: "hello world")
        field.setAccessibilityLabel("Test search")
        let tabs = NSTabView()
        for title in ["Research", "Shopping"] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = NSTextField(labelWithString: "Synthetic \(title) page")
            tabs.addTabViewItem(item)
        }
        tabs.heightAnchor.constraint(equalToConstant: 85).isActive = true
        tabs.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let stack = NSStackView(views: [unread, disabled, slider, field, state, tabs])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
        ])
        let bar = NSMenu()
        let appMenu = NSMenuItem(title: "BtrVoice", action: nil, keyEquivalent: "")
        appMenu.submenu = NSMenu(title: "BtrVoice")
        bar.addItem(appMenu)
        let parent = NSMenuItem(title: "Test Menu", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Test Menu")
        let details = NSMenuItem(title: "Show details", action: #selector(showDetails), keyEquivalent: "")
        details.target = self; menu.addItem(details); parent.submenu = menu; bar.addItem(parent)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.submenu = editMenu; bar.addItem(edit)
        NSApplication.shared.mainMenu = bar
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func pressUnread() { state.stringValue = "Unread selected" }
    @objc private func showDetails() { state.stringValue = "Details selected" }
}
