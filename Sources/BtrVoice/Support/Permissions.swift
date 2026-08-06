import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// The three TCC gates BtrVoice needs: microphone, speech recognition, and
/// accessibility (the last one for both caret lookup and posting key events).
enum Permissions {

    // MARK: Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    // MARK: Speech recognition

    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestSpeech(_ completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        default:
            completion(false)
        }
    }

    // MARK: Accessibility

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system "grant access" prompt. Returns the current (pre-grant) state;
    /// macOS never flips this synchronously, so callers should poll.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Settings deep links

    static func openSettings(_ pane: Pane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum Pane {
        case microphone, speechRecognition, accessibility

        var urlString: String {
            switch self {
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .speechRecognition:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
        }
    }

    /// Human-readable list of what is still missing, for the menu and the panel banner.
    static var missing: [String] {
        var out: [String] = []
        if !microphoneGranted { out.append("Microphone") }
        if !speechGranted { out.append("Speech Recognition") }
        if !accessibilityGranted { out.append("Accessibility") }
        return out
    }
}
