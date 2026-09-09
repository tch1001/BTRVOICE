/// Keeps user intent and execution evidence separate from model prose and screen content.
import Foundation

enum DesktopVoiceTaskError: LocalizedError {
    case targetChanged(String)
    var errorDescription: String? {
        switch self {
        case .targetChanged(let app): return "The task is still for \(app), but another app took focus. Return to \(app) and ask me to continue; I did not act on the other app."
        }
    }
}

struct DesktopVoiceTaskMemory {
    var request: String
    var updatedAt = Date()

    func resumedRequest(for utterance: String, now: Date = Date()) -> String? {
        guard now.timeIntervalSince(updatedAt) < 600, DesktopVoiceUtterance.isContinuation(utterance) else { return nil }
        return request
    }
}

enum DesktopVoiceUtterance {
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func isContinuation(_ text: String) -> Bool {
        let phrase = words(text).joined(separator: " ")
        return ["yes", "yeah", "yep", "okay", "ok", "go ahead", "continue", "carry on", "do it",
                "yes go ahead", "yeah go ahead", "okay go ahead", "ok go ahead", "please continue",
                "yes please", "yeah do it", "go on", "continue with that"].contains(phrase)
    }

    /// Corrections interrupt immediately, while a new substantive request is then replanned.
    static func isInterruption(_ text: String) -> Bool {
        let tokens = words(text)
        let phrase = tokens.joined(separator: " ")
        if ["stop", "cancel", "cancel that", "stop that", "wait", "hold on", "never mind", "nevermind", "no"].contains(phrase) { return true }
        if tokens.filter({ $0 == "no" }).count >= 2 { return true }
        return ["no ", "wait ", "hold on ", "actually ", "that's wrong", "that s wrong", "you are confused",
                "you re confused", "it doesn t seem to be working", "that isn t working"].contains { phrase.hasPrefix($0) }
    }

    static func isPauseOnly(_ text: String) -> Bool {
        let tokens = words(text)
        if tokens.filter({ $0 == "no" }).count >= 2, let last = tokens.lastIndex(of: "no"),
           tokens.dropFirst(last + 1).allSatisfy({ ["please", "okay", "ok"].contains($0) }) { return true }
        return tokens.allSatisfy { ["no", "stop", "please", "wait", "hold", "on", "cancel", "that", "okay", "ok"].contains($0) }
            || ["never mind", "nevermind"].contains(tokens.joined(separator: " "))
    }
}

struct DesktopVoiceProgress {
    private(set) var attempts = Set<String>()
    private(set) var actionCount = 0
    private(set) var observedChange = false
    private(set) var blockedCount = 0
    private var before: Set<String>?

    /// Snapshot IDs, traversal order and focus alone are not evidence of navigation.
    static func content(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").filter { !$0.hasPrefix("[Partial view:") }.map {
            $0.replacingOccurrences(of: #"\[e\d+(?: parent=e\d+)?\] ?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\be\d+\b"#, with: "element", options: .regularExpression)
                .replacingOccurrences(of: #" \| AXFocused=[^|]*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    static func controlKey(_ command: DesktopUICommand, in context: DesktopAccessibilityContext) -> String {
        let element = context.elements[command.elementID]
        let row = context.text.components(separatedBy: "\n").first { $0.hasPrefix("[\(command.elementID) ") || $0.hasPrefix("[\(command.elementID)]") } ?? ""
        return [String(context.processIdentifier ?? 0), element.map { String(CFHash($0.reference)) } ?? "", element?.role ?? "", element?.label ?? "",
                content(row).sorted().joined(separator: "|"), command.action ?? command.attribute ?? "", command.valueJSON ?? ""].joined(separator: "\n")
    }

    mutating func willAct(key: String, screen: String) -> Bool {
        let stateKey = key + "\nSCREEN\n" + Self.content(screen).sorted().joined(separator: "\n")
        guard attempts.insert(stateKey).inserted else { blockedCount += 1; return false }
        actionCount += 1
        before = Self.content(screen)
        observedChange = false
        return true
    }

    mutating func observe(_ screen: String) {
        if let before, Self.content(screen) != before { observedChange = true }
    }

    var canConfirmCompletion: Bool { actionCount == 0 || observedChange }
}

/// Shared with keyboard workers so cancelling a voice turn stops remaining events.
final class DesktopVoiceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

struct DesktopVoiceTextDraft: Equatable {
    let snapshotID: String
    let elementID: String
    let text: String

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys) == Set(["snapshot_id", "element_id", "text"]),
              let snapshot = arguments["snapshot_id"] as? String, !snapshot.isEmpty,
              let element = arguments["element_id"] as? String, !element.isEmpty,
              let text = arguments["text"] as? String, !text.isEmpty, text.utf8.count <= 16_000,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else {
            throw DesktopAXError.invalid("Prepare text for a field in the current snapshot (up to 16 KB).")
        }
        snapshotID = snapshot; elementID = element; self.text = text
    }
}

struct DesktopVoiceTaskConclusion: Equatable {
    let completed: Bool
    let summary: String
    let evidence: String

    func evidenceIsVisible(in screen: String) -> Bool {
        let text = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if screen.localizedCaseInsensitiveContains(text) { return true }
        // Accept prose whose quoted evidence can all be checked against the actual
        // screen; a model's unquoted assertion alone is never evidence.
        let pattern = #"[\"“]([^\"”]+)[\"”]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let quotes = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        return !quotes.isEmpty && quotes.allSatisfy { $0.count >= 2 && screen.localizedCaseInsensitiveContains($0) }
    }

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys) == Set(["outcome", "summary", "evidence"]),
              let outcome = arguments["outcome"] as? String, ["completed", "blocked"].contains(outcome),
              let summary = arguments["summary"] as? String, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let evidence = arguments["evidence"] as? String else {
            throw DesktopAXError.invalid("Finish with an outcome, summary and screen evidence.")
        }
        completed = outcome == "completed"
        self.summary = String(summary.prefix(2_000)); self.evidence = String(evidence.prefix(1_200))
    }
}

enum DesktopVoiceNavigation {
    static func url(_ text: String) throws -> URL {
        guard text.utf8.count <= 8_000, let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw DesktopAXError.invalid("Open a complete http or https website address.")
        }
        return url
    }
}
