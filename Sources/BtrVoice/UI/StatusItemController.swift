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

        let insert = item("Insert Buffer into Frontmost App", action: #selector(commit))
        insert.keyEquivalent = "\r"
        insert.keyEquivalentModifierMask = [.option]
        insert.isEnabled = !controller.buffer.isEmpty
        menu.addItem(insert)

        menu.addItem(item("Insert & Send", action: #selector(commitAndSend), enabled: !controller.buffer.isEmpty))
        menu.addItem(item("Show Dictation Panel", action: #selector(togglePanel)))
        menu.addItem(.separator())

        let preview = controller.buffer.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewItem = NSMenuItem(
            title: preview.isEmpty ? "Buffer is empty" : "“\(Self.truncate(preview))”",
            action: nil,
            keyEquivalent: ""
        )
        previewItem.isEnabled = false
        menu.addItem(previewItem)
        if !preview.isEmpty {
            menu.addItem(item("Copy Buffer", action: #selector(copyBuffer)))
            menu.addItem(item("Clear Buffer", action: #selector(clearBuffer)))
        }

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
            submenu.addItem(item("Chat with On-Device AI…", action: #selector(showJarvisChat)))
        } else {
            let unavailable = NSMenuItem(title: "Unavailable — needs Apple Intelligence", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            submenu.addItem(unavailable)
        }

        submenu.addItem(.separator())
        let notes = JarvisNotes.shared.notes
        if notes.isEmpty {
            let empty = NSMenuItem(title: "No notes yet — say “Jarvis, remember …”", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Notes (\(notes.count))", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for note in notes {
                let entry = NSMenuItem(title: Self.truncate(note.text), action: nil, keyEquivalent: "")
                entry.toolTip = note.text
                let noteMenu = NSMenu()
                let delete = NSMenuItem(title: "Delete This Note", action: #selector(deleteJarvisNote(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = note.id.uuidString
                noteMenu.addItem(delete)
                entry.submenu = noteMenu
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
            submenu.addItem(item("Delete All Notes…", action: #selector(deleteAllJarvisNotes)))
        }

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
            engineMenu.addItem(entry)
        }
        let active = DictationController.resolveEngine(from: settings.engineChoice)
        let note = NSMenuItem(
            title: "Active: \(active == .speechAnalyzer ? "SpeechAnalyzer" : "SFSpeechRecognizer")",
            action: nil,
            keyEquivalent: ""
        )
        note.isEnabled = false
        engineMenu.addItem(.separator())
        engineMenu.addItem(note)
        engine.submenu = engineMenu
        submenu.addItem(engine)

        let injection = NSMenuItem(title: "How to insert text", action: nil, keyEquivalent: "")
        let injectionMenu = NSMenu()
        for mode in InjectionMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(selectInjectionMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = settings.injectionMode == mode ? .on : .off
            injectionMenu.addItem(entry)
        }
        injection.submenu = injectionMenu
        submenu.addItem(injection)

        let newline = NSMenuItem(title: "How to type newlines", action: nil, keyEquivalent: "")
        let newlineMenu = NSMenu()
        for mode in NewlineMode.allCases {
            let entry = NSMenuItem(title: mode.label, action: #selector(selectNewlineMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = settings.newlineMode == mode ? .on : .off
            newlineMenu.addItem(entry)
        }
        newline.submenu = newlineMenu
        submenu.addItem(newline)

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
    @objc private func commit() { controller.commit(send: false) }
    @objc private func commitAndSend() { controller.commit(send: true) }
    @objc private func togglePanel() { onTogglePanel?() }
    @objc private func copyBuffer() { controller.copyBufferToPasteboard() }
    @objc private func clearBuffer() { controller.clearBuffer() }

    @objc private func toggleOnDevice() { settings.onDeviceOnly.toggle() }
    @objc private func toggleAutoPunctuation() { settings.autoPunctuation.toggle() }
    @objc private func toggleVoiceCommands() { settings.voiceCommandsEnabled.toggle() }
    @objc private func toggleFollowCaret() { settings.followCaret.toggle() }
    @objc private func toggleStopOnSilence() { settings.stopOnSilence.toggle() }
    @objc private func toggleClearAfterCommit() { settings.clearAfterCommit.toggle() }
    @objc private func toggleHideAfterCommit() { settings.hideAfterCommit.toggle() }
    @objc private func toggleJarvisAuto() { settings.jarvisAutoCleanup.toggle() }
    @objc private func showJarvisChat() {
        // Menu actions arrive on the main thread; hop explicitly for the actor.
        Task { @MainActor in JarvisChatWindowController.shared.show() }
    }

    @objc private func deleteJarvisNote(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        JarvisNotes.shared.delete(id: id)
    }

    @objc private func deleteAllJarvisNotes() {
        let alert = NSAlert()
        alert.messageText = "Delete all of Jarvis's notes?"
        alert.informativeText = "Jarvis will forget every saved rule. This cannot be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            JarvisNotes.shared.deleteAll()
        }
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = SpeechEngineChoice(rawValue: raw) else { return }
        settings.engineChoice = choice
        Log.write("engine choice → \(choice.label) (active: \(DictationController.resolveEngine(from: choice)))")
    }

    @objc private func selectInjectionMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = InjectionMode(rawValue: raw) else { return }
        settings.injectionMode = mode
    }

    @objc private func selectNewlineMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = NewlineMode(rawValue: raw) else { return }
        settings.newlineMode = mode
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
        “do send it” — insert the buffer, then press Return

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
