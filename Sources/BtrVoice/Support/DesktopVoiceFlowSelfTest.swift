/// Replays misnavigation, repeated presses, corrections and text approval with fake desktop effects.
/// No windows, microphone, user applications, screenshots or network are used by these checks.
import AppKit
import ApplicationServices

enum DesktopVoiceFlowSelfTest {
    static func pure(check: (String, Bool) -> Void) {
        check("repeated spoken no interrupts despite punctuation and filler", DesktopVoiceUtterance.isInterruption("You go to no, no, no, no"))
        check("a trailing string of no does not become another navigation request", DesktopVoiceUtterance.isPauseOnly("You go to no, no, no, no"))
        check("a correction with its replacement is not discarded", DesktopVoiceUtterance.isInterruption("No, go to courses within this website") && !DesktopVoiceUtterance.isPauseOnly("No, go to courses within this website"))
        check("ordinary sentences containing no are not cancellation", !DesktopVoiceUtterance.isInterruption("There are no unread chats"))
        let memory = DesktopVoiceTaskMemory(request: "Go through the courses in Canvas")
        check("go ahead resolves to the actual ongoing user task", memory.resumedRequest(for: "Yeah, go ahead.") == memory.request)
        check("a different request does not silently inherit authorization", memory.resumedRequest(for: "What is on the screen?") == nil)
        check("old task approval expires", memory.resumedRequest(for: "go ahead", now: Date().addingTimeInterval(700)) == nil)
        let original = "[e1] AXButton: Courses | AXFocused=1\n[e2] AXStaticText: Canvas"
        let renumbered = "[e8] AXStaticText: Canvas\n[e9 parent=e4] AXButton: Courses"
        check("new snapshot IDs and focus do not count as content progress", DesktopVoiceProgress.content(original) == DesktopVoiceProgress.content(renumbered))
        var progress = DesktopVoiceProgress()
        check("a first operation is allowed", progress.willAct(key: "Courses", screen: original))
        progress.observe(renumbered)
        check("unchanged content cannot support a success claim", !progress.canConfirmCompletion)
        check("repeating the same operation is blocked", !progress.willAct(key: "Courses", screen: renumbered))
        progress.observe(renumbered + "\nAXHeading: All courses\nAXLink: Introductory Computing")
        check("new course contents are evidence of progress", progress.canConfirmCompletion)
        check("a repeat can be useful after the content changes", progress.willAct(key: "Courses", screen: renumbered + "\nAXHeading: Another page"))
        check("returning to the earlier state does not restart the same loop", !progress.willAct(key: "Courses", screen: original))
        check("website URLs are accepted without spelling shortcuts", (try? DesktopVoiceNavigation.url("https://canvas.nus.edu.sg/courses"))?.host == "canvas.nus.edu.sg")
        for address in ["javascript:alert(1)", "file:///tmp/a", "https://name:secret@example.com", "not a URL"] {
            check("navigation rejects non-web or credential URLs: \(address)", (try? DesktopVoiceNavigation.url(address)) == nil)
        }
        let token = DesktopVoiceCancellation(); token.cancel()
        check("cancellation reaches keyboard workers", token.isCancelled)
        let specs: [[String: Any]] = ["c", "a", "n", "v", "a", "s"].map { ["type": "shortcut", "shortcut": $0] }
        let call: [String: Any] = ["output": [["type": "function_call", "name": "run_desktop_plan",
            "arguments": ["summary": "Type complete address", "actions": specs, "continue_after": false]]]]
        check("the model cannot substitute six letter presses for complete text", (try? DesktopVoiceAssistant.interpret(call, resolveApplication: { _ in nil })) == nil)
        let request = DesktopVoiceAssistant.requestBody(utterance: "go ahead", context: .init(targetName: "Fixture", recentActivity: [], ongoingTask: memory.request), screen: nil, learnedSkills: [])
        check("the model sees the ongoing task explicitly", (request["input"] as? String)?.contains(memory.request) == true)
        let prior: [[String: Any]] = [["type": "function_call", "call_id": "one", "name": "open_url", "arguments": "{}"], ["type": "function_call_output", "call_id": "one", "output": "Opened address"]]
        let continued = DesktopVoiceAssistant.continuing(request,
            output: [["type": "function_call", "call_id": "two", "name": "control_ui", "arguments": "{}"]], result: "Pressed Courses", prior: prior)
        let items = continued["input"] as? [[String: Any]] ?? []
        check("continuations preserve earlier calls and matching results", items.contains { $0["call_id"] as? String == "one" && $0["type"] as? String == "function_call_output" } && items.contains { $0["call_id"] as? String == "two" && $0["type"] as? String == "function_call_output" })
    }

    @MainActor
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("btrvoice-flow-\(UUID().uuidString)")
        var text = "[e1] AXButton: Courses | available actions: AXPress\n[e2] AXTextField: Search"
        var presses = 0
        var plans = 0
        var addresses: [URL] = []
        var insertions: [(String, Bool)] = []
        var slowControl = false
        var staleControls = 0
        var afterPress: String?
        var lastContext: DesktopVoiceAssistant.Context?
        var collect: ((DesktopCollectionRequest) async throws -> DesktopReadingCollection)?
        var resolveApplication: (String) -> DesktopVoiceApplicationTarget? = { _ in nil }
        var respond: ((String, DesktopVoiceAssistant.Context, DesktopScreenSnapshot?, String?) async throws -> DesktopVoiceAssistantDecision)!

        func snapshot() -> DesktopScreenSnapshot {
            let ref = AXUIElementCreateApplication(42)
            var ax = DesktopAccessibilityContext(text: text, elementCount: 2, truncated: false)
            ax.processIdentifier = 42
            ax.elements["e1"] = .init(id: "e1", reference: ref, parentID: nil, role: "AXButton", label: "Courses", actions: ["AXPress"], writable: [:], enabled: true)
            ax.elements["e2"] = .init(id: "e2", reference: ref, parentID: nil, role: "AXTextField", label: "Search", actions: [], writable: ["AXFocused": .boolean], enabled: true)
            return DesktopScreenSnapshot(jpeg: nil, width: 0, height: 0, displayID: 0, application: "Fixture", capturedAt: Date(), accessibility: ax, imageUnavailable: "This test supplies structured controls only.")
        }

        func coordinator() -> DesktopVoiceCoordinator {
            let dependencies = DesktopVoiceDependencies(targetPID: 42, resolveApplication: resolveApplication,
                respond: { [self] command, context, screen, result in
                    lastContext = context
                    return try await respond(command, context, screen, result)
                }, read: { [self] _, _, _, _ in snapshot() },
                control: { [self] _, _ in
                    if staleControls > 0 { staleControls -= 1; throw DesktopAXError.stale }
                    if slowControl { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    presses += 1
                    if let afterPress { text = afterPress }
                    return "The app accepted the press; outcome not verified."
                }, plan: { [self] _, token in if !token.isCancelled { plans += 1 } },
                openURL: { [self] url in addresses.append(url); text += "\nAXHeading: Canvas home" },
                insertText: { [self] text, send, token in
                    guard !token.isCancelled else { throw CancellationError() }
                    insertions.append((text, send)); self.text += "\nInserted: " + text
                }, collect: collect)
            return DesktopVoiceCoordinator(history: DesktopVoiceHistoryStore(directory: directory), dependencies: dependencies)
        }

        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ passed: Bool) { print("\(passed ? "PASS" : "FAIL"): \(name)"); if !passed { failures += 1 } }
        func finish(_ completed: Bool, _ summary: String, _ evidence: String = "") throws -> DesktopVoiceAssistantDecision {
            .finishTask(try DesktopVoiceTaskConclusion(arguments: ["outcome": completed ? "completed" : "blocked", "summary": summary, "evidence": evidence]))
        }
        func wait(_ coordinator: DesktopVoiceCoordinator) async {
            let deadline = Date().addingTimeInterval(5)
            while coordinator.isCommandRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            check("conversation finishes within the replay deadline", !coordinator.isCommandRunning)
        }
        pure(check: check)

        do {
            let fixture = Fixture(); defer { fixture.clean() }
            var calls = 0
            fixture.respond = { _, _, _, result in
                calls += 1
                if calls == 1 { return .invalidTool("Malformed fixture arguments") }
                check("invalid arguments return explicit no-action repair feedback", result?.contains("no action happened") == true)
                return .answer("The corrected request is read-only.")
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Explain the fixture")
            await wait(coordinator)
            check("invalid tool correction never dispatches a desktop action", calls == 2 && fixture.plans == 0 && fixture.presses == 0)
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.staleControls = 1
            fixture.respond = { _, _, screen, result in
                guard let screen else { return .beginUIControl }
                if result?.contains("control changed") == true { return .answer("The control changed; I have a fresh view.") }
                return .controlUI(.init(snapshotID: screen.accessibility.snapshotID, elementID: "e1", action: "AXPress"))
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Inspect the fixture control and act")
            await wait(coordinator)
            check("a stale target refreshes and replans without blindly replaying", fixture.staleControls == 0 && fixture.presses == 0 && coordinator.activities.last?.title.contains("fresh view") == true)
        }

        do {
            let fixture = Fixture(); defer { fixture.clean() }
            let app = DesktopVoiceApplicationTarget(displayName: "Fixture App", bundleIdentifier: nil,
                applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"))
            fixture.resolveApplication = { $0 == "fixture app" ? app : nil }
            fixture.respond = { _, _, _, _ in .plan(DesktopVoicePlan(summary: "Simulated single step", actions: [.openApplication(app)])) }
            let coordinator = fixture.coordinator()
            coordinator.submit("Open Fixture App"); await wait(coordinator)
            check("local fast paths execute only the simulated desktop effect", fixture.plans == 1)
            coordinator.submit("Carry out a single simulated step"); await wait(coordinator)
            check("single-step model plans execute only the simulated desktop effect", fixture.plans == 2)
        }

        do {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.respond = { _, _, screen, result in
                guard let screen else { return .beginUIControl }
                if result?.contains("Blocked repeated") == true { return try finish(false, "The course list did not appear.") }
                return .controlUI(.init(snapshotID: screen.accessibility.snapshotID, elementID: "e1", action: "AXPress"))
            }
            let coordinator = fixture.coordinator()
            coordinator.submit("Go to courses within this website")
            await wait(coordinator)
            check("a stuck Courses button is physically pressed only once", fixture.presses == 1)
            check("a rejected repeat is recorded as a failure", coordinator.history.entries.contains { $0.kind == .failure && $0.text == "Stopped a repeated action" })
            fixture.respond = { _, context, _, _ in
                check("go ahead remains an authorized interaction with the original goal", context.allowsUIActions && context.ongoingTask == "Go to courses within this website")
                return try finish(false, "The page still needs inspection.")
            }
            coordinator.submit("Yeah, go ahead."); await wait(coordinator)
            check("continuing the task does not refocus the address bar", fixture.plans == 0)
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.slowControl = true
            fixture.respond = { _, _, screen, _ in
                guard let screen else { return .beginUIControl }
                return .controlUI(.init(snapshotID: screen.accessibility.snapshotID, elementID: "e1", action: "AXPress"))
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Open Courses")
            try? await Task.sleep(nanoseconds: 40_000_000)
            coordinator.submit("No, no, no!")
            fixture.respond = { _, _, _, _ in .answer("I heard the correction.") }
            coordinator.submit("Explain what went wrong")
            await wait(coordinator)
            try? await Task.sleep(nanoseconds: 60_000_000)
            check("a spoken correction cancels pending effects instead of queuing", fixture.presses == 0)
            check("cancelled work cannot overwrite the new reply", coordinator.activities.last?.title == "I heard the correction.")
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            var triedCompletion = 0
            fixture.respond = { _, _, screen, _ in
                guard let screen else { return .beginUIControl }
                if fixture.presses == 0 { return .controlUI(.init(snapshotID: screen.accessibility.snapshotID, elementID: "e1", action: "AXPress")) }
                triedCompletion += 1
                if triedCompletion == 1 { return try finish(true, "Courses is open", "Courses") }
                return try finish(false, "I could not verify that the course list opened.")
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Go through my courses")
            await wait(coordinator)
            check("a dispatch plus the same label cannot produce a success claim", !coordinator.history.entries.contains { $0.kind == .assistant && $0.text == "Courses is open" })
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.respond = { _, _, screen, _ in
                if screen == nil { return .openURL(try DesktopVoiceNavigation.url("https://canvas.nus.edu.sg")) }
                return try finish(true, "Canvas home is visible.", "Canvas home")
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Go to Canvas NUS")
            await wait(coordinator)
            check("website navigation uses one complete URL with no letter shortcuts", fixture.addresses.count == 1 && fixture.plans == 0)
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.respond = { _, context, screen, _ in
                if let id = context.preparedTextID, screen == nil { return .commitText(id, false) }
                if !fixture.insertions.isEmpty { return try finish(true, "Text inserted.", "Hello, 世界 👋") }
                guard let screen else { return .beginUIControl }
                return .prepareText(try DesktopVoiceTextDraft(arguments: ["snapshot_id": screen.accessibility.snapshotID, "element_id": "e2", "text": "Hello, 世界 👋"]))
            }
            let coordinator = fixture.coordinator(); coordinator.submit("Type Hello, 世界 👋 in the search field")
            await wait(coordinator)
            check("preparing complete Unicode text creates a review draft without typing", coordinator.preparedText?.text == "Hello, 世界 👋" && fixture.insertions.isEmpty)
            coordinator.submit("Insert the displayed text"); await wait(coordinator)
            check("explicit insert sends the whole draft without an unintended Enter", fixture.insertions.count == 1 && fixture.insertions.first?.0 == "Hello, 世界 👋" && fixture.insertions.first?.1 == false)
            check("an inserted draft cannot be committed twice", coordinator.preparedText == nil)
        }
        print(failures == 0 ? "All voice flow replays passed." : "\(failures) replay checks failed.")
        return failures == 0 ? 0 : 1
    }

    /// Optional live model check; its tools still operate only on synthetic state.
    @MainActor
    static func runModel() async -> Int32 {
        var failures = 0
        for changes in [true, false] {
            let fixture = Fixture(); defer { fixture.clean() }
            fixture.text += "\nAXHeading: Canvas dashboard | document URL: https://canvas.example.test/"
            if changes { fixture.afterPress = fixture.text + "\nAXHeading: All courses\nAXLink: Introductory Computing\nAXLink: Linear Algebra" }
            let assistant = DesktopVoiceAssistant(resolveApplication: { _ in nil })
            var calls = 0
            fixture.respond = { command, context, screen, result in
                calls += 1
                guard calls <= 12 else { throw DesktopAXError.invalid("Model replay exceeded twelve decisions.") }
                let decision = try await assistant.respond(to: command, context: context, screen: screen, toolResult: result)
                print("Model decision \(calls): \(decision)")
                return decision
            }
            let coordinator = fixture.coordinator()
            coordinator.submit("Go to Courses within this website and tell me the course names.")
            let deadline = Date().addingTimeInterval(100)
            while coordinator.isCommandRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            if coordinator.isCommandRunning { coordinator.stop(); failures += 1; print("FAIL: model replay timed out") }
            let answers = coordinator.history.entries.filter { $0.kind == .assistant }
            let passed: Bool
            if changes {
                passed = fixture.presses == 1 && fixture.plans == 0 && fixture.addresses.isEmpty
                    && answers.contains { $0.text.contains("Introductory Computing") && $0.text.contains("Linear Algebra") }
            } else {
                passed = fixture.presses == 1 && fixture.plans == 0 && fixture.addresses.isEmpty
                    && answers.contains { $0.detail?.hasPrefix("Task unfinished:") == true }
            }
            print("\(passed ? "PASS" : "FAIL"): live model \(changes ? "reads the opened course list" : "stops when the course list does not open")")
            if !passed { failures += 1; print(coordinator.history.transcript()) }
        }
        do {
            let fixture = Fixture(); defer { fixture.clean() }
            let assistant = DesktopVoiceAssistant(resolveApplication: { _ in nil })
            fixture.respond = { command, context, screen, result in
                let decision = try await assistant.respond(to: command, context: context, screen: screen, toolResult: result)
                print("Text model decision: \(decision)")
                return decision
            }
            let coordinator = fixture.coordinator()
            coordinator.submit("Type Hello there in the Search field.")
            var deadline = Date().addingTimeInterval(40)
            while coordinator.isCommandRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            let staged = coordinator.preparedText?.text == "Hello there" && fixture.insertions.isEmpty
            if coordinator.isCommandRunning { coordinator.stop() }
            coordinator.submit("Yeah, go ahead.")
            deadline = Date().addingTimeInterval(40)
            while coordinator.isCommandRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
            let passed = staged && !coordinator.isCommandRunning && fixture.insertions.count == 1
                && fixture.insertions.first?.0 == "Hello there" && fixture.insertions.first?.1 == false
            if coordinator.isCommandRunning { coordinator.stop() }
            print("\(passed ? "PASS" : "FAIL"): live model prepares text and understands natural approval without sending Enter")
            if !passed { failures += 1; print(coordinator.history.transcript()) }
        }
        return failures == 0 ? 0 : 1
    }
}
