import AVFoundation
import AudioToolbox
import Foundation

/// Microphone tap. Hands raw buffers to whoever wants them and publishes a
/// smoothed 0...1 level for the waveform, plus a running "how long has it been
/// quiet" measure used for silence-aware segment rotation and auto-stop.
///
/// Device pinning: rather than a hand-rolled AUHAL unit (which silently delivered
/// nothing for some USB devices), the selected device is set as the *engine's* input
/// device via `kAudioOutputUnitProperty_CurrentDevice` on the input node. One capture
/// path for every device, and it's the one that is known to work. The system default
/// is never changed.
final class AudioCapture {

    /// Called on the audio thread. Keep it cheap.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread, throttled to ~30 Hz.
    var onLevel: ((Float) -> Void)?
    /// Capture can start successfully yet never deliver a single buffer, and by then
    /// the fallback chain has already been tried. Reported on the main thread.
    var onFailure: ((Error) -> Void)?
    /// The device we actually ended up on differs from the one asked for
    /// (silent-device fallback). Main thread; the controller surfaces it as status.
    var onDeviceFallback: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var activeInputFormat: AVAudioFormat?
    private var activeDeviceName = ""
    private var startupWatchdog: DispatchWorkItem?
    private var fallbackAttempted = false
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
        fallbackAttempted = false

        let selected: AudioInputDevice
        do {
            selected = try AudioInputSourceCatalog.resolveDevice(
                sourceID: settings.inputSourceID,
                savedName: settings.inputSourceName
            )
        } catch AudioInputSourceError.selectedMicrophoneUnavailable {
            let fallback = try AudioInputSourceCatalog.systemDefaultDevice()
            Log.write(
                "audio input: saved microphone \(settings.inputSourceName) is disconnected; "
                    + "using \(fallback.name) for this session"
            )
            try begin(device: fallback)
            return
        }
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

        // Pin the engine's input to the chosen device. Explicit even for the system
        // default, because the engine's unit remembers the previous session's pin.
        if let unit = input.audioUnit {
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
        } else if !device.isSystemDefault {
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
        activeDeviceName = device.name
        running = true
        armStartupWatchdog(deviceName: device.name)
        Log.write(
            "audio input: \(device.name)"
                + (device.isSystemDefault ? " (system default)" : " (pinned)")
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

    // MARK: - Silent-device fallback

    /// A device can accept a session and stay mute (sleeping USB interfaces do this).
    /// Rather than surfacing an error every session, quietly move to a device that
    /// actually produces audio; only give up when the alternatives are silent too.
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

            if !self.fallbackAttempted, let next = self.fallbackDevice(after: deviceName) {
                self.fallbackAttempted = true
                do {
                    try self.begin(device: next)
                    Log.write("audio input: fell back to \(next.name)")
                    let name = next.name
                    DispatchQueue.main.async { self.onDeviceFallback?(name) }
                    return
                } catch {
                    Log.write("audio input: fallback to \(next.name) failed — \(error.localizedDescription)")
                }
            }
            self.onFailure?(CaptureError.noAudioData(deviceName))
        }
        startupWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Best next candidate: the built-in microphone if it wasn't the one that just
    /// failed (it never sleeps), otherwise the system default, otherwise anything else.
    private func fallbackDevice(after failedName: String) -> AudioInputDevice? {
        let devices = AudioInputSourceCatalog.microphones()
        let builtIn = devices.first {
            $0.uid.localizedCaseInsensitiveContains("BuiltIn")
                || $0.name.localizedCaseInsensitiveContains("MacBook")
        }
        for candidate in [builtIn, devices.first(where: \.isSystemDefault)].compactMap({ $0 })
        where candidate.name != failedName {
            return candidate
        }
        return devices.first { $0.name != failedName }
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
                return "\(name) and the fallback microphones sent no audio. Check Inputs and your device connections."
            }
        }
    }
}
