import AVFoundation
import AudioToolbox
import Foundation

/// Microphone tap. Hands raw buffers to whoever wants them and publishes a
/// smoothed 0...1 level for the waveform, plus a running "how long has it been
/// quiet" measure used for silence-aware segment rotation and auto-stop.
///
/// Device pinning: AVAudioEngine's native input route is used whenever the selected
/// microphone is already the macOS default. Only a genuinely non-default selection is
/// bound through `kAudioOutputUnitProperty_CurrentDevice`; rebinding the default route
/// can leave the engine running without delivering any PCM buffers.
final class AudioCapture {

    /// Called on the audio thread. Keep it cheap.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread, throttled to ~30 Hz.
    var onLevel: ((Float) -> Void)?
    /// Capture can start successfully yet never deliver a single buffer. Reported on
    /// the main thread without silently switching away from the selected input.
    var onFailure: ((Error) -> Void)?

    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var activeInputFormat: AVAudioFormat?
    private var startupWatchdog: DispatchWorkItem?
    private var running = false
    private var smoothedLevel: Float = 0
    private var lastLevelPublish = CFAbsoluteTimeGetCurrent()

    private let stateLock = NSLock()
    private var _lastLoudTime = CFAbsoluteTimeGetCurrent()
    private var _observedBuffer = false

    /// Seconds since the input last exceeded the speech threshold.
    var silenceDuration: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return CFAbsoluteTimeGetCurrent() - _lastLoudTime
    }

    /// RMS above this counts as speech rather than room noise.
    private let speechThreshold: Float = 0.012

    var inputFormat: AVAudioFormat {
        activeInputFormat ?? engine.inputNode.outputFormat(forBus: 0)
    }

    func start() throws {
        guard !running else { return }

        let settings = Settings.shared
        let selected = try AudioInputSourceCatalog.resolveDevice(
            sourceID: settings.inputSourceID,
            savedName: settings.inputSourceName
        )
        // A fresh engine cannot retain a CurrentDevice pin from an earlier session.
        // This matters when the user switches back to Follow macOS System Default.
        engine = AVAudioEngine()
        try begin(device: selected)
    }

    func stop() {
        guard running else { return }
        running = false
        startupWatchdog?.cancel()
        startupWatchdog = nil
        tearDownEngine()
        activeInputFormat = nil
        smoothedLevel = 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    // MARK: - Capture

    private func begin(device: AudioInputDevice) throws {
        stateLock.lock()
        _lastLoudTime = CFAbsoluteTimeGetCurrent()
        _observedBuffer = false
        stateLock.unlock()

        let input = engine.inputNode

        // Let AVAudioEngine own its normal default-device route. Explicitly setting
        // CurrentDevice to that same device is not a no-op: on some route/sample-rate
        // combinations the engine starts successfully but its tap never receives PCM.
        let needsExplicitPin = !device.isSystemDefault
        if needsExplicitPin, let unit = input.audioUnit {
            var deviceID = device.objectID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioInputSourceError.couldNotBind(device.name, status)
            }
        } else if needsExplicitPin {
            throw CaptureError.couldNotStart(device.name, "the audio engine exposes no input unit")
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDownEngine()
            throw error
        }

        activeInputFormat = format
        running = true
        armStartupWatchdog(deviceName: device.name)
        Log.write(
            "audio input: \(device.name)"
                + (needsExplicitPin ? " (explicit pin)" : " (native default route)")
                + " \(Int(format.sampleRate))Hz/\(format.channelCount)ch"
        )
    }

    private func tearDownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        engine.reset()
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let firstBuffer = !_observedBuffer
        _observedBuffer = true
        stateLock.unlock()
        if firstBuffer {
            Log.write("audio input: first PCM buffer arrived — frames=\(buffer.frameLength)")
        }
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

    // MARK: - Silent-device detection

    /// A device can accept a session and stay mute (sleeping USB interfaces do this).
    /// Surface that failure instead of quietly changing the user's selected input.
    private func armStartupWatchdog(deviceName: String) {
        startupWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.stateLock.lock()
            let heardAnything = self._observedBuffer
            self.stateLock.unlock()
            guard !heardAnything else { return }

            Log.write("audio input: no PCM buffers from \(deviceName) after 2s")
            self.stop()
            self.onFailure?(CaptureError.noAudioData(deviceName))
        }
        startupWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
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
        case couldNotStart(String, String)
        case noAudioData(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No usable audio input device was found."
            case .couldNotStart(let name, let detail):
                return "BtrVoice could not start \(name): \(detail)"
            case .noAudioData(let name):
                return "\(name) sent no audio. Check Inputs and the device connection."
            }
        }
    }
}
