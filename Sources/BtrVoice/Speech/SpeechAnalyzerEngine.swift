import AVFoundation
import Foundation
import Speech

/// The macOS 26+ backend, built on `SpeechAnalyzer`/`SpeechTranscriber`.
///
/// Two structural wins over the legacy engine: no ~60-second task limit (so no
/// segment rotation, `rotate()` is a no-op), and finalised results arrive
/// *progressively* — the transcriber finalises each stretch of speech as it gains
/// confidence, while newer audio stays volatile. Volatile text maps to `onPartial`,
/// finalised stretches to `onSegmentFinal`, which is exactly the protocol's shape.
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: TranscriptionEngine {

    var onPartial: ((String) -> Void)?
    var onSegmentFinal: ((String) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    var displayName: String { "SpeechAnalyzer" }
    /// This API only runs the local model; audio never leaves the machine.
    var isOnDevice: Bool { true }
    var isAvailable: Bool { SpeechTranscriber.isAvailable }
    /// Static twin of `isAvailable`, for pickers that run before any engine exists.
    static var runtimeSupported: Bool { SpeechTranscriber.isAvailable }
    /// No task lifetime limit, so the controller's rotation policy never triggers.
    var segmentDuration: TimeInterval { 0 }
    func rotate() {}

    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    /// Everything the audio thread touches, guarded by one lock.
    private let feedLock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Audio captured while the analyzer is still starting up (or downloading its
    /// model on first use). Replayed once ready so the first words aren't lost.
    /// Cap ≈ 25s of 2048-frame buffers at 48kHz.
    private var preRoll: [AVAudioPCMBuffer] = []
    private let preRollCap = 600
    private var ready = false

    private var finishing = false
    private var cancelled = false
    /// Bumped by `discardUtterance()`; results from an older generation are dropped.
    private var generation = 0

    init(locale: Locale) {
        self.locale = locale
    }

    func start() throws {
        guard SpeechTranscriber.isAvailable else { throw EngineError.notSupported }
        finishing = false
        cancelled = false

        setupTask = Task { [weak self] in
            await self?.setUp()
        }
    }

    private func setUp() async {
        do {
            var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            if resolved == nil {
                resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
            }
            guard let supported = resolved else { throw EngineError.unsupportedLocale }

            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            self.transcriber = transcriber

            // First use on a fresh OS install: the model may need downloading.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                emitStatus("Downloading the speech model…")
                Log.write("speechanalyzer: downloading model assets for \(supported.identifier)")
                try await request.downloadAndInstall()
                Log.write("speechanalyzer: model assets installed")
            }

            guard !cancelled else { return }

            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

            // Consume results before starting, so nothing is dropped.
            let gen = generation
            resultsTask = Task { [weak self] in
                await self?.pumpResults(from: transcriber, generation: gen)
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            try await analyzer.start(inputSequence: stream)

            openGate(continuation: continuation, format: format)
        } catch {
            guard !cancelled else { return }
            Log.write("speechanalyzer: setup failed — \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else { return }
                self.onError?(error)
            }
        }
    }

    /// Synchronous on purpose: `NSLock` may not be held across suspension points, so
    /// the async setup path hands off to this once its awaits are done.
    private func openGate(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat?) {
        feedLock.lock()
        input = continuation
        analyzerFormat = format
        ready = true
        let backlog = preRoll
        preRoll.removeAll()
        feedLock.unlock()

        // Replay what the microphone captured while the analyzer was starting up.
        for buffer in backlog { push(buffer) }

        // If finish() won the race, close the input we just opened.
        if finishing { closeInput() }
    }

    private func pumpResults(from transcriber: SpeechTranscriber, generation gen: Int) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                let isFinal = result.isFinal
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cancelled, self.generation == gen else { return }
                    if isFinal {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { self.onSegmentFinal?(trimmed) }
                        self.onPartial?("")
                    } else {
                        self.onPartial?(text)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled, self.generation == gen else { return }
                self.onFinished?()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled, self.generation == gen else { return }
                if self.finishing {
                    // Losing the stream while closing out still means "done".
                    self.onFinished?()
                } else {
                    self.onError?(error)
                }
            }
        }
    }

    /// Restart the analyzer session. There is no API to drop just the volatile tail,
    /// but the model is already installed, so a restart is near-instant — and it
    /// guarantees no already-heard words can come back as a later final result.
    func discardUtterance() {
        guard !finishing, !cancelled else { return }
        generation += 1
        resultsTask?.cancel()
        closeInput()
        let old = analyzer
        analyzer = nil
        transcriber = nil
        Task { await old?.cancelAndFinishNow() }
        setupTask = Task { [weak self] in
            await self?.setUp()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onPartial?("")
        }
    }

    // MARK: - Audio

    func append(_ buffer: AVAudioPCMBuffer) {
        feedLock.lock()
        if !ready {
            if !finishing, !cancelled, preRoll.count < preRollCap { preRoll.append(buffer) }
            feedLock.unlock()
            return
        }
        feedLock.unlock()
        push(buffer)
    }

    /// Converts to the analyzer's preferred format and yields. Audio thread or setup
    /// task; the converter is only ever touched here, serialised by `feedLock`.
    private func push(_ buffer: AVAudioPCMBuffer) {
        feedLock.lock()
        defer { feedLock.unlock() }
        guard let input, let format = analyzerFormat else { return }

        if buffer.format == format {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData || (status == .inputRanDry && out.frameLength > 0) else { return }
        input.yield(AnalyzerInput(buffer: out))
    }

    // MARK: - Teardown

    func finish() {
        finishing = true
        closeInput()
        let analyzer = analyzer
        Task {
            // Finalises everything still volatile; the results stream then ends,
            // which is what fires onFinished.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        // Setup may still be mid-download with nothing to flush.
        if analyzer == nil {
            setupTask?.cancel()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled, self.finishing else { return }
                self.onFinished?()
            }
        }
    }

    func cancel() {
        cancelled = true
        closeInput()
        setupTask?.cancel()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func closeInput() {
        feedLock.lock()
        let continuation = input
        input = nil
        ready = false
        preRoll.removeAll()
        feedLock.unlock()
        continuation?.finish()
    }

    private func emitStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.cancelled else { return }
            self.onStatus?(message)
        }
    }

    enum EngineError: LocalizedError {
        case notSupported
        case unsupportedLocale

        var errorDescription: String? {
            switch self {
            case .notSupported:
                return "SpeechAnalyzer isn't available on this Mac."
            case .unsupportedLocale:
                return "SpeechAnalyzer doesn't support this language yet — switch the engine to SFSpeechRecognizer in Settings."
            }
        }
    }
}
