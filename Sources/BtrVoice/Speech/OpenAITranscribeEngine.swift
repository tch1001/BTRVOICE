import AVFoundation
import Foundation

/// Streaming transcription over OpenAI's Realtime API (gpt-realtime-whisper or
/// gpt-live-transcribe). Microphone audio is converted to 24kHz PCM16 mono and
/// streamed up a WebSocket; server-side VAD segments the speech, and transcript
/// deltas/completions come back as partials/finals.
final class OpenAITranscribeEngine: NSObject, TranscriptionEngine {

    var onPartial: ((String) -> Void)?
    var onSegmentFinal: ((String) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    let displayName: String
    var isOnDevice: Bool { false }
    var isAvailable: Bool { OpenAIKeyStore.isSet }
    /// Progressive finalisation — rotation policy never needs to fire.
    var segmentDuration: TimeInterval { 0 }

    private let model: String
    private var task: URLSessionWebSocketTask?
    /// Identifies the live socket so callbacks from a Trash-retired connection
    /// cannot append its old utterance to the fresh session.
    private var connectionGeneration = 0
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!

    private let lock = NSLock()
    private var ready = false
    private var finishing = false
    private var cancelled = false
    private var preRoll: [Data] = []
    private var currentPartial = ""
    /// Events arriving before this instant are from a discarded utterance.
    private var suppressUntil = Date.distantPast
    private var finishTimer: Timer?
    private var errorReported = false
    private var vadRetried = false

    enum EngineError: LocalizedError {
        case noKey
        case api(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "No OpenAI API key set (Jarvis menu → Set OpenAI API Key)."
            case .api(let message): return "OpenAI: \(message)"
            }
        }
    }

    init(model: String, displayName: String) {
        self.model = model
        self.displayName = displayName
    }

    func start() throws {
        try connect()
    }

    private func connect() throws {
        guard let key = OpenAIKeyStore.read() else { throw EngineError.noKey }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        lock.lock()
        connectionGeneration += 1
        let generation = connectionGeneration
        ready = false
        suppressUntil = .distantPast
        task = socket
        lock.unlock()
        socket.resume()
        receive(on: socket, generation: generation)
        Log.write("openai-stt: connecting (\(model))")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = convert(buffer) else { return }
        lock.lock()
        let isReady = ready
        if !isReady { preRoll.append(data); if preRoll.count > 200 { preRoll.removeFirst() } }
        lock.unlock()
        guard isReady else { return }
        sendAudio(data)
    }

    func rotate() { /* server VAD segments for us */ }

    func discardUtterance() {
        lock.lock()
        let shouldReconnect = task != nil && !finishing && !cancelled
        let retiredTask = shouldReconnect ? task : nil
        suppressUntil = Date()
        currentPartial = ""
        if shouldReconnect {
            connectionGeneration += 1
            task = nil
            ready = false
            preRoll.removeAll()
            errorReported = false
            vadRetried = false
        }
        lock.unlock()

        // A new transcription connection also creates a new server-side audio
        // stream. This is the only unambiguous boundary between the discarded
        // utterance and words spoken after Trash; microphone capture keeps running
        // and pre-roll buffers audio until the replacement session is ready.
        if let retiredTask {
            retiredTask.cancel(with: .normalClosure, reason: nil)
            do {
                try connect()
            } catch {
                reportError(error)
            }
        }
        emit {
            self.onPartial?("")
        }
    }

    func finish() {
        lock.lock()
        finishing = true
        lock.unlock()
        send(["type": "input_audio_buffer.commit"])
        // The final transcription for committed audio arrives asynchronously;
        // give it a moment, then declare the session flushed either way.
        DispatchQueue.main.async { [weak self] in
            self?.finishTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
                self?.completeFinish()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        connectionGeneration += 1
        let retiredTask = task
        task = nil
        lock.unlock()
        retiredTask?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - WebSocket

    private func receive(on socket: URLSessionWebSocketTask, generation: Int) {
        socket.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let isCurrentConnection = generation == self.connectionGeneration
            self.lock.unlock()
            guard isCurrentConnection else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                let benign = self.cancelled || self.finishing
                self.lock.unlock()
                if !benign { self.reportError(EngineError.api(error.localizedDescription)) }
                return
            case .success(.string(let text)):
                self.handle(text, connectionGeneration: generation)
            case .success:
                break
            }
            self.receive(on: socket, generation: generation)
        }
    }

    private func handle(_ text: String, connectionGeneration: Int) {
        lock.lock()
        let isCurrentConnection = connectionGeneration == self.connectionGeneration
        lock.unlock()
        guard isCurrentConnection else { return }
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "session.created", "transcription_session.created":
            // Live-transcribe models stream continuously and reject VAD config;
            // whisper-style models need server VAD to segment turns. Start with
            // VAD and drop it on rejection, so new models work either way.
            sendSessionConfig(
                includeVAD: model.contains("whisper"),
                connectionGeneration: connectionGeneration
            )

        case "session.updated", "transcription_session.updated":
            lock.lock()
            guard connectionGeneration == self.connectionGeneration else {
                lock.unlock()
                return
            }
            ready = true
            let backlog = preRoll
            preRoll.removeAll()
            lock.unlock()
            Log.write("openai-stt: session ready, flushing \(backlog.count) pre-roll chunks")
            for chunk in backlog {
                sendAudio(chunk, expectedConnection: connectionGeneration)
            }

        case "conversation.item.input_audio_transcription.delta":
            guard fresh(event, connectionGeneration: connectionGeneration) else { return }
            let delta = (event["delta"] as? String) ?? ""
            lock.lock()
            currentPartial += delta
            let partial = currentPartial
            lock.unlock()
            emit { self.onPartial?(partial) }

        case "conversation.item.input_audio_transcription.completed":
            guard fresh(event, connectionGeneration: connectionGeneration) else { return }
            lock.lock()
            currentPartial = ""
            lock.unlock()
            let transcript = ((event["transcript"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { emit { self.onSegmentFinal?(transcript) } }

        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? text
            // The session config was too opinionated for this model — retry once
            // with the rejected knob removed instead of killing the session.
            if message.localizedCaseInsensitiveContains("turn detection"), !vadRetried {
                vadRetried = true
                Log.write("openai-stt: model rejected VAD config, retrying without — \(message)")
                sendSessionConfig(
                    includeVAD: false,
                    connectionGeneration: connectionGeneration
                )
                return
            }
            // A commit on an empty buffer while finishing isn't worth surfacing.
            lock.lock(); let benign = finishing || cancelled; lock.unlock()
            if benign {
                Log.write("openai-stt: (finishing) \(message)")
            } else {
                reportError(EngineError.api(message))
            }

        default:
            break
        }
    }

    /// Discards results that belong to an utterance the user already threw away.
    private func fresh(
        _ event: [String: Any],
        connectionGeneration: Int
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connectionGeneration == self.connectionGeneration
            && (Date() > suppressUntil.addingTimeInterval(1.0) || suppressUntil == .distantPast)
    }

    private func completeFinish() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        connectionGeneration += 1
        let retiredTask = task
        task = nil
        // No completion event arrived for the tail — the words are on screen as
        // a partial, so the user is entitled to them as a final.
        let leftover = currentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        currentPartial = ""
        lock.unlock()
        retiredTask?.cancel(with: .normalClosure, reason: nil)
        if !alreadyCancelled {
            emit {
                if !leftover.isEmpty { self.onSegmentFinal?(leftover) }
                self.onFinished?()
            }
        }
    }

    /// UI-facing callbacks must land on the main thread: WebSocket receive
    /// callbacks arrive on a URLSession queue, and letting them reach AppKit
    /// (panel ordering, published state) crashes with EXC_BREAKPOINT.
    private func emit(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    private func sendSessionConfig(
        includeVAD: Bool,
        connectionGeneration: Int
    ) {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "transcription": ["model": model],
        ]
        if includeVAD { input["turn_detection"] = ["type": "server_vad"] }
        send(["type": "session.update", "session": [
            "type": "transcription",
            "audio": ["input": input],
        ]], expectedConnection: connectionGeneration)
    }

    private func send(
        _ event: [String: Any],
        expectedConnection: Int? = nil
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let socket = expectedConnection == nil || expectedConnection == connectionGeneration
            ? task
            : nil
        let generation = connectionGeneration
        lock.unlock()
        socket?.send(.string(text)) { [weak self] error in
            if let error, let self {
                self.lock.lock()
                let benign = self.cancelled || self.finishing
                    || generation != self.connectionGeneration
                self.lock.unlock()
                if !benign { self.reportError(EngineError.api(error.localizedDescription)) }
            }
        }
    }

    private func sendAudio(_ data: Data, expectedConnection: Int? = nil) {
        send(
            ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()],
            expectedConnection: expectedConnection
        )
    }

    private func reportError(_ error: Error) {
        lock.lock()
        let already = errorReported
        errorReported = true
        lock.unlock()
        guard !already else { return }
        Log.write("openai-stt: ERROR — \(error.localizedDescription)")
        emit { self.onError?(error) }
    }

    // MARK: - Audio conversion

    /// Mic input (typically 48kHz float) → 24kHz mono PCM16 bytes.
    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
