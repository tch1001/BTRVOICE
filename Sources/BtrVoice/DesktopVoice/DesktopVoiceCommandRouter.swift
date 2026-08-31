import Foundation

/// Converts short spoken desktop commands into deterministic, low-latency plans.
/// The router is intentionally independent from transcription and execution so a
/// future LLM planner can sit behind it without slowing down familiar commands.
struct DesktopVoiceApplicationTarget: Equatable {
    let displayName: String
    let bundleIdentifier: String?
    let applicationURL: URL
}

enum DesktopVoiceAction: Equatable {
    case openApplication(DesktopVoiceApplicationTarget)
    case pressShortcut(String)
}

struct DesktopVoicePlan: Equatable {
    let summary: String
    let actions: [DesktopVoiceAction]
}

enum DesktopVoiceRouteResult: Equatable {
    case plan(DesktopVoicePlan)
    case unsupported(String)
}

struct DesktopVoiceCommandRouter {
    typealias ApplicationResolver = (String) -> DesktopVoiceApplicationTarget?

    private let resolveApplication: ApplicationResolver

    init(resolveApplication: @escaping ApplicationResolver) {
        self.resolveApplication = resolveApplication
    }

    func route(_ transcript: String) -> DesktopVoiceRouteResult {
        let command = Self.normalized(transcript)
        guard !command.isEmpty else {
            return .unsupported("I didn't hear a command.")
        }

        if Self.newTabCommands.contains(command) {
            return shortcutPlan(summary: "Create a new tab", combo: "cmd+t")
        }
        if Self.closeTabCommands.contains(command) {
            return shortcutPlan(summary: "Close the current tab", combo: "cmd+w")
        }
        if Self.reloadCommands.contains(command) {
            return shortcutPlan(summary: "Reload the current page", combo: "cmd+r")
        }
        if Self.backCommands.contains(command) {
            return shortcutPlan(summary: "Go back", combo: "cmd+[")
        }
        if Self.forwardCommands.contains(command) {
            return shortcutPlan(summary: "Go forward", combo: "cmd+]")
        }

        guard let remainder = Self.strippingLaunchVerb(from: command) else {
            return .unsupported("That isn't in the fast command set yet.")
        }

        let (applicationPhrase, wantsNewTab) = Self.splitNewTabSuffix(from: remainder)
        let cleanedApplication = Self.strippingLeadingArticle(from: applicationPhrase)
        guard !cleanedApplication.isEmpty else {
            return .unsupported("Tell me which application to open.")
        }
        guard let application = resolveApplication(cleanedApplication) else {
            return .unsupported("I couldn't find an application called \(cleanedApplication).")
        }

        var actions: [DesktopVoiceAction] = [.openApplication(application)]
        if wantsNewTab {
            actions.append(.pressShortcut("cmd+t"))
        }
        let summary = wantsNewTab
            ? "Open \(application.displayName) and create a new tab"
            : "Open \(application.displayName)"
        return .plan(DesktopVoicePlan(summary: summary, actions: actions))
    }

    private func shortcutPlan(summary: String, combo: String) -> DesktopVoiceRouteResult {
        .plan(DesktopVoicePlan(summary: summary, actions: [.pressShortcut(combo)]))
    }

    private static let launchVerbs = ["open ", "launch ", "start "]

    private static func strippingLaunchVerb(from command: String) -> String? {
        for verb in launchVerbs where command.hasPrefix(verb) {
            return String(command.dropFirst(verb.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func splitNewTabSuffix(from command: String) -> (String, Bool) {
        let suffixes = [
            " and open a new tab", " and create a new tab", " and make a new tab",
            " then open a new tab", " then create a new tab", " then make a new tab",
            " and open new tab", " and create new tab", " and make new tab",
            " then open new tab", " then create new tab", " then make new tab",
            " and a new tab", " then a new tab", " and new tab", " then new tab",
        ]
        for suffix in suffixes where command.hasSuffix(suffix) {
            let application = String(command.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (application, true)
        }
        return (command, false)
    }

    private static func strippingLeadingArticle(from text: String) -> String {
        for article in ["the ", "a ", "an "] where text.hasPrefix(article) {
            return String(text.dropFirst(article.count))
        }
        return text
    }

    private static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]")).contains(scalar)
                ? Character(String(scalar))
                : " "
        }
        return String(cleaned)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static let newTabCommands: Set<String> = [
        "new tab", "open new tab", "open a new tab", "create new tab", "create a new tab",
    ]
    private static let closeTabCommands: Set<String> = [
        "close tab", "close the tab", "close this tab", "close current tab", "close the current tab",
    ]
    private static let reloadCommands: Set<String> = [
        "reload", "reload page", "reload the page", "refresh", "refresh page", "refresh the page",
    ]
    private static let backCommands: Set<String> = [
        "back", "go back", "browser back",
    ]
    private static let forwardCommands: Set<String> = [
        "forward", "go forward", "browser forward",
    ]
}
