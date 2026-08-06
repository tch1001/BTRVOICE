import AVFoundation
import Foundation

/// Microphone tap. Hands raw buffers to whoever wants them and publishes a
/// smoothed 0...1 level for the waveform, plus a running "how long has it been
/// quiet" measure used for silence-aware segment rotation and auto-stop.
final class AudioCapture {

    /// Called on the audio thread. Keep it cheap.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread, throttled to ~30 Hz.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var running = false
    private var smoothedLevel: Float = 0
    private var lastLevelPublish = CFAbsoluteTimeGetCurrent()

    private let stateLock = NSLock()
    private var _lastLoudTime = CFAbsoluteTimeGetCurrent()

    /// Seconds since the input last exceeded the speech threshold.
    var silenceDuration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CFAbsoluteTimeGetCurrent() - _lastLoudTime
    }

    /// RMS above this counts as speech rather than room noise.
    private let speechThreshold: Float = 0.012

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start() throws {
        guard !running else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        stateLock.lock()
        _lastLoudTime = CFAbsoluteTimeGetCurrent()
        stateLock.unlock()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        smoothedLevel = 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        onBuffer?(buffer)

        let rms = Self.rms(of: buffer)
        if rms > speechThreshold {
            stateLock.lock()
            _lastLoudTime = CFAbsoluteTimeGetCurrent()
            stateLock.unlock()
        }

        // Attack fast, release slow — reads as a responsive but non-jittery meter.
        let scaled = min(1, rms * 14)
        smoothedLevel = scaled > smoothedLevel
            ? smoothedLevel + (scaled - smoothedLevel) * 0.6
            : smoothedLevel + (scaled - smoothedLevel) * 0.15

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelPublish > 1.0 / 30.0 else { return }
        lastLevelPublish = now
        let value = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(value) }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        var sum: Float = 0
        // First channel is enough for a level meter.
        let samples = channels[0]
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(frames)).squareRoot()
    }

    enum CaptureError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No usable audio input device was found."
            }
        }
    }
}
