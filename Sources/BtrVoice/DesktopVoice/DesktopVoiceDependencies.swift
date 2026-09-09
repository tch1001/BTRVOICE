/// Allows complete command conversations to be replayed without opening windows or sending input.
import AppKit
import ApplicationServices

struct DesktopVoiceDependencies {
    var targetPID: pid_t
    var resolveApplication: (String) -> DesktopVoiceApplicationTarget? = { _ in nil }
    var respond: @MainActor (String, DesktopVoiceAssistant.Context, DesktopScreenSnapshot?, String?) async throws -> DesktopVoiceAssistantDecision
    var read: @MainActor (DesktopUIScope, AXUIElement?, Int, Bool) async throws -> DesktopScreenSnapshot
    var control: @MainActor (DesktopUICommand, DesktopAccessibilityContext) async throws -> String
    var plan: @MainActor (DesktopVoicePlan, DesktopVoiceCancellation) async throws -> Void
    var openURL: @MainActor (URL) async throws -> Void
    var insertText: @MainActor (String, Bool, DesktopVoiceCancellation) async throws -> Void
    var collect: (@MainActor (DesktopCollectionRequest) async throws -> DesktopReadingCollection)?
    var makeTranscriber: (() -> TranscriptionEngine)?
    var startAudio: (() throws -> Void)?
    var stopAudio: (() -> Void)?
}

struct DesktopVoicePreparedText {
    let id = UUID().uuidString
    let text: String
    let target: DesktopAccessibilityElement
    let context: DesktopAccessibilityContext
    let createdAt = Date()
}
