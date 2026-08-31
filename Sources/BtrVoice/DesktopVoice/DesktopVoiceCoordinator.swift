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
        case thinking
        case executing
        case failed
    }

    struct Activity: Identifiable, Equatable {
        enum Kind: Equatable {
            case heard
            case answer
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

    var isListening: Bool {
        phase == .connecting || phase == .listening || phase == .thinking || phase == .executing
    }

    private let audio = AudioCapture()
    private let executor = DesktopVoiceExecutor()
    private lazy var router = DesktopVoiceCommandRouter { phrase in
        DesktopApplicationResolver.shared.resolve(phrase)
    }
    private lazy var assistant = DesktopVoiceAssistant { phrase in
        DesktopApplicationResolver.shared.resolve(phrase)
    }
    private var engine: TranscriptionEngine?
    private var queuedCommands: [String] = []
    private var commandIsExecuting = false
    private var slowPathTask: Task<Void, Never>?
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
        slowPathTask?.cancel()
        slowPathTask = nil
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
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        let wasThinking = phase == .thinking
        slowPathTask?.cancel()
        slowPathTask = nil
        queuedCommands.removeAll()
        activities.removeAll()
        partialTranscript = ""
        // The visible partial mirrors the transcriber's in-flight utterance. Clear
        // both sides so the next audio delta starts at DEF rather than restoring
        // discarded speech as ABCDEF.
        engine?.discardUtterance()
        if wasThinking {
            commandIsExecuting = false
            restoreListeningPhase()
        }
        status = isListening ? "Listening for a command" : "Ready for a command"
        Log.write("desktop-voice: cleared activity, conversation, and current utterance")
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
            guard let self, self.phase != .thinking, self.phase != .executing else { return }
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
            append(.notice, "Voice control started", detail: "Fast commands run locally; unfamiliar commands and questions use the model-backed slow path.")
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
            runSlowPath(command, fastPathReason: reason)

        case .answer(let answer):
            append(.answer, answer, detail: "Local capability registry")
            status = "Answered locally"
            finishCurrentCommand()

        case .plan(let plan):
            execute(plan, source: "Local fast path")
        }
    }

    private func runSlowPath(_ command: String, fastPathReason: String) {
        phase = .thinking
        status = "Thinking…"
        append(.notice, "Checking the slow path", detail: fastPathReason)
        let context = DesktopVoiceAssistant.Context(
            targetName: targetName,
            recentActivity: activities.suffix(12).map(Self.contextLine)
        )

        slowPathTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let decision = try await self.assistant.respond(to: command, context: context)
                guard !Task.isCancelled else { return }
                self.slowPathTask = nil
                switch decision {
                case .answer(let answer):
                    self.append(.answer, answer, detail: "Model slow path")
                    self.status = "Answered"
                    self.finishCurrentCommand()
                case .plan(let plan):
                    self.execute(plan, source: "Model slow path")
                case .unsupported(let reason):
                    self.append(.notice, "I can't do that yet", detail: reason)
                    self.status = reason
                    self.finishCurrentCommand()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.slowPathTask = nil
                self.append(.failure, "Slow path unavailable", detail: error.localizedDescription)
                self.status = error.localizedDescription
                self.finishCurrentCommand()
            }
        }
    }

    private func execute(_ plan: DesktopVoicePlan, source: String) {
        phase = .executing
        status = plan.summary
        append(.plan, plan.summary, detail: source)
        let started = CFAbsoluteTimeGetCurrent()
        executor.execute(plan, preferredTarget: lastExternalApplication) { [weak self] result in
            guard let self else { return }
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
            self.finishCurrentCommand()
        }
    }

    private func finishCurrentCommand() {
        commandIsExecuting = false
        restoreListeningPhase()
        processNextCommandIfNeeded()
    }

    private func receivePartial(_ transcript: String) {
        partialTranscript = transcript
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil

        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let fastPath = isFastPathCommand(command)
        let delay = fastPath ? 0.55 : 1.15

        // Familiar commands stay sub-second. Questions and novel commands wait a
        // little longer for natural speech, then enter the interactive slow path.
        autoSubmitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            let stillVisible = self.partialTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard stillVisible == command else { return }
            self.submitCurrentPartial(fastPathOnly: fastPath)
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
        switch router.route(command) {
        case .plan, .answer: return true
        case .unsupported: return false
        }
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

    private static func contextLine(_ activity: Activity) -> String {
        let kind: String
        switch activity.kind {
        case .heard: kind = "user"
        case .answer: kind = "assistant"
        case .plan: kind = "plan"
        case .success: kind = "result"
        case .notice: kind = "notice"
        case .failure: kind = "failure"
        }
        let detail = activity.detail.map { " — \($0)" } ?? ""
        return "\(kind): \(activity.title)\(detail)"
    }

    private func fail(_ message: String) {
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        slowPathTask?.cancel()
        slowPathTask = nil
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
