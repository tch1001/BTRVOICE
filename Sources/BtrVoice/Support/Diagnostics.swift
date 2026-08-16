import AppKit

/// Answers "why didn't that work?" without needing a debugger attached.
enum Diagnostics {

    static func report(controller: DictationController) -> String {
        PermissionMonitor.shared.refresh()
        let monitor = PermissionMonitor.shared
        let settings = Settings.shared

        var lines: [String] = []
        lines.append("Bundle:        \(Bundle.main.bundleURL.path)")
        lines.append("Signature:     \(signingIdentity())")
        lines.append("")
        lines.append("Microphone:    \(mark(monitor.microphone))")
        lines.append("Speech:        \(mark(monitor.speech))")
        lines.append("Accessibility: \(mark(monitor.accessibility))")
        lines.append("")
        lines.append("Hotkeys:       \(HotkeyManager.shared.registrationSummary)")
        lines.append("Last hotkey:   \(HotkeyManager.shared.lastFiredDescription)")
        lines.append("")
        lines.append("Target app:    \(controller.targets.targetName ?? "none")")
        lines.append("Buffer:        \(controller.buffer.committedText.count) characters")
        let active = DictationController.resolveEngine(from: settings.engineChoice)
        lines.append("Engine:        \(active == .speechAnalyzer ? "SpeechAnalyzer (macOS 26)" : "SFSpeechRecognizer (legacy)") — setting: \(settings.engineChoice.label)")
        lines.append("Input:         \(AudioInputSourceCatalog.selectionLabel(sourceID: settings.inputSourceID, savedName: settings.inputSourceName))")
        lines.append("Insert mode:   \(settings.injectionMode.label)")
        lines.append("Newlines:      \(settings.newlineMode.label)")
        lines.append("Recognition:   \(settings.onDeviceOnly ? "on-device preferred" : "server")")
        lines.append("")
        lines.append("Log file:      \(Log.fileURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func mark(_ granted: Bool) -> String {
        granted ? "granted" : "NOT GRANTED"
    }

    private static func signingIdentity() -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code
        else { return "unknown" }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return "unknown" }

        if let certs = dict["certificates"] as? [SecCertificate], let leaf = certs.first {
            let name = SecCertificateCopySubjectSummary(leaf) as String? ?? "certificate"
            return "signed by \(name) — grants survive rebuilds"
        }
        return "ad-hoc — grants break on every rebuild"
    }

    /// Types a known string into whatever had focus, so the injection path can be
    /// proven end to end without depending on the microphone working first.
    static func testTyping(controller: DictationController, completion: @escaping (String) -> Void) {
        guard Permissions.accessibilityGranted else {
            completion("Accessibility is not granted, so nothing can be typed.")
            return
        }
        let target = controller.targets.targetName ?? "the frontmost app"
        Log.write("diagnostics: typing test into \(target)")

        controller.targets.focusTarget { focused in
            TextInjector.inject(
                "BtrVoice typing test ✓",
                mode: .typing,
                newlineMode: Settings.shared.newlineMode,
                pressReturnAfter: false
            ) { result in
                switch result {
                case .success:
                    let note = focused ? "" : " (could not bring it forward first)"
                    Log.write("diagnostics: typing test posted\(note)")
                    completion("Sent “BtrVoice typing test ✓” to \(target)\(note).\n\nIf nothing appeared there, the events are being posted but that app is rejecting them.")
                case .failure(let error):
                    Log.write("diagnostics: typing test failed — \(error.localizedDescription)")
                    completion("Failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
