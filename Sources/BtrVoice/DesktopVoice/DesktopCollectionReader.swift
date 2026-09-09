/// Executes only bounded, evidence-checked navigation for reading. It never sends,
/// deletes, archives, types text, or follows instructions found in a chat/page.
import AppKit
import ApplicationServices

enum DesktopCollectionReader {
    struct Candidate {
        let element: DesktopAccessibilityElement
        let item: DesktopReadingItem
    }
    struct Backend {
        var read: (DesktopAccessibilityReader.Purpose, AXUIElement?) async throws -> DesktopAccessibilityContext
        var select: (DesktopAccessibilityElement, DesktopAccessibilityContext) async throws -> Void
        var isTargetActive: () -> Bool
    }

    static func candidates(_ context: DesktopAccessibilityContext, kind: DesktopCollectionRequest.Kind) -> [Candidate] {
        let ordered = context.elements.values.sorted { number($0.id) < number($1.id) }
        var result: [Candidate] = []
        for element in ordered {
            if kind == .unreadMessages, element.enabled != false,
               let item = DesktopTelegramSemantics.unreadItem(element, in: context) {
                result.append(Candidate(element: element, item: item))
                continue
            }
            guard ["AXTab", "AXRadioButton", "AXRow", "AXCell", "AXButton"].contains(element.role),
                  element.enabled != false else { continue }
            let parents = ancestors(of: element, in: context)
            let text = subtreeText(element, in: context, limit: 1_600)
            let title = element.label.isEmpty ? text.components(separatedBy: "\n").first ?? "" : element.label
            guard !title.isEmpty, element.enabled != false else { continue }
            switch kind {
            case .browserTabs:
                guard element.role == "AXTab" || (element.role == "AXRadioButton" && parents.contains { $0.role == "AXTabGroup" }) else { continue }
                result.append(Candidate(element: element, item: .init(title: title, category: "tab", preview: text)))
            case .unreadMessages:
                // Buttons inside lists can also be destructive row actions. Never
                // promote an action button into a conversation-selection target.
                if element.role == "AXButton", element.label.range(of: #"(?i)\b(delete|archive|send|close|mark|mute|block|remove)\b"#, options: .regularExpression) != nil { continue }
                let isRow = ["AXRow", "AXCell"].contains(element.role)
                    || (element.role == "AXButton" && parents.contains { ["AXList", "AXOutline", "AXTable"].contains($0.role) })
                guard isRow, text.range(of: #"(?i)\b(?:[1-9][0-9]*\s+unread|unread\s+(?:messages?|chats?|[1-9][0-9]*))\b"#, options: .regularExpression) != nil,
                      !parents.contains(where: { parent in result.contains { $0.element.id == parent.id } }) else { continue }
                let category: String
                if text.range(of: #"(?i)\b(direct message|private chat|DM)\b"#, options: .regularExpression) != nil { category = "direct_message" }
                else if text.range(of: #"(?i)\b(group|channel|subscribers|members)\b"#, options: .regularExpression) != nil { category = "group_or_channel" }
                else { category = "unknown_chat_type" }
                result.append(Candidate(element: element, item: .init(title: title, category: category, preview: text, unreadEvidence: text)))
            }
        }
        if kind == .unreadMessages {
            // Only explicit DM evidence earns priority; a person's name alone is
            // not enough to relabel a group or bot conversation as a direct message.
            result.sort { ($0.item.category == "direct_message" ? 0 : 1, number($0.element.id))
                < ($1.item.category == "direct_message" ? 0 : 1, number($1.element.id)) }
        }
        return result
    }

    static func content(_ context: DesktopAccessibilityContext, kind: DesktopCollectionRequest.Kind) -> String? {
        let roots = context.elements.values.filter { entry in
            if kind == .browserTabs { return entry.role == "AXWebArea" }
            return ["AXList", "AXGroup", "AXScrollArea", "AXOutline", "AXTable"].contains(entry.role)
                && entry.label.range(of: #"(?i)\b(messages|conversation|message history|chat history)\b"#, options: .regularExpression) != nil
        }.sorted { number($0.id) < number($1.id) }
        guard let root = roots.first else { return nil }
        let text = subtreeText(root, in: context, limit: 5_000)
        return text.count > root.label.count + 8 ? text : nil
    }

    static func collect(_ request: DesktopCollectionRequest, application: String,
                        backend: Backend, trace: DesktopVoiceTrace? = nil, turnID: UUID? = nil) async throws -> DesktopReadingCollection {
        let started = Date()
        let purpose: DesktopAccessibilityReader.Purpose = request.kind == .browserTabs ? .tabs : .content
        var inventory = try await backend.read(purpose, nil)
        var found = candidates(inventory, kind: request.kind)
        // Some apps expose their window before populating its lazy AX children.
        // One local, read-only retry avoids reporting an empty first frame as the
        // available inventory. A healthy populated tree incurs no added delay.
        if found.isEmpty {
            trace?.record("collection.inventory_retry", turnID: turnID, fields: ["initial_elements": inventory.elementCount])
            try await Task.sleep(nanoseconds: 100_000_000)
            inventory = try await backend.read(purpose, nil)
            found = candidates(inventory, kind: request.kind)
        }
        var result = DesktopReadingCollection(kind: request.kind, application: application, items: [],
            discovered: found.count, partial: inventory.truncated || found.count > request.limit || found.isEmpty || request.kind == .unreadMessages, limitations: [])
        result.items = found.prefix(request.limit).map(\.item)
        result.limitations.append("Scope: the app's exposed tab strip/chat list, not an account-wide unread count. Hidden, virtualized or unsupported items may be missing.")
        if request.includeContent { result.limitations.append("Content is a bounded visible excerpt, not a complete page or message archive.") }
        if found.count > request.limit { result.limitations.append("Included the first \(request.limit) of \(found.count) discovered items.") }
        if inventory.truncated { result.limitations.append("Accessibility returned a partial inventory; discovered counts are not totals.") }
        if found.isEmpty { result.limitations.append("No clearly identified \(request.kind.rawValue) were exposed. This does not prove there are none.") }
        if request.kind == .unreadMessages { result.limitations.append("Chat type is unknown unless the app explicitly identifies a DM/group. Opening chats may mark messages read.") }
        let deadline = Date().addingTimeInterval(20)
        for (index, candidate) in found.prefix(request.limit).enumerated() {
            try Task.checkCancellation()
            var item = candidate.item
            if request.includeContent {
                guard index < 8 else {
                    result.partial = true
                    result.limitations.append("Opened at most eight items in this batch; remaining titles/list previews are included without content verification.")
                    break
                }
                guard Date() < deadline else { result.partial = true; result.limitations.append("Stopped at the 20-second collection budget; remaining items were not opened."); break }
                guard backend.isTargetActive() else {
                    result.partial = true
                    result.limitations.append("Paused because another app took focus. No further tabs/chats were selected.")
                    break
                }
                do {
                    // Retain references only as candidates; refresh capabilities
                    // and identity immediately before each selection.
                    let before = try await backend.read(.content, nil)
                    let previousContent = content(before, kind: request.kind)
                    let previouslySelected = before.elements.values.contains { CFEqual($0.reference, candidate.element.reference) && $0.selected == true }
                    let fresh = try await backend.read(.controls, candidate.element.reference)
                    guard let target = fresh.elements.values.first(where: {
                        CFEqual($0.reference, candidate.element.reference) && $0.role == candidate.element.role && $0.label == candidate.element.label
                    }) else { throw DesktopAXError.stale }
                    guard backend.isTargetActive() else { throw DesktopVoiceTaskError.targetChanged(application) }
                    try await backend.select(target, fresh)
                    trace?.record("collection.selected", turnID: turnID, fields: ["application": application, "title": item.title, "kind": request.kind.rawValue])
                    // Poll locally, not through the model. Each pass reads after
                    // selection; never attach the previous tab/chat to this item.
                    var lastContent: String?
                    for attempt in 0..<6 {
                        try Task.checkCancellation()
                        guard backend.isTargetActive(), Date() < deadline else { break }
                        let selected = try await backend.read(.content, nil)
                        // The injected backend uses the same snapshot identity in
                        // tests; live selection is checked by its advertised state.
                        let same = selected.elements.values.first { CFEqual($0.reference, candidate.element.reference) }
                        let selectedState = same?.selected == true
                        if selectedState, let text = content(selected, kind: request.kind),
                           previouslySelected || text != previousContent {
                            // Selection can update before the content pane. Require
                            // a changed (or already-selected) source and two stable
                            // post-selection reads, not a badge alone.
                            if lastContent == text {
                                item.content = text; item.contentVerified = true
                                if selected.truncated { result.partial = true }
                                break
                            }
                            lastContent = text
                        } else {
                            lastContent = nil
                        }
                        if attempt == 5 { break }
                        try await Task.sleep(nanoseconds: 80_000_000)
                    }
                    if !item.contentVerified {
                        result.partial = true
                        result.limitations.append("Could not verify a readable content pane for \(item.title); use its list preview only.")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    result.partial = true
                    result.limitations.append("Stopped before further navigation: " + error.localizedDescription)
                    trace?.record("collection.selection_failed", turnID: turnID, fields: ["title": item.title, "error": error.localizedDescription])
                    result.items[index] = item
                    break // An uncertain click is not safe to repeat blindly.
                }
            }
            result.items[index] = item
        }
        result.durationMS = Date().timeIntervalSince(started) * 1_000
        trace?.record("collection.result", turnID: turnID, fields: ["duration_ms": result.durationMS, "collection": result.json])
        return result
    }

    @MainActor static func liveBackend(application: NSRunningApplication, token: DesktopVoiceCancellation,
                                       trace: DesktopVoiceTrace?, turnID: UUID?) -> Backend {
        let pid = application.processIdentifier
        return Backend(read: { purpose, root in
            let started = Date()
            let worker = Task.detached(priority: .userInitiated) {
                DesktopAccessibilityReader.read(processIdentifier: pid, root: root, purpose: purpose)
            }
            let read = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard !token.isCancelled else { throw CancellationError() }
            trace?.record("ax.read", turnID: turnID, fields: ["pid": pid, "snapshot_id": read.snapshotID,
                "duration_ms": Date().timeIntervalSince(started) * 1_000, "elements": read.elementCount, "partial": read.truncated, "text": read.text])
            return read
        }, select: { element, context in
            let command: DesktopUICommand
            if element.selected == true { return }
            if element.actions.contains("AXPress") { command = .init(snapshotID: context.snapshotID, elementID: element.id, action: "AXPress") }
            else if element.writable["AXSelected"] == .boolean { command = .init(snapshotID: context.snapshotID, elementID: element.id, attribute: "AXSelected", valueJSON: "true") }
            else { throw DesktopAXError.invalid("This app doesn't expose a safe tab/chat selection action.") }
            let worker = Task.detached(priority: .userInitiated) {
                guard !token.isCancelled else { throw CancellationError() }
                return try DesktopAccessibilityControl.execute(command, in: context)
            }
            _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }, isTargetActive: { !token.isCancelled && !application.isTerminated
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid })
    }

    private static func ancestors(of element: DesktopAccessibilityElement, in context: DesktopAccessibilityContext) -> [DesktopAccessibilityElement] {
        var result: [DesktopAccessibilityElement] = []
        var id = element.parentID
        var seen = Set<String>()
        while let current = id, seen.insert(current).inserted, let parent = context.elements[current] {
            result.append(parent); id = parent.parentID
        }
        return result
    }

    private static func subtreeText(_ root: DesktopAccessibilityElement, in context: DesktopAccessibilityContext, limit: Int) -> String {
        var seen = Set<String>()
        let text = context.elements.values.filter { $0.id == root.id || ancestors(of: $0, in: context).contains { $0.id == root.id } }
            .sorted { number($0.id) < number($1.id) }.flatMap { [$0.label, $0.value ?? ""] }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        return String(text.prefix(limit))
    }
    private static func number(_ id: String) -> Int { Int(id.dropFirst()) ?? 0 }
}
