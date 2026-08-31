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

/// User-facing metadata for one deterministic command family. The router and the
/// assistant both read this registry so BtrVoice can accurately explain itself.
struct DesktopVoiceFastPath: Identifiable, Equatable {
    let id: String
    let title: String
    let action: String
    let examples: [String]

    var promptLine: String {
        let spoken = examples.map { "“\($0)”" }.joined(separator: ", ")
        return "- \(title): \(action). Examples: \(spoken)"
    }
}

enum DesktopVoiceRouteResult: Equatable {
    case plan(DesktopVoicePlan)
    case answer(String)
    case unsupported(String)
}

struct DesktopVoiceCommandRouter {
    typealias ApplicationResolver = (String) -> DesktopVoiceApplicationTarget?

    private struct ShortcutRule {
        let definition: DesktopVoiceFastPath
        let commands: Set<String>
        let summary: String
        let combo: String
    }

    static let fastPaths: [DesktopVoiceFastPath] = [
        DesktopVoiceFastPath(
            id: "open-application",
            title: "Open an application",
            action: "Find and activate an installed macOS application",
            examples: ["Open Telegram", "Launch Notes", "Start the browser"]
        ),
        DesktopVoiceFastPath(
            id: "open-application-new-tab",
            title: "Open an application and create a tab",
            action: "Open the application, then press Command-T",
            examples: ["Open Brave and create a new tab", "Start the browser then open a new tab"]
        ),
    ] + shortcutRules.map(\.definition)

    static var assistantContext: String {
        fastPaths.map(\.promptLine).joined(separator: "\n")
    }

    static var helpAnswer: String {
        let rows = fastPaths.enumerated().map { index, path in
            let spoken = path.examples.map { "“\($0)”" }.joined(separator: ", ")
            return "\(index + 1). \(path.title) — \(path.action). Say: \(spoken)"
        }
        return (["I currently have \(fastPaths.count) local fast paths:"] + rows + [
            "You can also ask how to use BtrVoice. Commands outside this list go to the model-backed slow path.",
        ]).joined(separator: "\n")
    }

    static let addingFastPathsAnswer = """
    Fast paths are currently built into DesktopVoiceCommandRouter.swift; there is no in-app Add Command button yet. Each shortcut family has one registry entry containing its name, examples, summary, and allowlisted key combination. Because routing and self-description read the same registry, a new entry appears in this command list automatically.
    """

    private let resolveApplication: ApplicationResolver

    init(resolveApplication: @escaping ApplicationResolver) {
        self.resolveApplication = resolveApplication
    }

    func route(_ transcript: String) -> DesktopVoiceRouteResult {
        let command = Self.normalized(transcript)
        guard !command.isEmpty else {
            return .unsupported("I didn't hear a command.")
        }

        if Self.isAddingFastPathQuestion(command) {
            return .answer(Self.addingFastPathsAnswer)
        }

        if Self.isHelpQuestion(command) {
            return .answer(Self.helpAnswer)
        }

        for rule in Self.shortcutRules where rule.commands.contains(command) {
            return shortcutPlan(summary: rule.summary, combo: rule.combo)
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

    private static func isHelpQuestion(_ command: String) -> Bool {
        if helpCommands.contains(command) { return true }
        let asksToInspect = command.contains("list")
            || command.contains("show")
            || command.contains("look")
            || command.contains("inspect")
            || command.contains("what")
            || command.contains("which")
            || command.contains("tell me")
        return asksToInspect
            && (command.contains("fast path")
                || command.contains("commands")
                || command.contains("can you do")
                || command.contains("capabilities"))
    }

    private static func isAddingFastPathQuestion(_ command: String) -> Bool {
        (command.contains("add") || command.contains("create") || command.contains("make"))
            && (command.contains("fast path") || command.contains("new command"))
    }

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

    private static let helpCommands: Set<String> = [
        "help", "what can you do", "how do i use this", "how do i use voice control",
        "list commands", "show commands", "list fast paths", "show fast paths",
    ]

    private static let shortcutRules: [ShortcutRule] = [
        ShortcutRule(
            definition: DesktopVoiceFastPath(
                id: "new-tab",
                title: "Create a new tab",
                action: "Press Command-T in the target application",
                examples: ["New tab", "Open a new tab", "Create a new tab"]
            ),
            commands: ["new tab", "open new tab", "open a new tab", "create new tab", "create a new tab"],
            summary: "Create a new tab",
            combo: "cmd+t"
        ),
        ShortcutRule(
            definition: DesktopVoiceFastPath(
                id: "close-tab",
                title: "Close the current tab",
                action: "Press Command-W in the target application",
                examples: ["Close tab", "Close this tab", "Close the current tab"]
            ),
            commands: ["close tab", "close the tab", "close this tab", "close current tab", "close the current tab"],
            summary: "Close the current tab",
            combo: "cmd+w"
        ),
        ShortcutRule(
            definition: DesktopVoiceFastPath(
                id: "reload",
                title: "Reload the current page",
                action: "Press Command-R in the target application",
                examples: ["Reload", "Reload the page", "Refresh the page"]
            ),
            commands: ["reload", "reload page", "reload the page", "refresh", "refresh page", "refresh the page"],
            summary: "Reload the current page",
            combo: "cmd+r"
        ),
        ShortcutRule(
            definition: DesktopVoiceFastPath(
                id: "back",
                title: "Go back",
                action: "Press Command-[ in the target application",
                examples: ["Back", "Go back", "Browser back"]
            ),
            commands: ["back", "go back", "browser back"],
            summary: "Go back",
            combo: "cmd+["
        ),
        ShortcutRule(
            definition: DesktopVoiceFastPath(
                id: "forward",
                title: "Go forward",
                action: "Press Command-] in the target application",
                examples: ["Forward", "Go forward", "Browser forward"]
            ),
            commands: ["forward", "go forward", "browser forward"],
            summary: "Go forward",
            combo: "cmd+]"
        ),
    ]
}
