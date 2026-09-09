/// Synthetic reading/diagnostic regression checks. No personal apps are inspected
/// or clicked, including in the optional live-model summary check.
import AppKit
import ApplicationServices

enum DesktopReadingSelfTest {
    static func pure(check: (String, Bool) -> Void) {
        let incomplete: [String: Any] = ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
            "output": [["type": "function_call", "name": "collect_reading", "arguments": "{\"kind\":"]]]
        check("token-truncated responses get one larger bounded retry", DesktopModelResponse.retryBudget(incomplete, budget: 1_600, attempt: 0) == 3_200)
        check("a second incomplete response does not retry forever", DesktopModelResponse.retryBudget(incomplete, budget: 3_200, attempt: 1) == nil)
        check("incomplete tools cannot reach the interpreter", (try? DesktopVoiceAssistant.interpret(incomplete, resolveApplication: { _ in nil })) == nil)
        check("content filters are not retried as token exhaustion", DesktopModelResponse.retryBudget(["status": "incomplete", "incomplete_details": ["reason": "content_filter"]], budget: 1_600, attempt: 0) == nil)
        check("unfinished output items are refused", (try? DesktopModelResponse.requireComplete(["status": "completed", "output": [["status": "in_progress"]]])) == nil)
        let request: [String: Any] = ["kind": "browser_tabs", "application": "Brave", "limit": 5, "include_content": false]
        check("reading tool accepts a bounded typed request", (try? DesktopCollectionRequest(arguments: request))?.limit == 5)
        var invalid = request; invalid["limit"] = true
        check("a boolean cannot masquerade as an item count", (try? DesktopCollectionRequest(arguments: invalid)) == nil)
        invalid = request; invalid["include_content"] = 1
        check("a numeric flag cannot authorize opening content", (try? DesktopCollectionRequest(arguments: invalid)) == nil)
        invalid = request; invalid["limit"] = 500
        check("reading batches cannot exceed the item budget", (try? DesktopCollectionRequest(arguments: invalid)) == nil)
        check("spoken five is understood without a planning round trip", DesktopCollectionRequest.infer("List the first five tabs", targetName: "Google Chrome")?.limit == 5)
        check("unqualified tabs use the active browser", DesktopCollectionRequest.infer("Summarize my tabs", targetName: "Google Chrome")?.application == "Google Chrome")
        check("explicit app beats the active browser", DesktopCollectionRequest.infer("Summarize my Brave tabs", targetName: "Safari")?.application == "brave")
        for text in ["Don't read my unread Telegram messages", "How do I list tabs?", "Teach me to summarize tabs", "List tabs and close them"] {
            check("ambiguous or non-reading request stays out of the local accelerator: \(text)", DesktopCollectionRequest.infer(text, targetName: nil) == nil)
        }
        check("an unspecified message app is not guessed", DesktopCollectionRequest.infer("Summarize unread messages", targetName: "Finder") == nil)
        let chats = context([
            element(1, role: "AXList", label: "Chats"),
            element(2, parent: "e1", role: "AXRow", label: "Project group, 8 unread messages"),
            element(3, parent: "e1", role: "AXRow", label: "Alice, direct message, 2 unread messages"),
            element(4, parent: "e1", role: "AXRow", label: "Bob, 1 unread message"),
            element(5, parent: "e1", role: "AXButton", label: "Unread"),
            element(6, parent: "e3", role: "AXCell", label: "2 unread messages")])
        let candidates = DesktopCollectionReader.candidates(chats, kind: .unreadMessages)
        check("explicit DMs precede group chats", candidates.first?.item.category == "direct_message")
        check("a person's name does not prove a DM", candidates.last?.item.category == "unknown_chat_type")
        check("unread filters and nested badges do not inflate chat counts", candidates.count == 3)
        let tabs = tabContext(selected: 2, page: "Page one text")
        check("only tab semantics identify tabs, not close buttons", DesktopCollectionReader.candidates(tabs, kind: .browserTabs).count == 2)
        check("page content excludes browser chrome", DesktopCollectionReader.content(tabs, kind: .browserTabs) == "Example page\nPage one text")
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("btrvoice-trace-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let trace = DesktopVoiceTrace(directory: directory, sessionID: UUID(), maximumBytes: 1_400)
            let turn = UUID()
            trace.record("model.request", turnID: turn, fields: ["authorization": "secret-header", "image_url": "secret-image",
                "arguments": #"{"password":"secret-pass","safe":"hello"}"#,
                "url": "https://example.test/?api_key=secret-key", "note": "Bearer secret-bearer"])
            trace.flush()
            let data = try Data(contentsOf: trace.fileURL)
            let text = String(decoding: data, as: UTF8.self)
            check("diagnostics omit headers, credentials, JSON-string secrets and images", !text.contains("secret-") && text.contains("hello"))
            check("diagnostics correlate the model request to its turn", text.contains(turn.uuidString) && text.contains("model.request"))
            let permissions = try FileManager.default.attributesOfItem(atPath: trace.fileURL.path)[.posixPermissions] as? NSNumber
            check("diagnostics are owner-only", permissions?.intValue == 0o600)
            for index in 0..<10 { trace.record("test", turnID: turn, fields: ["index": index, "padding": String(repeating: "x", count: 600)]) }
            trace.flush()
            let files = try FileManager.default.contentsOfDirectory(atPath: trace.directory.path)
            check("diagnostic retention is bounded to three files", files.sorted() == ["events.1.jsonl", "events.2.jsonl", "events.jsonl"])
            check("turn-filtered diagnostics survive rotation", DesktopVoiceTrace.recent(directory: directory, turnID: turn.uuidString).contains("\"index\":9"))
            check("unrelated turn IDs do not return another conversation", DesktopVoiceTrace.recent(directory: directory, turnID: UUID().uuidString).isEmpty)
        } catch { check("diagnostic fixtures write and read successfully: \(error)", false) }
    }

    @MainActor static func run(model: Bool = false) async -> Int32 {
        var failures = 0
        func check(_ name: String, _ passed: Bool) { print("\(passed ? "PASS" : "FAIL"): \(name)"); if !passed { failures += 1 } }
        pure(check: check)
        for mode in ["success", "stale-content", "focus", "uncertain", "preview"] {
            var selected = 2
            var selections = 0
            var reads = 0
            var active = true
            let backend = DesktopCollectionReader.Backend(read: { _, _ in
                reads += 1
                return tabContext(selected: selected, page: mode == "stale-content" || selected == 2 ? "Page one text" : "Page two text")
            }, select: { entry, _ in
                selections += 1
                if mode == "uncertain" { throw DesktopAXError.invalid("Selection timed out; its outcome is uncertain.") }
                selected = Int(entry.id.dropFirst())!
                if mode == "focus" { active = false }
            }, isTargetActive: { active })
            do {
                let result = try await DesktopCollectionReader.collect(.init(kind: .browserTabs, limit: 2, includeContent: mode != "preview"), application: "Fixture", backend: backend)
                switch mode {
                case "success": check("local batch attaches each selected tab's content", result.items.map(\.contentVerified) == [true, true] && result.items[1].content.contains("Page two"))
                case "stale-content": check("selection alone cannot mislabel the previous page as the next", result.items[0].contentVerified && !result.items[1].contentVerified && result.partial)
                case "focus": check("focus changes stop navigation while retaining remaining previews", selections == 1 && result.items.count == 2 && result.items.allSatisfy { !$0.contentVerified } && result.partial)
                case "uncertain": check("an uncertain selection is never blindly repeated", selections == 1 && result.partial && result.items.count == 2)
                default: check("preview listing takes one read and no selection", reads == 1 && selections == 0 && result.items.count == 2)
                }
            } catch { check("reading fixture \(mode): \(error)", false) }
        }
        do {
            let fixture = DesktopVoiceFlowSelfTest.Fixture(); defer { fixture.clean() }
            var calls = 0; var collections = 0
            fixture.collect = { request in
                collections += 1
                return DesktopReadingCollection(kind: request.kind, application: "Fixture", items: [.init(title: "Example", category: "tab", preview: "Example")], discovered: 1, partial: false, limitations: [])
            }
            fixture.respond = { _, _, _, result in
                calls += 1
                check("summary receives the collected evidence", result?.contains("Example") == true)
                return .answer("Research: Example (title only).")
            }
            let coordinator = fixture.coordinator()
            coordinator.submit("Summarize my browser tabs")
            let deadline = Date().addingTimeInterval(5)
            while coordinator.isCommandRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            check("a simple reading request uses one batch and one model call", !coordinator.isCommandRunning && collections == 1 && calls == 1 && fixture.plans == 0 && fixture.presses == 0)
            coordinator.history.trace.flush()
            let trace = DesktopVoiceTrace.recent(directory: fixture.directory)
            check("completed turns include an end-to-end timing event", trace.contains("turn.finished") && trace.contains("duration_ms"))
            coordinator.submit("List the first five tabs")
            let listingDeadline = Date().addingTimeInterval(5)
            while coordinator.isCommandRunning, Date() < listingDeadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            check("a plain listing needs no extra model call", !coordinator.isCommandRunning && collections == 2 && calls == 1 && coordinator.activities.last?.title.contains("Example") == true)
        }
        if model {
            let collection = DesktopReadingCollection(kind: .unreadMessages, application: "Synthetic chat fixture",
                items: [.init(title: "Alice", category: "direct_message", preview: "2 unread messages", unreadEvidence: "2 unread messages", content: "Alice: Can you review the launch notes by Friday?", contentVerified: true),
                        .init(title: "Project room", category: "group_or_channel", preview: "Release moved to Monday; 4 unread messages", unreadEvidence: "4 unread messages")],
                discovered: 2, partial: true, limitations: ["Only two exposed chats; Project room has a list preview only."])
            let started = Date()
            do {
                let assistant = DesktopVoiceAssistant(resolveApplication: { _ in nil })
                let reply = try await assistant.respond(to: "Summarize my unread messages, especially DMs.", context: .init(targetName: "Fixture", recentActivity: []), collection: collection)
                if case .answer(let text) = reply {
                    print("Synthetic summary (\(Int(Date().timeIntervalSince(started) * 1_000)) ms): \(text)")
                    check("lightweight model summarizes evidence without desktop tools", text.contains("Alice") && text.contains("Friday") && text.lowercased().contains("preview"))
                } else { check("summary mode returns text only", false) }
            } catch { check("synthetic live-model summary: \(error.localizedDescription)", false) }
            do {
                let tabs = DesktopReadingCollection(kind: .browserTabs, application: "Synthetic browser",
                    items: [.init(title: "Swift documentation", category: "tab", preview: "Swift documentation"),
                            .init(title: "SwiftUI tutorials", category: "tab", preview: "SwiftUI tutorials"),
                            .init(title: "Grocery list", category: "tab", preview: "Grocery list")],
                    discovered: 3, partial: false, limitations: ["Tab titles only; page contents were not inspected."])
                let assistant = DesktopVoiceAssistant(resolveApplication: { _ in nil })
                let reply = try await assistant.respond(to: "Group these browser tabs into categories and summarize what they are for.", context: .init(targetName: "Fixture", recentActivity: []), collection: tabs)
                if case .answer(let text) = reply {
                    print("Synthetic tab summary: \(text)")
                    check("tab categories preserve titles and title-only coverage", text.contains("Swift") && text.contains("Grocery") && text.lowercased().contains("title"))
                } else { check("tab categorization is a tool-free answer", false) }
            } catch { check("synthetic tab model check: \(error.localizedDescription)", false) }
        }
        return failures == 0 ? 0 : 1
    }

    private static func element(_ id: Int, parent: String? = nil, role: String, label: String, selected: Bool? = nil) -> DesktopAccessibilityElement {
        .init(id: "e\(id)", reference: AXUIElementCreateApplication(pid_t(50_000 + id)), parentID: parent,
              role: role, label: label, actions: ["AXPress"], writable: [:], enabled: true, selected: selected)
    }
    private static func context(_ elements: [DesktopAccessibilityElement]) -> DesktopAccessibilityContext {
        var result = DesktopAccessibilityContext(text: elements.map(\.label).joined(separator: "\n"), elementCount: elements.count, truncated: false)
        result.processIdentifier = 42
        result.elements = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        return result
    }
    private static func tabContext(selected: Int, page: String) -> DesktopAccessibilityContext {
        context([element(1, role: "AXTabGroup", label: "Tabs"),
                 element(2, parent: "e1", role: "AXRadioButton", label: "One", selected: selected == 2),
                 element(3, parent: "e1", role: "AXRadioButton", label: "Two", selected: selected == 3),
                 element(4, parent: "e2", role: "AXButton", label: "Close"),
                 element(5, role: "AXWebArea", label: "Example page"),
                 element(6, parent: "e5", role: "AXStaticText", label: page)])
    }
}
