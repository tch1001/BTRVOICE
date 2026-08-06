import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer` backend with segment stitching.
///
/// Everything public here is main-thread only; Speech callbacks are hopped onto
/// main before touching state.
final class AppleSpeechEngine: TranscriptionEngine {

    var onPartial: ((String) -> Void)?
    var onSegmentFinal: ((String) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    var displayName: String { "SFSpeechRecognizer" }
    var isOnDevice: Bool { usesOnDeviceRecognition }

    private let recognizer: SFSpeechRecognizer?
    private let onDeviceOnly: Bool
    private let addsPunctuation: Bool

    private var current: Segment?
    /// The request `append(_:)` should feed, guarded because that call arrives on the
    /// audio thread while segments are swapped on main.
    private var feedTarget: SFSpeechAudioBufferRecognitionRequest?
    private let feedLock = NSLock()
    /// Segment that has been closed but whose final result has not landed yet.
    private var draining: Segment?
    /// Partials produced by `current` while `draining` is still outstanding, held
    /// back so text can never appear out of order.
    private var heldPartial: String?
    private var finishing = false

    /// One recognition pass.
    private final class Segment {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var lastPartial = ""
        var startedAt = CFAbsoluteTimeGetCurrent()
        var resolved = false
        var closed = false
    }

    init(locale: Locale, onDeviceOnly: Bool, addsPunctuation: Bool) {
        let candidate = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        self.recognizer = candidate
        // Fall back to server recognition rather than failing outright when the
        // on-device asset for this locale isn't installed.
        self.onDeviceOnly = onDeviceOnly && (candidate?.supportsOnDeviceRecognition ?? false)
        self.addsPunctuation = addsPunctuation
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    var usesOnDeviceRecognition: Bool { onDeviceOnly }

    var segmentDuration: TimeInterval {
        guard let current else { return 0 }
        return CFAbsoluteTimeGetCurrent() - current.startedAt
    }

    func start() throws {
        guard let recognizer else { throw EngineError.unsupportedLocale }
        guard recognizer.isAvailable else { throw EngineError.recognizerUnavailable }
        finishing = false
        beginSegment()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Audio thread. Take a strong reference under the lock so a concurrent
        // rotation can't drop the request out from under us mid-append.
        feedLock.lock()
        let request = feedTarget
        feedLock.unlock()
        request?.append(buffer)
    }

    private func setFeedTarget(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        feedLock.lock()
        feedTarget = request
        feedLock.unlock()
    }

    func rotate() {
        guard !finishing, let closing = current, !closing.closed else { return }
        // If a previous rotation is still draining, let it finish first.
        guard draining == nil else { return }
        close(closing)
        draining = closing
        beginSegment()
        scheduleDrainTimeout(for: closing)
    }

    func discardUtterance() {
        guard !finishing else { return }
        heldPartial = nil
        // Mark both live segments resolved *before* cancelling, so their callbacks
        // (including the final result already in flight) are ignored.
        for segment in [current, draining].compactMap({ $0 }) {
            segment.resolved = true
            segment.closed = true
            segment.task?.cancel()
        }
        current = nil
        draining = nil
        setFeedTarget(nil)
        onPartial?("")
        beginSegment()
    }

    func finish() {
        finishing = true
        if let current, !current.closed {
            close(current)
            if draining == nil {
                draining = current
                scheduleDrainTimeout(for: current)
            } else {
                // Rare: rotation and finish collided. Resolve immediately, in order.
                resolve(current)
            }
        }
        self.current = nil
        if draining == nil { flushHeldAndComplete() }
    }

    func cancel() {
        finishing = false
        heldPartial = nil
        setFeedTarget(nil)
        for segment in [current, draining].compactMap({ $0 }) {
            segment.resolved = true
            segment.closed = true
            segment.task?.cancel()
        }
        current = nil
        draining = nil
    }

    // MARK: - Segments

    private func beginSegment() {
        guard let recognizer else { return }

        let segment = Segment()
        segment.request.shouldReportPartialResults = true
        segment.request.requiresOnDeviceRecognition = onDeviceOnly
        segment.request.taskHint = .dictation
        segment.request.addsPunctuation = addsPunctuation

        current = segment
        setFeedTarget(segment.request)
        segment.task = recognizer.recognitionTask(with: segment.request) { [weak self, weak segment] result, error in
            DispatchQueue.main.async {
                guard let self, let segment else { return }
                self.handle(result: result, error: error, for: segment)
            }
        }
    }

    private func close(_ segment: Segment) {
        guard !segment.closed else { return }
        segment.closed = true
        // Stop feeding before ending audio, or late buffers land on a closed request.
        if feedTargetMatches(segment.request) { setFeedTarget(nil) }
        segment.request.endAudio()
    }

    private func feedTargetMatches(_ request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        feedLock.lock()
        defer { feedLock.unlock() }
        return feedTarget === request
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, for segment: Segment) {
        if let result {
            let text = result.bestTranscription.formattedString
            segment.lastPartial = text
            if result.isFinal {
                resolve(segment, text: text)
                return
            }
            if segment === current {
                emitPartial(text)
            }
            return
        }

        guard let error else { return }
        // A closed segment erroring out after endAudio is normal; take what we have.
        if segment.closed {
            resolve(segment)
            return
        }
        if Self.isBenign(error) {
            // "No speech detected" and friends: restart a clean segment so the
            // session keeps listening instead of dying silently.
            resolve(segment)
            if !finishing, segment === current {
                current = nil
                beginSegment()
            }
            return
        }
        resolve(segment)
        onError?(error)
    }

    private func resolve(_ segment: Segment, text: String? = nil) {
        guard !segment.resolved else { return }
        segment.resolved = true
        segment.task = nil

        let value = (text ?? segment.lastPartial).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { onSegmentFinal?(value) }

        if segment === draining {
            draining = nil
            if let held = heldPartial {
                heldPartial = nil
                onPartial?(held)
            }
            if finishing, current == nil { onFinished?() }
        } else if segment === current, finishing {
            flushHeldAndComplete()
        }
    }

    private func emitPartial(_ text: String) {
        if draining != nil {
            heldPartial = text
        } else {
            onPartial?(text)
        }
    }

    private func flushHeldAndComplete() {
        heldPartial = nil
        onPartial?("")
        onFinished?()
    }

    /// A drained segment that never reports a final result would wedge the pipeline,
    /// so fall back to its last partial after a short grace period.
    private func scheduleDrainTimeout(for segment: Segment) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak segment] in
            guard let self, let segment, !segment.resolved else { return }
            self.resolve(segment)
        }
    }

    private static func isBenign(_ error: Error) -> Bool {
        let ns = error as NSError
        // kAFAssistantErrorDomain 1110 = no speech detected, 203 = retry,
        // 1101/216 = local recognition service churn. None are fatal.
        if ns.domain == "kAFAssistantErrorDomain" {
            return [203, 216, 1101, 1107, 1110].contains(ns.code)
        }
        return ns.domain == NSCocoaErrorDomain && ns.code == 4097
    }

    enum EngineError: LocalizedError {
        case unsupportedLocale
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale:
                return "Speech recognition isn't available for this language."
            case .recognizerUnavailable:
                return "The speech recogniser is temporarily unavailable."
            }
        }
    }
}
