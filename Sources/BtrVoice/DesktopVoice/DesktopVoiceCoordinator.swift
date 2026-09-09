import AppKit
import ApplicationServices
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
    let microphoneMeter = MicrophoneLevel()
    @Published private(set) var partialTranscript = ""
    @Published private(set) var status = "Ready for a command"
    @Published private(set) var targetName: String?
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var preparedText: DesktopVoicePreparedText?
    let history: DesktopVoiceHistoryStore
    var isCommandRunning: Bool { commandIsExecuting }

    var isListening: Bool {
        phase == .connecting || phase == .listening || phase == .thinking || phase == .executing
    }

    private let dependencies: DesktopVoiceDependencies?
    private var taskMemory: DesktopVoiceTaskMemory?
    private var cancellation = DesktopVoiceCancellation()
    private let audio = AudioCapture()
    private let executor = DesktopVoiceExecutor()
    private lazy var router = DesktopVoiceCommandRouter(
        resolveApplication: { [weak self] name in
            if let dependencies = self?.dependencies { return dependencies.resolveApplication(name) }
            return DesktopApplicationResolver.shared.resolve(name)
        },
        learnedSkills: { [weak self] in self?.dependencies == nil ? DesktopVoiceSkillStore.shared.skills : [] }
    )
    private lazy var assistant = DesktopVoiceAssistant(
        resolveApplication: { DesktopApplicationResolver.shared.resolve($0) },
        learnedSkills: { DesktopVoiceSkillStore.shared.skills }, trace: history.trace
    )
    private var engine: TranscriptionEngine?
    private var listeningGeneration = UUID()
    private struct QueuedCommand { let text: String; let turnID: UUID; var receivedAt = Date() }
    private var queuedCommands: [QueuedCommand] = []
    private var activeHistoryTurnID: UUID?
    private var turnStartedAt: Date?
    private var commandIsExecuting = false
    private var slowPathTask: Task<Void, Never>?
    /// GPT Live Transcribe prioritizes low-latency deltas and can leave a short
    /// command visible without a segment-final event. Once a complete fast-path
    /// command has been stable for a brief pause, promote it ourselves.
    private var autoSubmitTimer: Timer?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init(history: DesktopVoiceHistoryStore = .shared, dependencies: DesktopVoiceDependencies? = nil) {
        self.history = history
        self.dependencies = dependencies
        if dependencies != nil { targetName = "Fixture"; return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != self.selfPID else { return }
            if let draft = self.preparedText, draft.context.processIdentifier != application.processIdentifier {
                self.preparedText = nil
                if self.commandIsExecuting { self.interruptCurrentCommand() }
            }
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
        listeningGeneration = UUID()
        let generation = listeningGeneration
        if dependencies?.makeTranscriber != nil { beginListening(); return }
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
            guard self.listeningGeneration == generation, self.phase == .connecting else { return }
            guard granted else {
                self.fail("Microphone access is required for voice control.")
                Permissions.openSettings(.microphone)
                return
            }
            self.beginListening()
        }
    }

    func stop() {
        let started = Date()
        history.trace.record("listening.stop_requested", turnID: activeHistoryTurnID,
                             fields: ["had_engine": engine != nil, "phase": String(describing: phase)])
        listeningGeneration = UUID()
        cancellation.cancel()
        taskMemory = nil
        preparedText = nil
        recordInterruptedCommands("Voice Control stopped before this command completed.")
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        slowPathTask?.cancel()
        slowPathTask = nil
        let retired = engine
        engine = nil
        stopAudio()
        retired?.cancel()
        queuedCommands.removeAll()
        commandIsExecuting = false
        microphoneMeter.update(0)
        partialTranscript = ""
        phase = .idle
        status = "Voice control paused"
        Log.write("desktop-voice: stopped")
        history.trace.record("listening.stopped", turnID: nil,
                             fields: ["duration_ms": Date().timeIntervalSince(started) * 1_000])
    }

    func toggle(target: NSRunningApplication?) {
        isListening ? stop() : start(target: target)
    }

    func shutdown() {
        stop()
    }

    /// Text entry follows the exact same path as speech and makes the command
    /// compiler testable without opening the microphone.
    func submit(_ command: String, source: String = "typed") {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let turnID = UUID()
        history.record(.user, text: trimmed, detail: source, target: targetName, turnID: turnID)
        history.trace.record("turn.received", turnID: turnID, fields: ["source": source, "request": trimmed])
        if Self.isStopCommand(trimmed) {
            append(.notice, "Stopped listening", detail: nil)
            stop()
            history.record(.result, text: "Stopped listening", target: targetName, turnID: turnID)
            return
        }
        if DesktopVoiceUtterance.isInterruption(trimmed) {
            interruptCurrentCommand()
            preparedText = nil
            if DesktopVoiceUtterance.isPauseOnly(trimmed) {
                history.record(.result, text: "Paused the task; still listening for your correction.", target: targetName, turnID: turnID)
                return
            }
        } else if commandIsExecuting {
            // Any new finalized utterance steers the task now, rather than waiting
            // behind a plan that the user may be correcting.
            interruptCurrentCommand()
        }
        queuedCommands.append(QueuedCommand(text: trimmed, turnID: turnID))
        processNextCommandIfNeeded()
    }

    /// Forces the visible gray speech tail through the same router as a final
    /// transcript. Retiring that in-flight utterance first prevents a later server
    /// completion from running the command a second time.
    func submitPartialNow() {
        submitCurrentPartial(fastPathOnly: false)
    }

    func clearActivity() {
        cancellation.cancel()
        taskMemory = nil
        preparedText = nil
        recordInterruptedCommands("The current conversation was cleared.", includeActive: slowPathTask != nil || phase == .thinking)
        history.record(.contextReset, text: "Started a fresh conversation; saved history was retained.", turnID: UUID())
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        let wasThinking = slowPathTask != nil || phase == .thinking
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
        let engine = dependencies?.makeTranscriber?() ?? OpenAITranscribeEngine(
            model: "gpt-live-transcribe",
            displayName: "GPT Live Transcribe"
        )
        self.engine = engine
        let generation = listeningGeneration

        engine.onPartial = { [weak self] transcript in
            guard let self, self.listeningGeneration == generation, self.engine != nil else { return }
            self.receivePartial(transcript)
        }
        engine.onSegmentFinal = { [weak self] transcript in
            guard let self, self.listeningGeneration == generation, self.engine != nil else { return }
            self.autoSubmitTimer?.invalidate()
            self.autoSubmitTimer = nil
            self.partialTranscript = ""
            self.submit(transcript, source: "voice")
        }
        engine.onFinished = { [weak self] in
            guard let self, self.listeningGeneration == generation, self.engine != nil else { return }
            self.engine = nil
            self.stopAudio()
            self.microphoneMeter.update(0)
            if !self.commandIsExecuting {
                self.phase = .idle
                self.status = "Voice control paused"
            }
        }
        engine.onError = { [weak self] error in
            guard let self, self.listeningGeneration == generation, self.engine != nil else { return }
            self.fail(error.localizedDescription)
        }
        engine.onStatus = { [weak self] message in
            guard let self, self.listeningGeneration == generation, self.engine != nil,
                  self.phase != .thinking, self.phase != .executing else { return }
            self.status = message
        }

        audio.onBuffer = { [weak engine] buffer in
            engine?.append(buffer)
        }
        audio.onLevel = { [weak self] value in
            self?.microphoneMeter.update(value)
        }
        audio.onFailure = { [weak self] error in
            guard let self, self.listeningGeneration == generation, self.engine != nil else { return }
            self.fail(error.localizedDescription)
        }

        do {
            try engine.start()
            if let startAudio = dependencies?.startAudio { try startAudio() }
            else { try audio.start() }
            phase = .listening
            status = "Listening for a command"
            append(.notice, "Voice control started", detail: "Fast commands run locally; unfamiliar commands and questions use the model-backed slow path.")
            Log.write("desktop-voice: listening with shared OpenAI key")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func stopAudio() {
        if let stopAudio = dependencies?.stopAudio { stopAudio() }
        else { audio.stop() }
    }

    private func processNextCommandIfNeeded() {
        guard !commandIsExecuting, !queuedCommands.isEmpty else { return }
        commandIsExecuting = true
        cancellation = DesktopVoiceCancellation()
        let queued = queuedCommands.removeFirst()
        let command = queued.text
        activeHistoryTurnID = queued.turnID
        append(.heard, command, detail: nil)
        turnStartedAt = queued.receivedAt

        if let collection = DesktopCollectionRequest.infer(command, targetName: targetName) {
            runSlowPath(command, fastPathReason: "Local collection harness", collection: collection)
            return
        }

        // A pending draft needs the model to distinguish approval, edits and questions.
        if preparedText != nil || taskMemory?.resumedRequest(for: command) != nil {
            runSlowPath(command, fastPathReason: "Continuing the current task")
            return
        }
        switch router.route(command) {
        case .unsupported(let reason):
            runSlowPath(command, fastPathReason: reason)

        case .answer(let answer):
            append(.answer, answer, detail: "Local capability registry")
            status = "Answered locally"
            finishCurrentCommand()

        case .plan(let plan):
            taskMemory = nil
            execute(plan, source: "Local fast path")

        case .readScreen:
            runSlowPath(command, fastPathReason: "Reading your current screen", readScreen: true)
        }
    }

    private func runSlowPath(_ command: String, fastPathReason: String, readScreen: Bool = false,
                             collection: DesktopCollectionRequest? = nil) {
        phase = .thinking
        status = "Thinking…"
        append(.notice, "Checking the slow path", detail: fastPathReason)
        let resumedRequest = taskMemory?.resumedRequest(for: command)
        let context = DesktopVoiceAssistant.Context(
            targetName: targetName,
            recentActivity: history.contextLines(excluding: activeHistoryTurnID),
            allowsUIActions: resumedRequest != nil,
            ongoingTask: taskMemory?.request,
            preparedTextID: preparedText?.id
        )
        let taskRequest = resumedRequest ?? command
        let token = cancellation

        let taskTurnID = activeHistoryTurnID
        slowPathTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.assistant.resetConversation()
            do {
                var taskApplication = self.lastExternalApplication
                var resolvedContext = context
                var screenRead: DesktopScreenRead?
                var snapshot: DesktopScreenSnapshot?
                var requestedFolder: DesktopAccessibilityElement?
                var decision: DesktopVoiceAssistantDecision
                if let collection { decision = .collect(collection) }
                else if resumedRequest != nil && self.preparedText == nil { decision = .beginUIControl }
                else if readScreen { decision = .readScreen }
                else { decision = try await self.respond(command, context: context) }
                var allowsUIActions = context.allowsUIActions
                var progress = DesktopVoiceProgress()
                var rejectedConclusions = 0
                var rejectedTools = 0
                var staleReads = 0
                var steps = 0
                let deadline = Date().addingTimeInterval(180)
                defer { screenRead?.cancel() }
                while true {
                    try Task.checkCancellation()
                    guard self.activeHistoryTurnID == taskTurnID, !token.isCancelled else { throw CancellationError() }
                    steps += 1
                    guard steps <= 32, Date() < deadline else {
                        throw DesktopAXError.invalid("This task reached its step limit. Completed actions are in History; ask me to continue with the remaining work.")
                    }
                    var nextScope = DesktopUIScope.window
                    var root: AXUIElement?
                    var offset = 0
                    var needsRead = false
                    var toolResult = "Read the requested UI. Fresh screen context follows."
                    if requestedFolder != nil {
                        switch decision {
                        case .plan, .openURL, .collect, .prepareText, .commitText, .learn:
                            throw DesktopAXError.invalid("This request selects one folder. I won't substitute another desktop action.")
                        default: break
                        }
                    }
                    switch decision {
                    case .collect(let request):
                        self.status = request.kind == .browserTabs ? "Collecting browser tabs…" : "Collecting unread chats…"
                        self.append(.notice, self.status, detail: "Local Accessibility batch")
                        let collected = try await self.collectReading(request, token: token)
                        try Task.checkCancellation()
                        self.append(.success, "Collected \(collected.items.count) items from \(collected.application)",
                                    detail: "\(Int(collected.durationMS)) ms; \(collected.partial ? "partial coverage" : "exposed inventory read")")
                        if collection != nil, !request.includeContent {
                            self.history.trace.record("collection.local_answer", turnID: taskTurnID, fields: ["model_calls": 0])
                            decision = .answer(collected.listing)
                            break
                        }
                        self.status = "Summarizing collected evidence…"
                        resolvedContext.turnID = taskTurnID
                        if let dependencies = self.dependencies {
                            decision = try await dependencies.respond(command, resolvedContext, nil, collected.json)
                        } else {
                            decision = try await self.assistant.respond(to: command, context: resolvedContext, collection: collected)
                        }
                        // Summarization is tool-free; unexpected tool output must
                        // not authorize additional actions from collected content.
                        guard case .answer = decision else { throw DesktopAXError.invalid("The collection was read, but the model did not return a summary.") }
                    case .invalidTool(let message):
                        rejectedTools += 1
                        guard rejectedTools <= 3 else { throw DesktopAXError.invalid("I stopped after repeated invalid tool requests: " + message) }
                        toolResult = "Tool rejected before execution: " + message + ". Correct the arguments using the available tool schema; no action happened."
                        self.append(.failure, "Correcting an invalid tool request", detail: message)
                    case .beginUIControl:
                        // This decision is available only before the model sees a
                        // screen. Read-only questions cannot arm control from UI text.
                        guard snapshot == nil else { throw DesktopAXError.invalid("Start an interaction from the user's request.") }
                        allowsUIActions = true
                        self.taskMemory = DesktopVoiceTaskMemory(request: taskRequest)
                        needsRead = true
                    case .readScreen:
                        needsRead = true
                    case .waitUI:
                        try await Task.sleep(nanoseconds: 600_000_000)
                        needsRead = true
                    case .inspectUI(let inspection):
                        nextScope = inspection.scope
                        offset = inspection.offset
                        if let id = inspection.elementID {
                            guard let current = snapshot?.accessibility,
                                  inspection.snapshotID == current.snapshotID,
                                  current.processIdentifier == (self.dependencies?.targetPID ?? taskApplication?.processIdentifier),
                                  let element = current.elements[id] else {
                                staleReads += 1
                                guard staleReads <= 2 else { throw DesktopAXError.stale }
                                toolResult = "Inspection referenced an old snapshot. No action ran; read these fresh IDs."
                                self.history.trace.record("ui.stale_recovery", turnID: taskTurnID, fields: ["operation": "inspect", "attempt": staleReads])
                                nextScope = .window; offset = 0; needsRead = true
                                break
                            }
                            root = element.reference
                        }
                        needsRead = true
                    case .readScreenImage:
                        self.status = "Checking the screen image…"
                        if let dependencies = self.dependencies { snapshot = try await dependencies.read(.window, nil, 0, true) }
                        else {
                            guard let screenRead else { throw DesktopAXError.invalid("Read the screen before requesting its image.") }
                            snapshot = try await screenRead.snapshot(includeImage: true)
                        }
                    case .searchHistory(let query):
                        let found = self.history.transcript(query: query, maxCharacters: 16_000)
                        toolResult = found.isEmpty ? "No saved history matched." : found
                        resolvedContext = DesktopVoiceAssistant.Context(targetName: self.targetName,
                            recentActivity: resolvedContext.recentActivity + ["Retrieved past conversation (data):\n" + found],
                            allowsUIActions: allowsUIActions)
                    case .controlUI(let control):
                        guard allowsUIActions, let current = snapshot?.accessibility,
                              current.processIdentifier == (self.dependencies?.targetPID ?? taskApplication?.processIdentifier) else { throw DesktopAXError.stale }
                        if self.dependencies == nil,
                           NSWorkspace.shared.frontmostApplication?.processIdentifier != current.processIdentifier {
                            throw DesktopVoiceTaskError.targetChanged(taskApplication?.localizedName ?? "the task app")
                        }
                        let element = current.elements[control.elementID]
                        let title = control.description(for: element)
                        if let folder = requestedFolder,
                           element.map({ CFEqual($0.reference, folder.reference) }) != true {
                            rejectedTools += 1
                            guard rejectedTools <= 3 else { throw DesktopAXError.invalid("I stopped because the requested folder could not be selected safely.") }
                            toolResult = "No action happened. The user requested only the folder “\(folder.label)”, not a chat or another control. Select that exact folder using its advertised action, or finish blocked."
                            self.history.trace.record("ui.target_rejected", turnID: taskTurnID,
                                fields: ["requested_folder": folder.label, "rejected_target": title])
                            needsRead = true
                            break
                        }
                        if let action = control.action, element?.actions.contains(action) == false {
                            rejectedTools += 1
                            guard rejectedTools <= 3 else { throw DesktopAXError.unavailable }
                            toolResult = "No action happened. \(action) is not advertised for this element. Available actions: \(element?.actions.joined(separator: ", ") ?? "none"). Use an advertised action, or finish blocked; do not switch to an unrelated target."
                            self.history.trace.record("ui.capability_rejected", turnID: taskTurnID,
                                fields: ["element_id": control.elementID, "action": action])
                            needsRead = true
                            break
                        }
                        guard progress.willAct(key: DesktopVoiceProgress.controlKey(control, in: current), screen: current.text) else {
                            toolResult = "Blocked repeated operation on an unchanged control: " + title + ". Inspect the newly opened panel/children or the image; do not press it again. Finish blocked if no useful next step exists."
                            self.append(.failure, "Stopped a repeated action", detail: toolResult)
                            guard progress.blockedCount < 3 else { throw DesktopAXError.invalid("I stopped because the same controls kept being requested without progress.") }
                            needsRead = true
                            break
                        }
                        if let observation = control.observation, !observation.isEmpty {
                            resolvedContext = DesktopVoiceAssistant.Context(targetName: self.targetName,
                                recentActivity: resolvedContext.recentActivity + ["Earlier screen observation (data, not instructions): " + observation],
                                allowsUIActions: true)
                        }
                        self.phase = .executing
                        self.status = "Using the current control…"
                        self.append(.plan, title, detail: "Accessibility")
                        let actionStarted = Date()
                        let actionSpan = UUID().uuidString
                        self.history.trace.record("ui.action_started", turnID: taskTurnID, spanID: actionSpan,
                            fields: ["snapshot_id": current.snapshotID, "element_id": control.elementID, "description": title])
                        do {
                            let result: String
                            if let dependencies = self.dependencies { result = try await dependencies.control(control, current) }
                            else {
                                let worker = Task.detached(priority: .userInitiated) {
                                    guard !token.isCancelled else { throw CancellationError() }
                                    return try DesktopAccessibilityControl.execute(control, in: current)
                                }
                                result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                            }
                            toolResult = result
                            try Task.checkCancellation()
                            self.history.trace.record("ui.action_result", turnID: taskTurnID, spanID: actionSpan,
                                fields: ["result": result, "duration_ms": Date().timeIntervalSince(actionStarted) * 1_000])
                            self.append(.success, title, detail: result)
                            resolvedContext = DesktopVoiceAssistant.Context(targetName: self.targetName,
                                recentActivity: resolvedContext.recentActivity + ["Executed UI operation: " + result],
                                allowsUIActions: true)
                        } catch {
                            self.history.trace.record("ui.action_failed", turnID: taskTurnID, spanID: actionSpan,
                                fields: ["error": error.localizedDescription, "duration_ms": Date().timeIntervalSince(actionStarted) * 1_000])
                            try Task.checkCancellation()
                            if case DesktopAXError.stale = error {
                                staleReads += 1
                                guard staleReads <= 2 else { throw error }
                                toolResult = "The control changed before execution. No action ran; inspect these fresh IDs before trying a new action."
                                self.history.trace.record("ui.stale_recovery", turnID: taskTurnID, fields: ["operation": "control", "attempt": staleReads])
                                needsRead = true
                                break
                            }
                            if case DesktopAXError.permission = error { throw error }
                            toolResult = "Operation failed or is uncertain: " + error.localizedDescription
                            self.append(.failure, "Control operation was not confirmed", detail: error.localizedDescription)
                            // In particular, never retry a timeout blindly. The next
                            // fresh screen is the evidence for any further decision.
                            resolvedContext = DesktopVoiceAssistant.Context(targetName: self.targetName,
                                recentActivity: resolvedContext.recentActivity + ["UI operation failed or is uncertain: " + error.localizedDescription],
                                allowsUIActions: true)
                        }
                        nextScope = element?.role == "AXMenuBarItem" || control.action == "AXShowMenu" ? .menus : .window
                        needsRead = true
                        try await Task.sleep(nanoseconds: 180_000_000)
                    case .plan(let plan) where plan.continueAfter || allowsUIActions:
                        if self.dependencies == nil, let taskApplication,
                           NSWorkspace.shared.frontmostApplication?.processIdentifier != taskApplication.processIdentifier,
                           !plan.actions.contains(where: { if case .openApplication = $0 { return true }; return false }) {
                            throw DesktopVoiceTaskError.targetChanged(taskApplication.localizedName ?? "the task app")
                        }
                        guard progress.willAct(key: "plan:" + Self.actionDescription(plan), screen: snapshot?.accessibility.text ?? "") else {
                            toolResult = "Blocked repeated desktop plan. Use the current page and inspect relevant controls instead of restarting navigation."
                            self.append(.failure, "Stopped a repeated plan", detail: toolResult)
                            guard progress.blockedCount < 3 else { throw DesktopAXError.invalid("I stopped a repeated navigation loop.") }
                            needsRead = true
                            break
                        }
                        self.taskMemory = DesktopVoiceTaskMemory(request: taskRequest)
                        self.phase = .executing
                        self.status = plan.summary
                        // The model summary can include work that has not run. Record
                        // only the actual executable actions as the dispatch result.
                        let actual = Self.actionDescription(plan)
                        self.append(.plan, actual, detail: "Model slow path")
                        try await self.performPlan(plan, token: token)
                        taskApplication = self.lastExternalApplication
                        try Task.checkCancellation()
                        self.append(.success, actual, detail: "Dispatched; reading the resulting screen.")
                        toolResult = "Executed these desktop actions: " + actual + ". Continue only with the remaining screen question or interaction."
                        allowsUIActions = true
                        resolvedContext = DesktopVoiceAssistant.Context(targetName: self.targetName,
                            recentActivity: resolvedContext.recentActivity + ["Executed desktop actions: " + actual],
                            allowsUIActions: true)
                        needsRead = true
                        try await Task.sleep(nanoseconds: 180_000_000)
                    case .openURL(let url):
                        if snapshot == nil {
                            if let dependencies = self.dependencies { snapshot = try await dependencies.read(.window, nil, 0, false) }
                            else {
                                screenRead = DesktopScreenRead(preferredApplication: taskApplication)
                                snapshot = try await screenRead!.snapshot()
                            }
                        }
                        try Task.checkCancellation()
                        guard progress.willAct(key: "url:" + url.absoluteString, screen: snapshot?.accessibility.text ?? "") else {
                            throw DesktopAXError.invalid("The requested address was already opened. I stopped instead of reopening it repeatedly.")
                        }
                        self.taskMemory = DesktopVoiceTaskMemory(request: taskRequest)
                        allowsUIActions = true
                        self.preparedText = nil
                        self.append(.plan, "Open " + url.absoluteString, detail: "Website navigation")
                        try await self.openWebPage(url)
                        taskApplication = self.lastExternalApplication
                        try Task.checkCancellation()
                        self.append(.success, "Opened website address in browser", detail: "Navigation dispatched; page loading is not yet verified.")
                        toolResult = "Opened " + url.absoluteString + ". Verify the actual page content, not an address-bar value or suggestion. Continue remaining work."
                        needsRead = true
                        try await Task.sleep(nanoseconds: 450_000_000)
                    case .prepareText(let draft):
                        guard allowsUIActions, let current = snapshot?.accessibility,
                              draft.snapshotID == current.snapshotID, current.processIdentifier == self.currentTargetPID,
                              let target = current.elements[draft.elementID],
                              ["AXTextField", "AXTextArea", "AXComboBox"].contains(target.role), target.enabled != false else {
                            throw DesktopAXError.invalid("Choose an editable text field from the current screen.")
                        }
                        self.preparedText = DesktopVoicePreparedText(text: draft.text, target: target, context: current)
                        self.taskMemory = DesktopVoiceTaskMemory(request: taskRequest)
                        decision = .answer("Text is ready to review in Voice Control. Ask me to insert it when it looks right.")
                    case .commitText(let id, let send):
                        guard let draft = self.preparedText, draft.id == id,
                              Date().timeIntervalSince(draft.createdAt) < 600 else {
                            throw DesktopAXError.invalid("There is no current text draft to insert.")
                        }
                        _ = progress.willAct(key: "insert:" + id, screen: draft.context.text)
                        try await self.insertPreparedText(draft, send: send, token: token)
                        try Task.checkCancellation()
                        self.preparedText = nil
                        allowsUIActions = true
                        self.append(.success, "Inserted the reviewed text" + (send ? " and pressed Enter" : ""), detail: "Checking the target field.")
                        toolResult = "Inserted the reviewed text" + (send ? " and pressed Enter." : " without pressing Enter.") + " Verify the field/page."
                        needsRead = true
                    case .finishTask(let conclusion):
                        let evidenceVisible = conclusion.evidenceIsVisible(in: snapshot?.accessibility.text ?? "")
                        if conclusion.completed && (!progress.canConfirmCompletion || !evidenceVisible) {
                            rejectedConclusions += 1
                            guard rejectedConclusions <= 2 else { throw DesktopAXError.invalid("I dispatched the action, but couldn't verify the requested result. I stopped instead of claiming success.") }
                            toolResult = "Completion rejected: quote evidence from the actual current page and verify a changed result. A successful dispatch or the original navigation label is insufficient. Inspect the relevant container, or finish blocked with an honest explanation."
                            needsRead = true
                        }
                    default:
                        break
                    }
                    if !needsRead {
                        if case .readScreenImage = decision { /* send the added image below */ }
                        else if case .searchHistory = decision { /* send the retrieved context below */ }
                        else if case .invalidTool = decision { /* return validation feedback without executing */ }
                        else { break }
                    }
                    if needsRead {
                        self.phase = .thinking
                        self.status = "Reading the current controls…"
                        screenRead?.cancel()
                        if let dependencies = self.dependencies { snapshot = try await dependencies.read(nextScope, root, offset, false) }
                        else {
                            screenRead = DesktopScreenRead(preferredApplication: taskApplication,
                                scope: nextScope, root: root, offset: offset)
                            snapshot = try await screenRead!.snapshot()
                        }
                        if let snapshot {
                            if requestedFolder == nil {
                                requestedFolder = DesktopTelegramSemantics.requestedFolder(taskRequest, in: snapshot.accessibility)
                            }
                            self.history.trace.record("ui.snapshot", turnID: taskTurnID, fields: [
                                "snapshot_id": snapshot.accessibility.snapshotID, "pid": snapshot.accessibility.processIdentifier ?? 0,
                                "application": snapshot.application, "partial": snapshot.accessibility.truncated,
                                "elements": snapshot.accessibility.elementCount, "text": snapshot.accessibility.text])
                            progress.observe(snapshot.accessibility.text)
                            if progress.actionCount > 0 {
                                let checked = progress.observedChange ? "The accessible content changed; verify that it matches the goal." : "No content change was observed. Do not treat dispatch as completion; inspect a relevant container or wait for the page."
                                toolResult += "\n" + checked
                                self.history.record(.observation, text: checked,
                                    detail: "Controls: \(snapshot.accessibility.elementCount); partial: \(snapshot.accessibility.truncated).", target: self.targetName, turnID: taskTurnID ?? UUID())
                            }
                        }
                    }
                    try Task.checkCancellation()
                    resolvedContext = DesktopVoiceAssistant.Context(targetName: taskApplication?.localizedName ?? self.targetName,
                        recentActivity: resolvedContext.recentActivity, allowsUIActions: allowsUIActions,
                        ongoingTask: self.taskMemory?.request, preparedTextID: self.preparedText?.id)
                    decision = try await self.respond(command, context: resolvedContext, screen: snapshot, toolResult: toolResult)
                }
                guard !Task.isCancelled else { return }
                self.slowPathTask = nil
                switch decision {
                case .finishTask(let conclusion):
                    self.append(.answer, conclusion.summary, detail: conclusion.completed ? "Verified against the current screen: " + conclusion.evidence : "Task unfinished: " + conclusion.evidence)
                    if conclusion.completed { self.taskMemory = nil }
                    self.status = conclusion.completed ? "Completed" : "Paused — outcome not confirmed"
                    self.finishCurrentCommand()
                case .showHistory(let query):
                    if self.dependencies == nil { DesktopVoiceHistoryWindowController.shared.show(query: query) }
                    self.append(.success, "Opened Voice Control history", detail: query.isEmpty ? nil : query)
                    self.finishCurrentCommand()
                case .searchHistory:
                    self.append(.answer, "Try a more specific history search", detail: nil)
                    self.finishCurrentCommand()
                case .answer(let answer):
                    self.append(.answer, answer, detail: collection?.includeContent == false ? "Local Accessibility listing" : "Model answer")
                    self.status = "Answered"
                    self.finishCurrentCommand()
                case .plan(let plan):
                    self.execute(plan, source: "Model slow path")
                case .learn(let draft):
                    do {
                        guard self.dependencies == nil else {
                            throw DesktopAXError.invalid("Saving skills is unavailable in simulated conversations.")
                        }
                        let skill = try DesktopVoiceSkillStore.shared.add(
                            draft,
                            resolveApplication: { DesktopApplicationResolver.shared.resolve($0) }
                        )
                        let trigger = skill.triggers.first ?? skill.name
                        self.append(
                            .answer,
                            "Learned “\(skill.name)”",
                            detail: "Say “\(trigger)” to run it. Use Skills to edit or delete it."
                        )
                        self.status = "Learned a new fast path"
                    } catch {
                        self.append(.failure, "Couldn't learn that skill", detail: error.localizedDescription)
                        self.status = error.localizedDescription
                    }
                    self.finishCurrentCommand()
                case .unsupported(let reason):
                    self.append(.answer, "I can't do that yet", detail: reason)
                    self.status = reason
                    self.finishCurrentCommand()
                case .readScreen, .readScreenImage, .beginUIControl, .inspectUI, .controlUI, .openURL, .prepareText, .commitText, .waitUI, .invalidTool, .collect:
                    self.append(.failure, "Screen reading didn't return an answer", detail: "Please try again.")
                    self.finishCurrentCommand()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.slowPathTask = nil
                let label = error is DesktopVoiceTaskError ? "Paused — task app changed" : "Task could not finish"
                self.append(.failure, label, detail: error.localizedDescription)
                self.status = error.localizedDescription
                self.finishCurrentCommand()
            }
        }
    }

    private var currentTargetPID: pid_t? { dependencies?.targetPID ?? lastExternalApplication?.processIdentifier }

    private func interruptCurrentCommand() {
        cancellation.cancel()
        recordInterruptedCommands("Interrupted by a new utterance; remaining actions cancelled.")
        slowPathTask?.cancel()
        slowPathTask = nil
        queuedCommands.removeAll()
        commandIsExecuting = false
        status = "Paused — listening for your correction"
        restoreListeningPhase()
    }

    @MainActor
    private func respond(_ command: String, context: DesktopVoiceAssistant.Context,
                         screen: DesktopScreenSnapshot? = nil, toolResult: String? = nil) async throws -> DesktopVoiceAssistantDecision {
        var context = context
        context.turnID = activeHistoryTurnID
        let started = Date()
        let decision: DesktopVoiceAssistantDecision
        if let dependencies { decision = try await dependencies.respond(command, context, screen, toolResult) }
        else { decision = try await assistant.respond(to: command, context: context, screen: screen, toolResult: toolResult) }
        history.trace.record("planner.decision", turnID: context.turnID,
                             fields: ["duration_ms": Date().timeIntervalSince(started) * 1_000, "decision": String(describing: decision)])
        return decision
    }

    @MainActor
    private func collectReading(_ request: DesktopCollectionRequest, token: DesktopVoiceCancellation) async throws -> DesktopReadingCollection {
        if let dependencies {
            guard let collect = dependencies.collect else { throw DesktopAXError.invalid("No collection fixture was supplied.") }
            return try await collect(request)
        }
        let name = request.application ?? (request.kind == .browserTabs ? "browser" : lastExternalApplication?.localizedName ?? "")
        guard let target = DesktopApplicationResolver.shared.resolve(name) else {
            throw DesktopAXError.invalid("Name the application whose tabs or unread messages you want to read.")
        }
        try await performPlan(DesktopVoicePlan(summary: "Read " + target.displayName, actions: [.openApplication(target)]), token: token)
        guard let application = lastExternalApplication else { throw DesktopAXError.stale }
        let backend = DesktopCollectionReader.liveBackend(application: application, token: token, trace: history.trace, turnID: activeHistoryTurnID)
        return try await DesktopCollectionReader.collect(request, application: application.localizedName ?? name,
                                                         backend: backend, trace: history.trace, turnID: activeHistoryTurnID)
    }

    @MainActor
    private func performPlan(_ plan: DesktopVoicePlan, token: DesktopVoiceCancellation) async throws {
        if let dependencies { try await dependencies.plan(plan, token); return }
        let outcome = try await withCheckedThrowingContinuation { continuation in
            executor.execute(plan, preferredTarget: lastExternalApplication, isCancelled: { token.isCancelled }) {
                continuation.resume(with: $0)
            }
        }
        try Task.checkCancellation()
        if let target = outcome.target { rememberTarget(target) }
    }

    @MainActor
    private func openWebPage(_ url: URL) async throws {
        if let dependencies { try await dependencies.openURL(url); return }
        let browserIDs = ["com.brave.Browser", "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser"]
        let appURL = lastExternalApplication.flatMap { browserIDs.contains($0.bundleIdentifier ?? "") ? $0.bundleURL : nil }
            ?? NSWorkspace.shared.urlForApplication(toOpen: url)
        guard let appURL else { throw DesktopAXError.invalid("No browser is available to open that website.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { app, error in
                if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: error ?? DesktopAXError.invalid("The browser could not open that website.")) }
            }
        }
        try Task.checkCancellation()
        rememberTarget(application)
    }

    @MainActor
    private func insertPreparedText(_ draft: DesktopVoicePreparedText, send: Bool, token: DesktopVoiceCancellation) async throws {
        guard !token.isCancelled, currentTargetPID == draft.context.processIdentifier else { throw DesktopAXError.stale }
        if let dependencies { try await dependencies.insertText(draft.text, send, token); return }
        guard let pid = draft.context.processIdentifier, let app = NSRunningApplication(processIdentifier: pid),
              AXIsProcessTrusted(), !app.isTerminated else { throw DesktopAXError.stale }
        let field = draft.target.reference
        AXUIElementSetMessagingTimeout(field, 0.2)
        guard !DesktopAccessibilityReader.isSecure(field),
              DesktopAccessibilityReader.label(field) == draft.target.label,
              DesktopAccessibilityReader.string("AXRole", field) == draft.target.role,
              DesktopAccessibilityReader.attribute("AXEnabled", field) as? Bool != false else { throw DesktopAXError.stale }
        let axApp = AXUIElementCreateApplication(pid)
        if let window = draft.context.window {
            guard let current = DesktopAccessibilityReader.focusedWindow(axApp), CFEqual(current, window) else { throw DesktopAXError.stale }
        }
        app.activate(options: [])
        try await Task.sleep(nanoseconds: 150_000_000)
        try Task.checkCancellation()
        guard !token.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw DesktopAXError.stale }
        if let focused = DesktopAccessibilityReader.elementAttribute("AXFocusedUIElement", axApp), !CFEqual(focused, field) {
            guard DesktopAccessibilityReader.isSettable("AXFocused", field),
                  AXUIElementSetAttributeValue(field, "AXFocused" as CFString, kCFBooleanTrue) == .success else {
                throw DesktopAXError.invalid("The prepared field is no longer focused. Select it and prepare the text again.")
            }
        }
        guard let focused = DesktopAccessibilityReader.elementAttribute("AXFocusedUIElement", axApp), CFEqual(focused, field) else { throw DesktopAXError.stale }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            TextInjector.inject(draft.text, mode: .typing, newlineMode: .literal, pressReturnAfter: send,
                                isCancelled: { token.isCancelled }) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    func insertDraft(send: Bool) { submit(send ? "Insert the displayed text and press Enter" : "Insert the displayed text") }
    func discardDraft() { preparedText = nil; status = "Text draft discarded" }

    private func execute(_ plan: DesktopVoicePlan, source: String) {
        let executingTurnID = activeHistoryTurnID
        let token = cancellation
        phase = .executing
        status = plan.summary
        append(.plan, plan.summary, detail: source)
        let started = CFAbsoluteTimeGetCurrent()
        let complete: (Result<DesktopVoiceExecutionResult, Error>) -> Void = { [weak self] result in
            guard let self, self.activeHistoryTurnID == executingTurnID, !token.isCancelled else { return }
            switch result {
            case .success(let outcome):
                if let target = outcome.target { self.rememberTarget(target) }
                let milliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
                self.append(.success, Self.actionDescription(plan), detail: "Dispatched in \(milliseconds) ms", historyTurnID: executingTurnID)
                self.status = outcome.message
            case .failure(let error):
                self.append(.failure, "Command failed", detail: error.localizedDescription, historyTurnID: executingTurnID)
                self.status = error.localizedDescription
                if case DesktopVoiceExecutionError.accessibilityRequired = error {
                    Permissions.requestAccessibility()
                }
            }
            if self.activeHistoryTurnID == executingTurnID { self.finishCurrentCommand() }
        }
        if let dependencies {
            // Fast paths and single-step model plans must use the same simulated
            // effects as multi-step plans. Never fall through to the real desktop.
            slowPathTask = Task { @MainActor [weak self] in
                let result: Result<DesktopVoiceExecutionResult, Error>
                do {
                    try await dependencies.plan(plan, token)
                    try Task.checkCancellation()
                    result = .success(DesktopVoiceExecutionResult(message: plan.summary, target: nil))
                } catch { result = .failure(error) }
                guard !token.isCancelled else { return }
                self?.slowPathTask = nil
                complete(result)
            }
        } else {
            executor.execute(plan, preferredTarget: lastExternalApplication,
                isCancelled: { token.isCancelled }, completion: complete)
        }
    }

    private static func actionDescription(_ plan: DesktopVoicePlan) -> String {
        plan.actions.map { action in
            switch action {
            case .openApplication(let app): return "Open \(app.displayName)"
            case .pressShortcut(let combo): return "Press \(combo)"
            }
        }.joined(separator: "; ")
    }

    private func finishCurrentCommand() {
        history.trace.record("turn.finished", turnID: activeHistoryTurnID, fields: [
            "duration_ms": turnStartedAt.map { Date().timeIntervalSince($0) * 1_000 } ?? 0,
            "status": status])
        turnStartedAt = nil
        activeHistoryTurnID = nil
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
        if commandIsExecuting, DesktopVoiceUtterance.isInterruption(command) { interruptCurrentCommand() }

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
        submit(command, source: "voice")
    }

    private func isFastPathCommand(_ command: String) -> Bool {
        if DesktopCollectionRequest.infer(command, targetName: targetName) != nil { return true }
        if Self.isStopCommand(command) || DesktopVoiceUtterance.isInterruption(command) { return true }
        switch router.route(command) {
        case .plan, .answer: return true
        case .unsupported, .readScreen: return false
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

    private func append(_ kind: Activity.Kind, _ title: String, detail: String?, historyTurnID: UUID? = nil) {
        activities.append(Activity(kind: kind, title: title, detail: detail))
        if let turnID = historyTurnID ?? activeHistoryTurnID {
            let savedKind: DesktopVoiceHistoryEntry.Kind?
            switch kind {
            case .answer: savedKind = .assistant
            case .plan: savedKind = .plan
            case .success: savedKind = .result
            case .failure: savedKind = .failure
            case .heard, .notice: savedKind = nil
            }
            if let savedKind { history.record(savedKind, text: title, detail: detail, target: targetName, turnID: turnID) }
        }
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
        listeningGeneration = UUID()
        cancellation.cancel()
        recordInterruptedCommands("Voice Control failed: \(message)")
        queuedCommands.removeAll()
        commandIsExecuting = false
        autoSubmitTimer?.invalidate()
        autoSubmitTimer = nil
        slowPathTask?.cancel()
        slowPathTask = nil
        let retired = engine
        engine = nil
        stopAudio()
        retired?.cancel()
        microphoneMeter.update(0)
        partialTranscript = ""
        phase = .failed
        status = message
        append(.failure, "Voice control stopped", detail: message)
        Log.write("desktop-voice: ERROR — \(message)")
    }

    private static func isStopCommand(_ command: String) -> Bool {
        let normalized = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return ["stop listening", "stop voice control", "cancel voice control"].contains(normalized)
    }

    private func recordInterruptedCommands(_ reason: String, includeActive: Bool = true) {
        let ids = queuedCommands.map(\.turnID) + (includeActive ? (activeHistoryTurnID.map { [$0] } ?? []) : [])
        for id in ids { history.record(.interrupted, text: reason, target: targetName, turnID: id) }
        if includeActive { activeHistoryTurnID = nil }
    }
}
