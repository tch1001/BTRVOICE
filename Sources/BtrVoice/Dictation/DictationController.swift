import AVFoundation
import AppKit
import Foundation

/// Orchestrates capture → recognition → buffer → injection.
///
/// The flow is deliberately two-phase: speech only ever mutates the local buffer,
/// and a separate explicit commit turns that buffer into keystrokes. Nothing reaches
/// the focused app until the user says so.
final class DictationController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case finishing
        case committing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var status: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var usingOnDeviceRecognition = false

    let buffer = TextBuffer()
    let targets = TargetTracker()

    /// Set by the app delegate to drive the floating panel.
    var showPanel: (() -> Void)?
    var hidePanel: (() -> Void)?
    var repositionPanel: (() -> Void)?
    /// Give up keyboard focus so injected events land in the target app, not in us.
    var releaseFocus: (() -> Void)?

    private let settings = Settings.shared
    private let audio = AudioCapture()
    private var engine: TranscriptionEngine?
    private var policyTimer: Timer?

    /// Commit requested while audio was still draining.
    private struct PendingCommit {
        let send: Bool
    }
    private var pendingCommit: PendingCommit?
    /// The user hit Insert mid-dictation; go back to listening once the text is out.
    private var resumeAfterCommit = false
    private var pendingCommitDeadline: Timer?

    var isListening: Bool { phase == .listening }

    // MARK: - Public control

    func toggleDictation() {
        switch phase {
        case .listening, .finishing:
            stopListening()
        case .idle, .committing:
            startListening()
        }
    }

    func startListening() {
        guard phase == .idle || phase == .committing else { return }
        errorMessage = nil
        Log.write("startListening (mic=\(Permissions.microphoneGranted) speech=\(Permissions.speechGranted) ax=\(Permissions.accessibilityGranted))")

        // We're a background accessory app, so a first-run TCC prompt can open behind
        // everything and look like nothing happened at all. Come forward for it.
        if !Permissions.microphoneGranted || !Permissions.speechGranted {
            NSApp.activate(ignoringOtherApps: true)
        }

        Permissions.requestMicrophone { [weak self] micOK in
            guard let self else { return }
            guard micOK else {
                self.fail("Microphone access denied. Grant it in System Settings › Privacy & Security › Microphone.")
                Permissions.openSettings(.microphone)
                return
            }
            Permissions.requestSpeech { [weak self] speechOK in
                guard let self else { return }
                guard speechOK else {
                    self.fail("Speech Recognition access denied. Grant it in System Settings › Privacy & Security › Speech Recognition.")
                    Permissions.openSettings(.speechRecognition)
                    return
                }
                self.beginSession()
            }
        }
    }

    /// Stops capture and flushes the recogniser. The buffer is kept for review.
    func stopListening() {
        guard phase == .listening else { return }
        phase = .finishing
        status = "Finishing…"
        audio.stop()
        stopPolicyTimer()
        level = 0
        engine?.finish()
    }

    /// Sends the buffer to the focused app as keystrokes.
    func commit(send: Bool = false) {
        // Inserting shouldn't end the conversation: if they were talking, pick the
        // microphone back up as soon as the text is delivered.
        if phase == .listening { resumeAfterCommit = true }
        if phase == .listening || phase == .finishing {
            // Let the tail of speech land before typing anything.
            pendingCommit = PendingCommit(send: send)
            armPendingCommitTimeout()
            stopListening()
            return
        }
        performCommit(send: send)
    }

    /// Throws the buffer away without typing anything.
    func cancel() {
        resumeAfterCommit = false
        pendingCommit = nil
        pendingCommitDeadline?.invalidate()
        pendingCommandTimer?.invalidate()
        pendingCommand = nil
        if phase == .listening || phase == .finishing {
            audio.stop()
            stopPolicyTimer()
            // Cancelling marks every segment resolved, so no late result can push text
            // back into the buffer we're about to clear.
            engine?.cancel()
            retireEngine(cancelling: false)
        }
        level = 0
        buffer.clear()
        phase = .idle
        status = ""
        hidePanel?()
    }

    func clearBuffer() {
        // Order matters: discard first, so a final result racing in right now is
        // already marked stale before the buffer empties.
        engine?.discardUtterance()
        buffer.clear()
    }

    /// The user edited into the live grey text. Freeze the whole thing as theirs and
    /// stop the recogniser from finishing (and re-appending) that utterance.
    func adoptEditedText(_ value: String) {
        engine?.discardUtterance()
        buffer.adoptDisplayedText(value)
    }

    /// The panel's ⌫ button: a literal Backspace keystroke in the target app.
    /// The panel is non-activating, so the target still has focus when the button is
    /// clicked — the event lands at its cursor with no focus juggling needed.
    func pressBackspaceInTarget(wordwise: Bool) {
        guard Permissions.accessibilityGranted else {
            fail("Accessibility access is required to press keys in other apps.")
            return
        }
        TextInjector.pressBackspace(wordwise: wordwise) { [weak self] result in
            if case .failure(let error) = result {
                self?.fail(error.localizedDescription)
            }
        }
    }

    func copyBufferToPasteboard() {
        // What you see is what you copy, live tail included.
        let text = buffer.displayText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied to clipboard"
    }

    // MARK: - Segment application & Jarvis

    /// Applies a finalised segment's actions to the buffer and routes any
    /// escalated command. Safe to call from any thread.
    private func applySegmentActions(_ actions: [BufferAction]) {
        let escalated = buffer.apply(actions)
        guard let request = escalated.first else { return }
        // A spoken command would otherwise re-enter the engine from inside its
        // own callback; let the current one unwind first.
        DispatchQueue.main.async {
            if case .jarvis(let instruction) = request {
                self.handleJarvis(instruction)
            } else {
                self.stagePendingCommand(request)
            }
        }
    }

    /// Serialises auto-cleanup so overlapping segments land in spoken order.
    private var jarvisChain: Task<Void, Never>?

    private func enqueueJarvisAutoClean(_ actions: [BufferAction]) {
        let previous = jarvisChain
        jarvisChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var cleaned: [BufferAction] = []
            for action in actions {
                if case .insert(let fragment) = action {
                    let result = (try? await JarvisEngine.cleanup(fragment)) ?? fragment
                    cleaned.append(.insert(result))
                } else {
                    cleaned.append(action)
                }
            }
            self.applySegmentActions(cleaned)
        }
    }

    /// A spoken "Jarvis, …" instruction. "remember" is stored locally; anything
    /// else rewrites the staged buffer via the on-device model. Both act on the
    /// local buffer only, and edits are undoable — so no confirmation countdown.
    private func handleJarvis(_ instruction: String) {
        guard JarvisEngine.isAvailable else {
            status = settings.jarvisBackend == .openAI
                ? "Jarvis (OpenAI) needs an API key — see the Jarvis menu"
                : "Jarvis needs Apple Intelligence on this Mac"
            Log.write("jarvis: unavailable — instruction dropped: \(instruction)")
            return
        }

        switch JarvisEngine.classify(instruction) {
        case .remember(let note):
            guard !note.isEmpty else {
                status = "Jarvis: remember what?"
                return
            }
            JarvisNotes.shared.add(note)
            status = "Jarvis will remember that"

        case .edit(let utterance):
            buffer.flushPartial()
            let text = buffer.committedText
            status = "Jarvis is thinking…"
            Log.write("jarvis: edit — \(utterance)")
            Task { [weak self] in
                do {
                    let result = try await JarvisEngine.rewrite(text, utterance: utterance)
                    await MainActor.run {
                        guard let self else { return }
                        self.buffer.replace(with: result)
                        self.status = "Jarvis updated the text (undo: ⌘Z in panel)"
                    }
                } catch {
                    await MainActor.run {
                        self?.status = "Jarvis failed: \(error.localizedDescription)"
                        Log.write("jarvis: edit failed — \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Voice commands

    /// Grace period between hearing a command and performing it.
    static let pendingCommandGrace: TimeInterval = 3.0

    struct PendingCommand: Equatable {
        let action: BufferAction
        let label: String
        /// When the command fires unless cancelled — drives the countdown in the UI.
        let firesAt: Date
    }

    @Published private(set) var pendingCommand: PendingCommand?
    private var pendingCommandTimer: Timer?

    /// A spoken command doesn't fire immediately: the panel shows what's about to
    /// happen, and the user gets a few seconds to cancel it (or fire it early).
    private func stagePendingCommand(_ action: BufferAction) {
        let label: String
        switch action {
        case .pasteInTarget: label = "Paste (⌘V)"
        case .copyInTarget: label = "Copy (⌘C)"
        case .selectAllInTarget: label = "Select All (⌘A)"
        case .clickAtPointer: label = "Click"
        case .commit: label = "Insert"
        case .commitAndSend: label = "Insert & Send"
        case .insert, .jarvis: return
        }
        pendingCommandTimer?.invalidate()
        pendingCommand = PendingCommand(
            action: action,
            label: label,
            firesAt: Date().addingTimeInterval(Self.pendingCommandGrace)
        )
        showPanel?()
        pendingCommandTimer = Timer.scheduledTimer(
            withTimeInterval: Self.pendingCommandGrace, repeats: false
        ) { [weak self] _ in
            self?.firePendingCommand()
        }
    }

    /// The countdown elapsed, or the user clicked "Now".
    func firePendingCommand() {
        pendingCommandTimer?.invalidate()
        pendingCommandTimer = nil
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        perform(pending.action)
    }

    func cancelPendingCommand() {
        pendingCommandTimer?.invalidate()
        pendingCommandTimer = nil
        pendingCommand = nil
        status = "Command cancelled"
    }

    private func perform(_ action: BufferAction) {
        guard Permissions.accessibilityGranted else {
            fail("Accessibility access is required to control other apps.")
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
            return
        }
        let done: (Result<Void, TextInjector.InjectionError>) -> Void = { [weak self] result in
            if case .failure(let error) = result {
                self?.fail(error.localizedDescription)
            }
        }
        switch action {
        case .pasteInTarget:
            Log.write("voice command: paste (⌘V)")
            status = "Pasted"
            TextInjector.pressShortcut(.paste, completion: done)
        case .copyInTarget:
            Log.write("voice command: copy (⌘C)")
            status = "Copied"
            TextInjector.pressShortcut(.copy, completion: done)
        case .selectAllInTarget:
            Log.write("voice command: select all (⌘A)")
            status = "Selected all"
            TextInjector.pressShortcut(.selectAll, completion: done)
        case .clickAtPointer:
            Log.write("voice command: click at pointer")
            status = "Clicked"
            TextInjector.clickAtPointer(completion: done)
        case .commit:
            Log.write("voice command: insert")
            commit(send: false)
        case .commitAndSend:
            Log.write("voice command: insert & send")
            commit(send: true)
        case .insert, .jarvis:
            break
        }
    }

    // MARK: - Session lifecycle

    /// Which engine a session started right now would use.
    static func resolveEngine(from choice: SpeechEngineChoice) -> SpeechEngineChoice {
        switch choice {
        case .gptWhisper, .gptLiveTranscribe, .gptEditor:
            // Cloud engines need a key; fall back to the local stack without one.
            if OpenAIKeyStore.isSet { return choice }
        case .automatic, .speechAnalyzer, .legacy:
            break
        }
        if #available(macOS 26.0, *), choice != .legacy, SpeechAnalyzerEngine.runtimeSupported {
            return .speechAnalyzer
        }
        return .legacy
    }

    private func makeEngine() -> TranscriptionEngine {
        let locale = Locale(identifier: settings.localeIdentifier)
        switch Self.resolveEngine(from: settings.engineChoice) {
        case .gptWhisper:
            return OpenAITranscribeEngine(model: "gpt-realtime-whisper", displayName: "GPT Realtime Whisper")
        case .gptLiveTranscribe:
            return OpenAITranscribeEngine(model: "gpt-live-transcribe", displayName: "GPT Live Transcribe")
        case .gptEditor:
            return OpenAIEditorEngine(seedTranscript: buffer.committedText)
        case .speechAnalyzer:
            if #available(macOS 26.0, *) {
                return SpeechAnalyzerEngine(locale: locale)
            }
            fallthrough
        default:
            return AppleSpeechEngine(
                locale: locale,
                onDeviceOnly: settings.onDeviceOnly,
                addsPunctuation: settings.autoPunctuation
            )
        }
    }

    private func beginSession() {
        guard phase != .listening else { return }

        let engine = makeEngine()
        self.engine = engine
        usingOnDeviceRecognition = engine.isOnDevice

        engine.onPartial = { [weak self] text in
            self?.buffer.setPartial(text)
        }
        if let editor = engine as? OpenAIEditorEngine {
            // Semantic app commands ("copy the highlighted text") and the
            // streaming rewrite preview, both delivered on the main thread.
            editor.onCommand = { [weak self] action in
                self?.stagePendingCommand(action)
            }
            editor.onReplacementPreview = { [weak self] preview in
                self?.buffer.setReplacementPreview(preview)
            }
        }
        engine.onSegmentFinal = { [weak self, weak engine] text in
            guard let self else { return }

            // Editor-style engines deliver the complete intended transcript:
            // replace the buffer wholesale. Spoken commands arrive as [[cmd:…]]
            // markers the editor was instructed to emit instead of prose.
            if engine?.replacesBuffer == true {
                let (cleaned, commands) = VoiceCommands.extractEditorCommands(text)
                DispatchQueue.main.async {
                    if !cleaned.isEmpty || commands.isEmpty {
                        self.buffer.replace(with: cleaned)
                    }
                    if let command = commands.first {
                        self.stagePendingCommand(command)
                    }
                }
                return
            }

            let actions = VoiceCommands.parse(text, enabled: self.settings.voiceCommandsEnabled)

            if self.settings.jarvisAutoCleanup, JarvisEngine.isAvailable {
                // Auto mode: every plain utterance goes through Jarvis first. The
                // chain keeps segments in spoken order even when cleanups overlap.
                self.enqueueJarvisAutoClean(actions)
            } else {
                self.applySegmentActions(actions)
            }
        }
        engine.onFinished = { [weak self] in
            self?.handleRecognitionFinished()
        }
        engine.onError = { [weak self] error in
            self?.fail(error.localizedDescription)
        }
        engine.onStatus = { [weak self] message in
            self?.status = message
        }

        audio.onBuffer = { [weak engine] pcm in
            engine?.append(pcm)
        }
        audio.onLevel = { [weak self] value in
            self?.level = value
        }

        do {
            try engine.start()
            try audio.start()
        } catch {
            audio.stop()
            engine.cancel()
            self.engine = nil
            fail(error.localizedDescription)
            return
        }

        phase = .listening
        status = engine.isOnDevice ? "Listening — \(engine.displayName)" : "Listening — \(engine.displayName) (server)"
        Log.write("listening — engine=\(engine.displayName) on-device=\(engine.isOnDevice) input=\(Int(audio.inputFormat.sampleRate))Hz")
        showPanel?()
        if settings.followCaret { repositionPanel?() }
        startPolicyTimer()
    }

    private func handleRecognitionFinished() {
        retireEngine(cancelling: false)
        guard phase == .finishing else { return }
        phase = .idle
        status = buffer.isEmpty ? "" : "Ready — ⌥↩ to insert"

        if let pending = pendingCommit {
            pendingCommit = nil
            pendingCommitDeadline?.invalidate()
            performCommit(send: pending.send)
        }
    }

    /// If the recogniser never reports completion we still owe the user their commit.
    private func armPendingCommitTimeout() {
        pendingCommitDeadline?.invalidate()
        pendingCommitDeadline = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self, let pending = self.pendingCommit else { return }
            self.pendingCommit = nil
            self.retireEngine(cancelling: true)
            if self.phase == .finishing { self.phase = .idle }
            // The recogniser never delivered its final; the words on screen are still
            // owed to the user, so promote the partial rather than dropping it.
            self.buffer.flushPartial()
            self.performCommit(send: pending.send)
        }
    }

    /// Drops our reference to the engine, but hands the last one to the next
    /// main-loop turn: `onFinished` / `onError` run *inside* closures the engine owns,
    /// and freeing it there would pull the running closure out from under itself.
    private func retireEngine(cancelling: Bool) {
        guard let engine else { return }
        self.engine = nil
        DispatchQueue.main.async {
            if cancelling { engine.cancel() }
        }
    }

    // MARK: - Rotation / silence policy

    private func startPolicyTimer() {
        stopPolicyTimer()
        policyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.evaluatePolicy()
        }
    }

    private func stopPolicyTimer() {
        policyTimer?.invalidate()
        policyTimer = nil
    }

    /// `SFSpeechRecognitionTask` stops accepting audio after roughly a minute. Rather
    /// than dying mid-sentence, roll over to a fresh segment — preferably during a
    /// pause, so no words straddle the boundary.
    private func evaluatePolicy() {
        guard phase == .listening, let engine else { return }
        let duration = engine.segmentDuration
        let silence = audio.silenceDuration

        // Rotate at any natural pause, not just near the 60s cliff: rotation is what
        // moves text from the grey volatile partial into the committed buffer, and
        // committed text is what Insert and backspace can act on. (segmentDuration is
        // 0 for engines that finalise progressively, so this never fires for them.)
        if duration > 4, silence > 0.8 {
            engine.rotate()
        } else if duration > 40, silence > 0.4 {
            engine.rotate()
        } else if duration > 55 {
            engine.rotate()
        }

        if settings.stopOnSilence, silence > settings.silenceTimeout, !buffer.isEmpty {
            stopListening()
        }
    }

    // MARK: - Commit

    private func performCommit(send: Bool) {
        // Two commits in flight would interleave keystrokes in the target app.
        guard phase != .committing else { return }

        // If recognition ended without a final result, take what's on screen rather
        // than silently dropping it.
        buffer.flushPartial()

        let text = buffer.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Nothing to insert"
            // An empty ⌥↩ mid-dictation shouldn't kill the session either.
            if resumeAfterCommit {
                resumeAfterCommit = false
                startListening()
            }
            return
        }
        guard Permissions.accessibilityGranted else {
            fail("Accessibility access is required to type into other apps.")
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
            return
        }

        phase = .committing
        let targetName = targets.targetName ?? "the focused app"
        status = "Inserting into \(targetName)…"
        Log.write("commit: \(text.count) chars → \(targetName) via \(settings.injectionMode.label)")

        // Order matters: stop being the key window, then make sure the destination
        // really has focus, and only then post events.
        releaseFocus?()
        if settings.hideAfterCommit { hidePanel?() }

        targets.focusTarget { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.status = "Could not focus \(targetName) — typing anyway"
            }
            TextInjector.inject(
                text,
                mode: self.settings.injectionMode,
                newlineMode: self.settings.newlineMode,
                pressReturnAfter: send
            ) { result in
                switch result {
                case .success:
                    self.status = "Inserted into \(targetName)"
                    if self.settings.clearAfterCommit { self.buffer.clear() }
                    self.phase = .idle
                    if self.resumeAfterCommit {
                        self.resumeAfterCommit = false
                        self.startListening()
                    }
                case .failure(let error):
                    self.resumeAfterCommit = false
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Errors

    private func fail(_ message: String) {
        resumeAfterCommit = false
        audio.stop()
        stopPolicyTimer()
        retireEngine(cancelling: true)
        level = 0
        phase = .idle
        status = ""
        errorMessage = message
        showPanel?()
        Log.write("ERROR: \(message)")
    }

    func dismissError() {
        errorMessage = nil
    }
}
