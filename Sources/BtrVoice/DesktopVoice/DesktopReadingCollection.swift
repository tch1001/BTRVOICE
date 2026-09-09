/// Bounded semantic read operations, not arbitrary action macros. The model gets
/// source-backed items in one batch and can spend its time summarizing, not clicking.
import Foundation
import CoreFoundation

struct DesktopCollectionRequest: Equatable, Codable {
    enum Kind: String, Codable { case browserTabs = "browser_tabs", unreadMessages = "unread_messages" }
    let kind: Kind
    var application: String?
    var limit = 8
    var includeContent = true

    init(kind: Kind, application: String? = nil, limit: Int = 8, includeContent: Bool = true) {
        self.kind = kind; self.application = application; self.limit = limit; self.includeContent = includeContent
    }

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys) == ["kind", "application", "limit", "include_content"],
              let raw = arguments["kind"] as? String, let kind = Kind(rawValue: raw),
              let number = arguments["limit"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let limit = arguments["limit"] as? Int, (1...30).contains(limit),
              let boolean = arguments["include_content"] as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(),
              let content = arguments["include_content"] as? Bool,
              arguments["application"] is String || arguments["application"] is NSNull else {
            throw DesktopVoiceAssistant.AssistantError.invalidPlan("Choose browser_tabs or unread_messages, an app or null, a limit of 1–30, and include_content.")
        }
        self.init(kind: kind, application: arguments["application"] as? String, limit: limit, includeContent: content)
    }

    /// Optional local accelerator. Ambiguous, negated and hypothetical requests
    /// stay with the model; this is not the only way to request a collection.
    static func infer(_ text: String, targetName: String?) -> Self? {
        let words = DesktopVoiceUtterance.words(text)
        let phrase = words.joined(separator: " ")
        guard !["don t", "do not", "never", "how to", "how do", "if ", "teach", "learn", "remember", "send", "delete", "close", "archive"].contains(where: phrase.contains),
              !["not", "how", "why", "mean", "example"].contains(where: words.contains),
              ["summarize", "summarise", "list", "check", "read", "categorize", "categorise", "group", "count", "tell"].contains(where: words.contains) else { return nil }
        let browserNames = ["brave", "chrome", "safari", "edge", "firefox"]
        let messageNames = ["telegram", "slack", "whatsapp", "messages", "discord", "signal"]
        let kind: Kind
        let app: String?
        if words.contains("tabs") {
            kind = .browserTabs
            app = browserNames.first(where: words.contains)
                ?? targetName.flatMap { name in browserNames.contains(where: name.lowercased().contains) ? name : nil }
                ?? "browser"
        } else if words.contains("unread") && ["messages", "chats", "dms", "dm"].contains(where: words.contains) {
            kind = .unreadMessages
            app = messageNames.filter { $0 != "messages" }.first(where: words.contains)
                ?? targetName.flatMap { name in messageNames.contains(where: name.lowercased().contains) ? name : nil }
            guard app != nil else { return nil }
        } else { return nil }
        let wantsSummary = ["summarize", "summarise", "read", "group", "categorize", "categorise"].contains(where: words.contains)
        let spokenNumbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        let limit = words.compactMap { Int($0) ?? spokenNumbers[$0] }.first.map { min(30, max(1, $0)) } ?? 30
        return Self(kind: kind, application: app, limit: limit, includeContent: wantsSummary)
    }
}

struct DesktopReadingItem: Codable, Equatable {
    var title: String
    var category: String
    var preview: String
    var unreadEvidence: String?
    var content: String = ""
    var contentVerified = false
}

struct DesktopReadingCollection: Codable, Equatable {
    var kind: DesktopCollectionRequest.Kind
    var application: String
    var items: [DesktopReadingItem]
    var discovered: Int
    var partial: Bool
    var limitations: [String]
    var durationMS: Double = 0

    /// A plain list needs no LLM. Keep evidence and coverage visible even on this
    /// zero-model path; semantic grouping and summaries still use the model.
    var listing: String {
        let rows = items.enumerated().map { index, item in
            "\(index + 1). \(item.title)" + (item.preview == item.title ? "" : " — " + String(item.preview.prefix(300)))
        }
        let heading = "\(application): \(items.count) exposed \(kind == .browserTabs ? "tabs" : "unread chat rows") listed."
        return ([heading] + rows + limitations).joined(separator: "\n")
    }

    var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "{}"
    }
}
