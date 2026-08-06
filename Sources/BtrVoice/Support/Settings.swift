import Foundation

enum InjectionMode: String, CaseIterable {
    /// Synthesise unicode key events. Works everywhere, including Terminal and Telegram.
    case typing
    /// Stash the pasteboard, set our text, send ⌘V, restore. Much faster for long text.
    case paste
    /// Type short text, paste anything above `TextInjector.pasteThreshold`.
    case auto

    var label: String {
        switch self {
        case .typing: return "Type keystrokes"
        case .paste: return "Paste (⌘V)"
        case .auto: return "Automatic"
        }
    }
}

enum SpeechEngineChoice: String, CaseIterable {
    /// Newest engine the OS offers. SpeechAnalyzer on macOS 26+, legacy before.
    case automatic
    case speechAnalyzer
    case legacy

    var label: String {
        switch self {
        case .automatic: return "Automatic (newest available)"
        case .speechAnalyzer: return "SpeechAnalyzer (macOS 26+)"
        case .legacy: return "SFSpeechRecognizer (legacy)"
        }
    }
}

enum NewlineMode: String, CaseIterable {
    /// Press the physical Return key. Correct for Terminal; sends the message in chat apps.
    case returnKey
    /// Press ⇧Return. Correct for chat apps where Return sends.
    case shiftReturn
    /// Embed \n in the unicode payload. Some apps ignore it entirely.
    case literal

    var label: String {
        switch self {
        case .returnKey: return "Return key"
        case .shiftReturn: return "Shift-Return (chat apps)"
        case .literal: return "Literal newline"
        }
    }
}

/// UserDefaults-backed preferences. Observable so both the SwiftUI panel and the
/// status-item menu stay in sync.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let store = UserDefaults.standard

    @Published var onDeviceOnly: Bool { didSet { store.set(onDeviceOnly, forKey: Key.onDeviceOnly) } }
    @Published var autoPunctuation: Bool { didSet { store.set(autoPunctuation, forKey: Key.autoPunctuation) } }
    @Published var voiceCommandsEnabled: Bool { didSet { store.set(voiceCommandsEnabled, forKey: Key.voiceCommands) } }
    @Published var injectionMode: InjectionMode { didSet { store.set(injectionMode.rawValue, forKey: Key.injectionMode) } }
    @Published var newlineMode: NewlineMode { didSet { store.set(newlineMode.rawValue, forKey: Key.newlineMode) } }
    @Published var followCaret: Bool { didSet { store.set(followCaret, forKey: Key.followCaret) } }
    @Published var stopOnSilence: Bool { didSet { store.set(stopOnSilence, forKey: Key.stopOnSilence) } }
    @Published var silenceTimeout: Double { didSet { store.set(silenceTimeout, forKey: Key.silenceTimeout) } }
    @Published var clearAfterCommit: Bool { didSet { store.set(clearAfterCommit, forKey: Key.clearAfterCommit) } }
    @Published var hideAfterCommit: Bool { didSet { store.set(hideAfterCommit, forKey: Key.hideAfterCommit) } }
    @Published var localeIdentifier: String { didSet { store.set(localeIdentifier, forKey: Key.locale) } }
    @Published var engineChoice: SpeechEngineChoice { didSet { store.set(engineChoice.rawValue, forKey: Key.engineChoice) } }
    /// When on, Jarvis cleans up every utterance automatically; when off, only
    /// on an explicit "Jarvis, …" command.
    @Published var jarvisAutoCleanup: Bool { didSet { store.set(jarvisAutoCleanup, forKey: Key.jarvisAutoCleanup) } }

    private enum Key {
        static let onDeviceOnly = "onDeviceOnly"
        static let autoPunctuation = "autoPunctuation"
        static let voiceCommands = "voiceCommandsEnabled"
        static let injectionMode = "injectionMode"
        static let newlineMode = "newlineMode"
        static let followCaret = "followCaret"
        static let stopOnSilence = "stopOnSilence"
        static let silenceTimeout = "silenceTimeout"
        static let clearAfterCommit = "clearAfterCommit"
        static let hideAfterCommit = "hideAfterCommit"
        static let locale = "localeIdentifier"
        static let engineChoice = "engineChoice"
        static let jarvisAutoCleanup = "jarvisAutoCleanup"
    }

    private init() {
        store.register(defaults: [
            Key.onDeviceOnly: true,
            Key.autoPunctuation: true,
            Key.voiceCommands: true,
            Key.injectionMode: InjectionMode.auto.rawValue,
            Key.newlineMode: NewlineMode.returnKey.rawValue,
            Key.followCaret: true,
            Key.stopOnSilence: false,
            Key.silenceTimeout: 2.5,
            Key.clearAfterCommit: true,
            // Stays up so a dictate → insert → keep talking loop doesn't require
            // re-summoning the panel every round.
            Key.hideAfterCommit: false,
            Key.locale: Locale.current.identifier,
            Key.engineChoice: SpeechEngineChoice.automatic.rawValue,
            Key.jarvisAutoCleanup: false,
        ])

        onDeviceOnly = store.bool(forKey: Key.onDeviceOnly)
        autoPunctuation = store.bool(forKey: Key.autoPunctuation)
        voiceCommandsEnabled = store.bool(forKey: Key.voiceCommands)
        injectionMode = InjectionMode(rawValue: store.string(forKey: Key.injectionMode) ?? "") ?? .auto
        newlineMode = NewlineMode(rawValue: store.string(forKey: Key.newlineMode) ?? "") ?? .returnKey
        followCaret = store.bool(forKey: Key.followCaret)
        stopOnSilence = store.bool(forKey: Key.stopOnSilence)
        silenceTimeout = store.double(forKey: Key.silenceTimeout)
        clearAfterCommit = store.bool(forKey: Key.clearAfterCommit)
        hideAfterCommit = store.bool(forKey: Key.hideAfterCommit)
        localeIdentifier = store.string(forKey: Key.locale) ?? Locale.current.identifier
        engineChoice = SpeechEngineChoice(rawValue: store.string(forKey: Key.engineChoice) ?? "") ?? .automatic
        jarvisAutoCleanup = store.bool(forKey: Key.jarvisAutoCleanup)
    }

    /// Whether the modern engine can actually run here, so pickers can grey it out.
    static var speechAnalyzerAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SpeechAnalyzerEngine.runtimeSupported
        }
        return false
    }
}
