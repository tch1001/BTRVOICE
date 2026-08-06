import AVFoundation
import Foundation

/// Backend-agnostic streaming transcriber.
///
/// A "segment" is one bounded recognition pass. Apple's `SFSpeechRecognitionTask`
/// stops accepting audio after roughly a minute, so long dictation is stitched
/// together from consecutive segments; `rotate()` closes the current one and opens
/// the next. Other backends (whisper.cpp, Parakeet) can implement this protocol
/// and ignore rotation entirely.
protocol TranscriptionEngine: AnyObject {
    /// In-flight text for the current segment. Cumulative, replaces the previous partial.
    var onPartial: ((String) -> Void)? { get set }
    /// A segment closed out. Append this to the buffer.
    var onSegmentFinal: ((String) -> Void)? { get set }
    /// Everything has been flushed after `finish()`.
    var onFinished: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    /// Transient progress worth surfacing ("Downloading speech model…").
    var onStatus: ((String) -> Void)? { get set }

    var isAvailable: Bool { get }
    /// Short name for status lines and diagnostics.
    var displayName: String { get }
    var isOnDevice: Bool { get }
    /// Seconds of audio in the current segment, for rotation policy.
    var segmentDuration: TimeInterval { get }

    func start() throws
    func append(_ buffer: AVAudioPCMBuffer)
    /// Close the current segment and immediately begin a new one.
    func rotate()
    /// Throw away the in-flight utterance — its partial AND its eventual final —
    /// and keep listening fresh. Called when the user clears the buffer, so speech
    /// that was already recognised can't resurrect itself afterwards.
    func discardUtterance()
    /// Close the current segment and stop. Flushes a final result.
    func finish()
    /// Tear down without flushing.
    func cancel()
}
