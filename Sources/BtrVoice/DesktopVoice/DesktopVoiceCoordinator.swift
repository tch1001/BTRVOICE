import AppKit
import Foundation

/// Owns the first desktop-voice state machine: microphone capture, streaming
/// transcription, local intent routing, native execution, and compact activity.
/// It remains alive when the overlay is hidden so later world-state observers and
/// slower LLM planners can be attached without changing the user-facing surface.
final class DesktopVoiceCoordinator: ObservableObject {
    static let shared = DesktopVoiceCoordinator()

    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case executing
        case failed
    }

    struct Activity: Identifiable, Equatable {
        enum Kind: Equatable {
            case heard
            case plan
            case success
            case notice
            case failure
        }

        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var partialTranscript = ""
    @Published private(set) var status = "Ready for a command"
    @Published private(set) var targetName: String?
    @Published private(set) var activities: [Activity] = []

    var isListening: Bool { phase == .connecting || phase == .listening || phase == .executing }

    private let audio = AudioCapture()
    private let executor = DesktopVoiceExecutor()
    private lazy var router = DesktopVoiceCommandRouter { phrase in
        DesktopApplicationResolver.shared.resolve(phrase)
    }
    private var engine: TranscriptionEngine?
    private var queuedCommands: [String] = []
    private var commandIsExecuting = false
    /// GPT Live Transcribe prioritizes low-latency deltas and can leave a short
    /// command visible without a segment-final event. Once a complete fast-path
    /// command has been stable for a brief pause, promote it ourselves.
    private var autoSubmitTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != self.selfPID else { return }
            self.rememberTarget(application)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func setTarget(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != selfPID,
              !application.isTerminated else { return }
        rememberTarget(application)
    }

    func start(target: NSRunningApplication?) {
        setTarget(target)
        guard engine == nil else {
            status = phase == .executing ? "Running a command…" : "Listening for a command"
            return
        }
        guard OpenAIKeyStore.isSet else {
            phase = .failed
            status = "Set the OpenAI API key in the Jarvis menu to enable voice commands."
            append(.failure, "Voice transcription is unavailable", detail: "The existing BtrVoice OpenAI key is shared with this feature.")
            return
        }

        phase = .connecting
        status = "Connecting to live transcription…"
        Permissions.requestMicrophone { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.fail("Microphone access is required for voice control.")
                Permissions.openSettings(.microphone)
                return
            }
            self.beginListening()
        }
    }

    func stop() {
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        audio.stop()
        engine?.cancel()
        engine = nil
        queuedCommands.removeAll()
        commandIsExecuting = false
        level = 0
        partialTranscript = ""
        phase = .idle
        status = "Voice control paused"
        Log.write("desktop-voice: stopped")
    }

    func toggle(target: NSRunningApplication?) {
        isListening ? stop() : start(target: target)
    }

    func shutdown() {
        stop()
    }

    /// Text entry follows the exact same path as speech and makes the command
    /// compiler testable without opening the microphone.
    func submit(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if Self.isStopCommand(trimmed) {
            append(.notice, "Stopped listening", detail: nil)
            stop()
            return
        }
        queuedCommands.append(trimmed)
        processNextCommandIfNeeded()
    }

    /// Forces the visible gray speech tail through the same router as a final
    /// transcript. Retiring that in-flight utterance first prevents a later server
    /// completion from running the command a second time.
    func submitPartialNow() {
        submitCurrentPartial(fastPathOnly: false)
    }

    func clearActivity() {
        activities.removeAll()
        partialTranscript = ""
        status = isListening ? "Listening for a command" : "Ready for a command"
    }

    private func beginListening() {
        guard engine == nil else { return }
        let engine = OpenAITranscribeEngine(
            model: "gpt-live-transcribe",
            displayName: "GPT Live Transcribe"
        )
        self.engine = engine

        engine.onPartial = { [weak self] transcript in
            self?.receivePartial(transcript)
        }
        engine.onSegmentFinal = { [weak self] transcript in
            guard let self else { return }
            self.autoSubmitTimer?.invalidate()
            self.autoSubmitTimer = nil
            self.partialTranscript = ""
            self.submit(transcript)
        }
        engine.onFinished = { [weak self] in
            guard let self else { return }
            self.engine = nil
            self.audio.stop()
            self.level = 0
            if !self.commandIsExecuting {
                self.phase = .idle
                self.status = "Voice control paused"
            }
        }
        engine.onError = { [weak self] error in
            self?.fail(error.localizedDescription)
        }
        engine.onStatus = { [weak self] message in
            guard let self, self.phase != .executing else { return }
            self.status = message
        }

        audio.onBuffer = { [weak engine] buffer in
            engine?.append(buffer)
        }
        audio.onLevel = { [weak self] value in
            self?.level = value
        }
        audio.onFailure = { [weak self] error in
            self?.fail(error.localizedDescription)
        }

        do {
            try engine.start()
            try audio.start()
            phase = .listening
            status = "Listening for a command"
            append(.notice, "Voice control started", detail: "Fast commands run locally; unfamiliar commands remain visible for future routing.")
            Log.write("desktop-voice: listening with shared OpenAI key")
        } catch {
            engine.cancel()
            self.engine = nil
            audio.stop()
            fail(error.localizedDescription)
        }
    }

    private func processNextCommandIfNeeded() {
        guard !commandIsExecuting, !queuedCommands.isEmpty else { return }
        commandIsExecuting = true
        let command = queuedCommands.removeFirst()
        append(.heard, command, detail: nil)

        switch router.route(command) {
        case .unsupported(let reason):
            append(.notice, "Not in the fast path yet", detail: reason)
            status = reason
            commandIsExecuting = false
            restoreListeningPhase()
            processNextCommandIfNeeded()

        case .plan(let plan):
            phase = .executing
            status = plan.summary
            append(.plan, plan.summary, detail: "Local fast path")
            let started = CFAbsoluteTimeGetCurrent()
            executor.execute(plan, preferredTarget: lastExternalApplication) { [weak self] result in
                guard let self else { return }
                self.commandIsExecuting = false
                switch result {
                case .success(let outcome):
                    if let target = outcome.target { self.rememberTarget(target) }
                    let milliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                    self.append(.success, outcome.message, detail: "Dispatched in \(milliseconds) ms")
                    self.status = outcome.message
                case .failure(let error):
                    self.append(.failure, "Command failed", detail: error.localizedDescription)
                    self.status = error.localizedDescription
                    if case DesktopVoiceExecutionError.accessibilityRequired = error {
                        Permissions.requestAccessibility()
                    }
                }
                self.restoreListeningPhase()
                self.processNextCommandIfNeeded()
            }
        }
    }

    private func receivePartial(_ transcript: String) {
        partialTranscript = transcript
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil

        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, isFastPathCommand(command) else { return }

        // Long enough to distinguish successive streaming deltas, short enough
        // that a familiar command visibly reacts within roughly one second.
        autoSubmitTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            let stillVisible = self.partialTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard stillVisible == command else { return }
            self.submitCurrentPartial(fastPathOnly: true)
        }
    }

    private func submitCurrentPartial(fastPathOnly: Bool) {
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        let command = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard !fastPathOnly || isFastPathCommand(command) else { return }

        partialTranscript = ""
        engine?.discardUtterance()
        submit(command)
    }

    private func isFastPathCommand(_ command: String) -> Bool {
        if Self.isStopCommand(command) { return true }
        if case .plan = router.route(command) { return true }
        return false
    }

    private func restoreListeningPhase() {
        phase = engine == nil ? .idle : .listening
        if engine != nil, queuedCommands.isEmpty, status.isEmpty {
            status = "Listening for a command"
        }
    }

    private func rememberTarget(_ application: NSRunningApplication) {
        lastExternalApplication = application
        targetName = application.localizedName
    }

    private func append(_ kind: Activity.Kind, _ title: String, detail: String?) {
        activities.append(Activity(kind: kind, title: title, detail: detail))
        if activities.count > 40 {
            activities.removeFirst(activities.count - 40)
        }
    }

    private func fail(_ message: String) {
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        audio.stop()
        engine?.cancel()
        engine = nil
        level = 0
        partialTranscript = ""
        phase = .failed
        status = message
        append(.failure, "Voice control stopped", detail: message)
        Log.write("desktop-voice: ERROR — \(message)")
    }

    private static func isStopCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["stop", "stop listening", "stop voice control", "cancel voice control"].contains(normalized)
    }
}
