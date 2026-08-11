import AppKit
import Combine

/// Menu-bar presence: state at a glance, plus every command and preference without
/// needing the panel open.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let controller: DictationController
    private let settings = Settings.shared
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    var onTogglePanel: (() -> Void)?

    init(controller: DictationController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        statusItem.menu = menu
        // Insurance against a persisted hidden state (e.g. an accidental ⌘-drag off
        // the bar in a past session, which macOS remembers).
        statusItem.isVisible = true
        statusItem.behavior = []
        statusItem.button?.toolTip = "BtrVoice — ⌥Space to dictate"
        updateIcon()

        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let listening = controller.isListening
        let name = listening ? "waveform.circle.fill" : "waveform"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "BtrVoice")
        image?.isTemplate = !listening
        button.image = image
        button.contentTintColor = listening ? .systemRed : nil
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Pick up a grant made since the last poll so the menu never lags reality.
        PermissionMonitor.shared.refresh()
        menu.removeAllItems()

        let dictate = item(
            controller.isListening ? "Stop Dictation" : "Start Dictation",
            action: #selector(toggleDictation)
        )
        dictate.keyEquivalent = " "
        dictate.keyEquivalentModifierMask = [.option]
        menu.addItem(dictate)

        // The fleet's Jarvis — a separate window, a separate pipeline. Deliberately
        // additive: nothing about dictation changes whether this is used or not.
        menu.addItem(item("Start Jarvis", action: #selector(startJarvis)))

        // Everything else buffer-related lives in the panel UI — the menu stays
        // minimal: dictate, Jarvis, settings, health.
        menu.addItem(.separator())
        menu.addItem(jarvisItem())
        menu.addItem(settingsItem())

        let missing = Permissions.missing
        if !missing.isEmpty {
            menu.addItem(.separator())
            let warning = NSMenuItem(title: "Needs permission: \(missing.joined(separator: ", "))", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            if !Permissions.microphoneGranted {
                menu.addItem(item("Open Microphone Settings…", action: #selector(openMicSettings)))
            }
            if !Permissions.speechGranted {
                menu.addItem(item("Open Speech Recognition Settings…", action: #selector(openSpeechSettings)))
            }
            if !Permissions.accessibilityGranted {
                menu.addItem(item("Open Accessibility Settings…", action: #selector(openAccessibilitySettings)))
                menu.addItem(item("Repair Accessibility Permission…", action: #selector(repairAccessibility)))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Voice Commands…", action: #selector(showVoiceCommandHelp)))
        menu.addItem(item("Diagnostics…", action: #selector(showDiagnostics)))
        menu.addItem(item(
            keyLogMonitor == nil ? "Log Keystroke Timing (60s)" : "Stop Keystroke Logging",
            action: #selector(toggleKeyLogging)
        ))
        menu.addItem(item("Open Log File", action: #selector(openLog)))

        menu.addItem(.separator())
        let restart = item("Restart BtrVoice", action: #selector(restart))
        restart.keyEquivalent = "r"
        restart.keyEquivalentModifierMask = [.command]
        menu.addItem(restart)

        let quitItem = item("Quit BtrVoice", action: #selector(quit))
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
    }

    private func jarvisItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Jarvis", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if JarvisEngine.isAvailable {
            submenu.addItem(toggle("Clean up dictation automatically", #selector(toggleJarvisAuto), settings.jarvisAutoCleanup))
        } else {
            let unavailable = NSMenuItem(
                title: settings.jarvisBackend == .openAI
                    ? "Unavailable — set an OpenAI API key below"
                    : "Unavailable — needs Apple Intelligence",
                action: nil, keyEquivalent: ""
            )
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        }

        let backend = NSMenuItem(title: "AI Backend", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()
        for choice in JarvisBackend.allCases {
            let entry = NSMenuItem(title: choice.label, action: #selector(selectJarvisBackend(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = settings.jarvisBackend == choice ? .on : .off
            if choice == .onDevice, !JarvisEngine.onDeviceAvailable {
                entry.action = nil
                entry.toolTip = "Needs Apple Intelligence on macOS 26+"
            }
            if choice == .openAI, !OpenAIKeyStore.isSet {
                entry.toolTip = "Set an OpenAI API key first"
            }
            backendMenu.addItem(entry)
        }
        backend.submenu = backendMenu
        submenu.addItem(backend)

        submenu.addItem(item(
            OpenAIKeyStore.isSet ? "OpenAI API Key (set) — Change…" : "Set OpenAI API Key…",
            action: #selector(setOpenAIKey)
        ))
        if OpenAIKeyStore.isSet {
            submenu.addItem(item("Remove OpenAI API Key", action: #selector(clearOpenAIKey)))
        }
        if JarvisEngine.onDeviceAvailable {
            submenu.addItem(item("Chat with On-Device AI…", action: #selector(showJarvisChat)))
        }

        submenu.addItem(.separator())
        let count = JarvisNotes.shared.notes.count
        submenu.addItem(item(
            count == 0 ? "Rules… (none yet)" : "Rules… (\(count))",
            action: #selector(showJarvisNotes)
        ))

        parent.submenu = submenu
        return parent
    }

    private func settingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(toggle("Prefer on-device recognition", #selector(toggleOnDevice), settings.onDeviceOnly))
        submenu.addItem(toggle("Automatic punctuation", #selector(toggleAutoPunctuation), settings.autoPunctuation))
        submenu.addItem(toggle("Spoken commands", #selector(toggleVoiceCommands), settings.voiceCommandsEnabled))
        submenu.addItem(toggle("Panel follows the text caret", #selector(toggleFollowCaret), settings.followCaret))
        submenu.addItem(toggle("Stop listening after a pause", #selector(toggleStopOnSilence), settings.stopOnSilence))
        submenu.addItem(toggle("Clear buffer after inserting", #selector(toggleClearAfterCommit), settings.clearAfterCommit))
        submenu.addItem(toggle("Hide panel after inserting", #selector(toggleHideAfterCommit), settings.hideAfterCommit))

        submenu.addItem(.separator())
        let engine = NSMenuItem(title: "Speech engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        let analyzerAvailable = Settings.speechAnalyzerAvailable
        for choice in SpeechEngineChoice.allCases {
            let entry = NSMenuItem(title: choice.label, action: #selector(selectEngine(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = settings.engineChoice == choice ? .on : .off
            if choice == .speechAnalyzer, !analyzerAvailable {
                entry.action = nil
                entry.toolTip = "Requires macOS 26 or later"
            }
            if choice == .gptWhisper || choice == .gptLiveTranscribe || choice == .gptEditor, !OpenAIKeyStore.isSet {
                entry.action = nil
                entry.toolTip = "Needs an OpenAI API key (Jarvis menu → Set OpenAI API Key)"
            }
            engineMenu.addItem(entry)
        }
        let active = DictationController.resolveEngine(from: settings.engineChoice)
        let note = NSMenuItem(
            title: "Active: \(active.label)",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        engineMenu.addItem(.separator())
        engineMenu.addItem(note)
        engine.submenu = engineMenu
        submenu.addItem(engine)

        parent.submenu = submenu
        return parent
    }

    private func item(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        return entry
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.state = on ? .on : .off
        return entry
    }

    private static func truncate(_ text: String, limit: Int = 48) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    // MARK: - Actions

    @objc private func toggleDictation() { controller.toggleDictation() }

    @objc private func startJarvis() {
        DispatchQueue.main.async { JarvisSurfaceWindowController.shared.show() }
    }

    @objc private func toggleOnDevice() { settings.onDeviceOnly.toggle() }
    @objc private func toggleAutoPunctuation() { settings.autoPunctuation.toggle() }
    @objc private func toggleVoiceCommands() { settings.voiceCommandsEnabled.toggle() }
    @objc private func toggleFollowCaret() { settings.followCaret.toggle() }
    @objc private func toggleStopOnSilence() { settings.stopOnSilence.toggle() }
    @objc private func toggleClearAfterCommit() { settings.clearAfterCommit.toggle() }
    @objc private func toggleHideAfterCommit() { settings.hideAfterCommit.toggle() }
    @objc private func toggleJarvisAuto() { settings.jarvisAutoCleanup.toggle() }

    // MARK: - Keystroke timing diagnostic
    //
    // Repeated letters have two very different causes: the OS auto-repeating
    // because a key-up arrived late (isARepeat = true, driven by system latency),
    // or genuinely duplicated events (isARepeat = false — hardware chatter or an
    // event tap re-injecting). Only the flag can tell them apart, so log it.

    private var keyLogMonitor: Any?
    private var keyLogStop: Timer?
    private var keyLogLast: TimeInterval = 0

    @objc private func toggleKeyLogging() {
        if keyLogMonitor != nil {
            stopKeyLogging()
            return
        }
        keyLogLast = 0
        Log.write("keymon: ==== started (type normally for 60s) ====")
        keyLogMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return }
            let now = event.timestamp
            let gap = self.keyLogLast == 0 ? 0 : (now - self.keyLogLast) * 1000
            self.keyLogLast = now

            let kind: String
            switch event.type {
            case .keyDown: kind = "down"
            case .keyUp: kind = "up  "
            default: kind = "mods"
            }
            var mods: [String] = []
            let flags = event.modifierFlags
            if flags.contains(.command) { mods.append("cmd") }
            if flags.contains(.shift) { mods.append("shift") }
            if flags.contains(.option) { mods.append("opt") }
            if flags.contains(.control) { mods.append("ctrl") }
            let repeatFlag = event.type == .keyDown && event.isARepeat ? " AUTOREPEAT" : ""
            // Which app the switcher landed on — the point of the ⌘Tab trace.
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.write(String(
                format: "keymon: %@ key=%3d gap=%6.1fms [%@] front=%@%@",
                kind, event.keyCode, gap, mods.joined(separator: "+"), front, repeatFlag
            ))
        }
        keyLogStop = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.stopKeyLogging()
        }
    }

    private func stopKeyLogging() {
        if let keyLogMonitor { NSEvent.removeMonitor(keyLogMonitor) }
        keyLogMonitor = nil
        keyLogStop?.invalidate()
        keyLogStop = nil
        Log.write("keymon: ==== stopped ====")
    }

    @objc private func showJarvisNotes() {
        Task { @MainActor in JarvisNotesWindowController.shared.show() }
    }
    @objc private func selectJarvisBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = JarvisBackend(rawValue: raw) else { return }
        settings.jarvisBackend = choice
        Log.write("jarvis backend → \(choice.label)")
    }

    @objc private func setOpenAIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored locally in Application Support (owner-only permissions). Used for the OpenAI Jarvis backend and cloud transcription engines."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { OpenAIKeyStore.write(key) }
        }
    }

    @objc private func clearOpenAIKey() {
        OpenAIKeyStore.clear()
        if settings.jarvisBackend == .openAI { settings.jarvisBackend = .onDevice }
    }

    @objc private func showJarvisChat() {
        // Menu actions arrive on the main thread; hop explicitly for the actor.
        Task { @MainActor in JarvisChatWindowController.shared.show() }
    }


    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = SpeechEngineChoice(rawValue: raw) else { return }
        settings.engineChoice = choice
        Log.write("engine choice → \(choice.label) (active: \(DictationController.resolveEngine(from: choice)))")
    }

    @objc private func openMicSettings() { Permissions.openSettings(.microphone) }
    @objc private func openSpeechSettings() { Permissions.openSettings(.speechRecognition) }
    @objc private func openAccessibilitySettings() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    /// A floating cheat-sheet, deliberately not a modal alert: it stays up while you
    /// dictate, and the rest of the app keeps working underneath it.
    private var helpPanel: NSPanel?

    @objc private func showVoiceCommandHelp() {
        if let helpPanel {
            helpPanel.orderFrontRegardless()
            return
        }

        let text = """
        Say “do” plus a command while dictating. Without “do”, the words
        are just transcribed. Each command shows a short countdown in the
        panel before it fires — cancel it or fire it early from there.

        “do paste” — press ⌘V in the focused app
        “do copy” — press ⌘C
        “do select all” — press ⌘A
        “do click” — click at the mouse pointer
        “do insert” — type the buffer into the focused app
        “do send it” — insert the buffer, then press Return
        (These work in the GPT Editor engine too.)

        Say “Jarvis” (or “hey Jarvis”) followed by an instruction:
        “Jarvis, clean this up” — rewrite the staged text
        “Jarvis, replace X with Y” — any edit you can describe
        “Jarvis, remember …” — save a standing rule Jarvis applies
        from then on. Manage notes in the Jarvis menu.

        Keyboard: ⌥Space dictate · ⌥↩ insert · ⌥⎋ discard
        ⌘↩ insert from the panel · backspace button: ⌥-click deletes a word
        """

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.isSelectable = true

        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -18),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Voice Commands"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = padded
        panel.setContentSize(padded.fittingSize)
        panel.center()

        helpPanel = panel
        panel.orderFrontRegardless()
    }

    /// Clears any stale Accessibility entry and re-triggers the system prompt.
    ///
    /// A grant is bound to the app's code signature. If that signature ever changed —
    /// which it did on every rebuild while the app was ad-hoc signed — the entry stays
    /// in the list, still switched on, matching nothing. Removing and re-adding by hand
    /// is fiddly and easy to get wrong, so do it properly here.
    @objc private func repairAccessibility() {
        NSApp.activate(ignoringOtherApps: true)

        let confirm = NSAlert()
        confirm.messageText = "Repair Accessibility permission"
        confirm.informativeText = """
        This clears BtrVoice's existing Accessibility entry and asks macOS for a fresh \
        one, which fixes an entry that looks enabled but no longer applies.

        You'll get the standard system prompt — choose Open System Settings and switch \
        BtrVoice on.
        """
        confirm.addButton(withTitle: "Repair")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.btr.voice"]
        do {
            try reset.run()
            reset.waitUntilExit()
            Log.write("repair: tccutil reset exited \(reset.terminationStatus)")
        } catch {
            Log.write("repair: tccutil failed — \(error.localizedDescription)")
        }

        PermissionMonitor.shared.refresh()
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    @objc private func showDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "BtrVoice diagnostics"
        alert.informativeText = Diagnostics.report(controller: controller)
        alert.addButton(withTitle: "Test Typing")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Close")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Give the user time to click into a text field before events are posted.
            let countdown = NSAlert()
            countdown.messageText = "Typing test"
            countdown.informativeText = """
            Click into a text field in the app you want to test — Telegram, Terminal, \
            anything — then come back and press Start. BtrVoice will wait three seconds \
            and type a short line into whatever has focus.
            """
            countdown.addButton(withTitle: "Start")
            countdown.addButton(withTitle: "Cancel")
            guard countdown.runModal() == .alertFirstButtonReturn else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                Diagnostics.testTyping(controller: self.controller) { outcome in
                    let result = NSAlert()
                    result.messageText = "Typing test"
                    result.informativeText = outcome
                    result.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    result.runModal()
                }
            }

        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Diagnostics.report(controller: controller), forType: .string)

        default:
            break
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            Log.write("log file opened")
        }
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func restart() {
        Log.write("restarting")
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier

        // Wait for this process to actually exit before relaunching: two instances
        // would fight over the status item and the global hotkeys.
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.2; open '\(escaped)'"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            Log.write("restart failed to spawn helper: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
