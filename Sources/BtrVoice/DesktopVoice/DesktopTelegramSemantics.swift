/// Adapts Telegram Desktop's Qt accessibility list items. Static text in a chat
/// list is a row; an unread folder badge or an outgoing read receipt is not one.
import Foundation

enum DesktopTelegramSemantics {
    static func isListItem(bundleIdentifier: String?, role: String, parentRole: String?, parentLabel: String?) -> Bool {
        bundleIdentifier == "com.tdesktop.Telegram" && role == "AXStaticText"
            && parentRole == "AXList" && ["Chats", "Folders"].contains(parentLabel)
    }

    static func isItem(_ element: DesktopAccessibilityElement, in context: DesktopAccessibilityContext, list: String) -> Bool {
        guard let parent = element.parentID.flatMap({ context.elements[$0] }) else { return false }
        return parent.label == list && isListItem(bundleIdentifier: context.bundleIdentifier,
            role: element.role, parentRole: parent.role, parentLabel: parent.label)
    }

    static func unreadItem(_ element: DesktopAccessibilityElement, in context: DesktopAccessibilityContext) -> DesktopReadingItem? {
        guard isItem(element, in: context, list: "Chats"),
              element.label.range(of: #"(?i)(?:^|,\s*)[1-9][0-9]* new messages?(?:,|$)"#, options: .regularExpression) != nil else { return nil }
        let components = element.label.components(separatedBy: ", ")
        let isGroup = ["Group", "Channel"].contains(components.first)
        let title = components.dropFirst(isGroup ? 1 : 0).first ?? element.label
        return .init(title: title, category: isGroup ? "group_or_channel" : "unknown_chat_type",
            preview: element.label, unreadEvidence: element.label)
    }

    /// Lock simple, explicit folder-selection requests to that folder. Failure
    /// to select Unread must not authorize opening an unrelated unread chat.
    static func requestedFolder(_ request: String, in context: DesktopAccessibilityContext) -> DesktopAccessibilityElement? {
        let normalized = request.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let matches = context.elements.values.filter { element in
            guard isItem(element, in: context, list: "Folders") else { return false }
            let name = element.label.replacingOccurrences(of: #"\s*\([0-9]+ unread chats?\)$"#, with: "", options: .regularExpression).lowercased()
            guard !name.isEmpty else { return false }
            let pattern = #"^(?:yeah )?(?:please )?(?:(?:can|could) you )?(?:please )?(?:click(?: on)?|open|select|go to|switch to|show) (?:the )?(?:telegram )?"#
                + NSRegularExpression.escapedPattern(for: name) + #"(?: (?:tab|folder|one))?(?: please)?$"#
            return normalized.range(of: pattern, options: .regularExpression) != nil
        }
        return matches.count == 1 ? matches.first : nil
    }
}
