import AppKit
import AVFoundation
import SwiftUI

/// "Start Jarvis": talking to the *fleet's* Jarvis — the orchestrator on this Mac's
/// jarvis node — by voice or keyboard.
///
/// Everything here is additive and self-contained on purpose. Dictation is a workflow
/// the user depends on daily; this window builds its own audio capture and its own
/// transcription engine instance and shares nothing with `DictationController` beyond
/// instantiating the same engine classes fresh. Closing the window tears all of it
/// down; dictation never notices it existed.
///
/// The conversation shown here is the same one `jarvis talk` and `jarvis ask` see —
/// one thread per node, however many surfaces look at it. That is why replies can
/// reference things asked from the terminal an hour ago: same brain, different mouth.
@MainActor
final class JarvisSurfaceModel: ObservableObject {

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        var text: String
    }

    enum MicState: Equatable {
        case idle
        case starting
        case listening
        case sending
    }

    @Published var turns: [Turn] = []
    @Published var micState: MicState = .idle
    @Published var partial = ""
    @Published var progress = ""
    @Published var connectionProblem = ""
    @Published var speakReplies = UserDefaults.standard.bool(forKey: "jarvisSpeakReplies")

    private let bus = JarvisBusClient()
    private var capture: AudioCapture?
    private var engine: TranscriptionEngine?
    /// Finalised segments of the utterance in progress, stitched at send time.
    private var segments: [String] = []
    private let voice = AVSpeechSynthesizer()

    // MARK: - Lifecycle

    func appear() {
        guard !bus.isConnected else { return }
        do {
            try bus.connect()
            connectionProblem = ""
            bus.onProgress = { [weak self] note in self?.progress = note }
        } catch {
            connectionProblem = error.localizedDescription
        }
    }

    func teardown() {
        stopMic(discard: true)
        voice.stopSpeaking(at: .immediate)
        bus.disconnect()
    }

    func toggleSpeakReplies() {
        speakReplies.toggle()
        UserDefaults.standard.set(speakReplies, forKey: "jarvisSpeakReplies")
        if !speakReplies { voice.stopSpeaking(at: .immediate) }
    }

    // MARK: - Voice

    /// One press starts listening; the next stops and sends what was heard.
    func toggleMic() {
        switch micState {
        case .idle: startMic()
        case .listening: finishUtterance()
        case .starting, .sending: break
        }
    }

    func discardUtterance() {
        stopMic(discard: true)
    }

    private func startMic() {
        guard micState == .idle else { return }
        micState = .starting
        partial = ""
        segments = []

        // The plain transcribers only: the GPT Editor's rewrite-the-buffer semantics
        // belong to dictation, and a question for Jarvis is not a document to polish.
        let engine = Self.makeTranscriber()
        self.engine = engine

        engine.onPartial = { [weak self] text in
            DispatchQueue.main.async { self?.partial = text }
        }
        engine.onSegmentFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { self.segments.append(trimmed) }
                self.partial = ""
            }
        }
        engine.onFinished = { [weak self] in
            DispatchQueue.main.async { self?.sendCollected() }
        }
        engine.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopMic(discard: true)
                self.turns.append(Turn(isUser: false, text: "⚠️ mic: \(error.localizedDescription)"))
            }
        }
        engine.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.progress = status }
        }

        do {
            try engine.start()
            let capture = AudioCapture()
            self.capture = capture
            capture.onBuffer = { [weak engine] buffer in engine?.append(buffer) }
            try capture.start()
            micState = .listening
        } catch {
            stopMic(discard: true)
            turns.append(Turn(isUser: false, text: "⚠️ mic: \(error.localizedDescription)"))
        }
    }

    /// Stop capturing and let the engine flush; `onFinished` sends what it heard.
    private func finishUtterance() {
        guard micState == .listening else { return }
        micState = .sending
        capture?.stop()
        capture = nil
        engine?.finish()
    }

    private func stopMic(discard: Bool) {
        capture?.stop()
        capture = nil
        if discard { engine?.cancel() }
        engine = nil
        partial = ""
        segments = []
        if micState != .sending || discard { micState = .idle }
    }

    private func sendCollected() {
        let heard = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        engine = nil
        segments = []
        micState = .idle
        guard !heard.isEmpty else { return }
        send(heard)
    }

    private static func makeTranscriber() -> TranscriptionEngine {
        let settings = Settings.shared
        let locale = Locale(identifier: settings.localeIdentifier)
        if #available(macOS 26.0, *), SpeechAnalyzerEngine.runtimeSupported {
            return SpeechAnalyzerEngine(locale: locale)
        }
        return AppleSpeechEngine(
            locale: locale,
            onDeviceOnly: settings.onDeviceOnly,
            addsPunctuation: settings.autoPunctuation
        )
    }

    // MARK: - The turn

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if !bus.isConnected { appear() }
        guard connectionProblem.isEmpty else { return }

        turns.append(Turn(isUser: true, text: question))
        progress = "thinking…"

        // `origin: voice` is one of the orchestrator's recognised human origins — this
        // is the person speaking, through a different mouth than the terminal.
        bus.call("llm.chat", params: ["message": question, "origin": "voice", "source": "btrvoice"]) {
            [weak self] result in
            guard let self else { return }
            self.progress = ""
            switch result {
            case .success(let payload):
                let answer = payload["answer"] as? String ?? "(no answer)"
                self.turns.append(Turn(isUser: false, text: answer))
                if self.speakReplies { self.speak(answer) }
            case .failure(let error):
                self.turns.append(Turn(isUser: false, text: "⚠️ \(error.localizedDescription)"))
            }
        }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        voice.speak(utterance)
    }
}

// MARK: - View

struct JarvisSurfaceView: View {
    @ObservedObject var model: JarvisSurfaceModel
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            if !model.connectionProblem.isEmpty {
                Label(model.connectionProblem, systemImage: "bolt.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.turns.isEmpty {
                            Text("This is the fleet's Jarvis — the same conversation as `jarvis talk` in a terminal. Press the mic and speak, or type below. It can see every machine on the mesh.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(model.turns) { turn in
                            HStack {
                                if turn.isUser { Spacer(minLength: 40) }
                                Text(turn.text)
                                    .font(.system(size: 12.5))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(turn.isUser ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
                                    )
                                if !turn.isUser { Spacer(minLength: 40) }
                            }
                            .id(turn.id)
                        }
                        if !model.progress.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(model.progress)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.turns) {
                    if let last = model.turns.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if model.micState == .listening || !model.partial.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.accentColor)
                    Text(model.partial.isEmpty ? "Listening…" : model.partial)
                        .font(.system(size: 12))
                        .foregroundStyle(model.partial.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.toggleMic()
                } label: {
                    Image(systemName: micSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 20)
                }
                .help(micHelp)
                .disabled(model.micState == .starting || model.micState == .sending)

                if model.micState == .listening {
                    Button("Discard") { model.discardUtterance() }
                        .help("Stop listening and throw away what was heard")
                }

                TextField("Ask Jarvis…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }

                Button("Send") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    model.toggleSpeakReplies()
                } label: {
                    Image(systemName: model.speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .help(model.speakReplies ? "Replies are spoken aloud" : "Replies are silent")
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 360)
        .onAppear { model.appear() }
    }

    private var micSymbol: String {
        switch model.micState {
        case .idle: return "mic"
        case .starting: return "mic.badge.xmark"
        case .listening: return "stop.circle.fill"
        case .sending: return "ellipsis"
        }
    }

    private var micHelp: String {
        model.micState == .listening
            ? "Stop and send what was heard"
            : "Speak to Jarvis"
    }

    private func submit() {
        model.send(input)
        input = ""
    }
}

// MARK: - Window

/// Owns the window so the menu can summon it repeatedly; the model — and with it the
/// bus connection and any live microphone — is torn down when the window closes.
@MainActor
final class JarvisSurfaceWindowController: NSObject, NSWindowDelegate {
    static let shared = JarvisSurfaceWindowController()
    private var window: NSWindow?
    private var model: JarvisSurfaceModel?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = JarvisSurfaceModel()
        self.model = model
        let hosting = NSHostingController(rootView: JarvisSurfaceView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Jarvis"
        win.setContentSize(NSSize(width: 520, height: 440))
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.teardown()
        model = nil
        window = nil
    }
}
