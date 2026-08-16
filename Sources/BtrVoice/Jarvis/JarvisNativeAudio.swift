import AVFoundation
import AudioToolbox
import Foundation

/// Native full-duplex audio for Jarvis Voice.
///
/// VoiceProcessingIO performs acoustic echo cancellation before the microphone tap.
/// The tap is converted to 24 kHz PCM16 for Realtime and for the local speaker gate;
/// Realtime PCM deltas are converted back to float audio and scheduled on the same
/// engine so its speaker output remains available to the echo canceller.
final class JarvisNativeAudio {
    var onInputPCM: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var responseEngine = AVAudioEngine()
    private var responsePlayer = AVAudioPlayerNode()
    private var captureUnit: AudioUnit?
    private var captureFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "com.btr.voice.jarvis-audio")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!
    private let playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: 24_000,
        channels: 1
    )!

    private var converter: AVAudioConverter?
    private var running = false
    private var tapInstalled = false
    private var playerConnected = false
    private var responsePlayerConnected = false
    private var responseRunning = false
    private var muted = false
    private var smoothedLevel: Float = 0
    private var lastLevelAt = CFAbsoluteTimeGetCurrent()
    private var inputFrameCount = 0
    private var conversionFailureCount = 0
    private var voiceProcessingUnavailable = false
    private var captureCallbackObserved = false
    private var captureRenderErrorLogged = false

    private(set) var echoCancellationEnabled = false
    private(set) var usedSystemRouteFallback = false
    private(set) var playbackErrorDetail: String?

    init() {
        engine.attach(player)
        responseEngine.attach(responsePlayer)
    }

    func start(
        inputDeviceID: UInt32?,
        outputDeviceID: UInt32?,
        preferVoiceProcessing: Bool,
        keepOtherAudioPlaying: Bool
    ) throws {
        guard !running else { return }
        usedSystemRouteFallback = false
        playbackErrorDetail = nil
        var voiceProcessingError: Error?
        if preferVoiceProcessing && !voiceProcessingUnavailable {
            do {
                // Apple's macOS voice-processing node is documented against the
                // system-default I/O pair. Selecting devices on the VPIO unit after
                // it has made its private aggregate can corrupt that aggregate, so
                // the controller only chooses this path when the selected route is
                // already the system route.
                try startEngine(
                    voiceProcessing: true,
                    inputDeviceID: nil,
                    outputDeviceID: nil,
                    keepOtherAudioPlaying: keepOtherAudioPlaying
                )
                return
            } catch {
                voiceProcessingError = error
                voiceProcessingUnavailable = true
                Log.write(
                    "jarvis voice: VoiceProcessingIO could not start; retrying the microphone without native echo cancellation — \(Self.describe(error))"
                )
                quarantineVoiceProcessingGraph()
            }
        } else if !preferVoiceProcessing {
            Log.write(
                "jarvis voice: selected route is not the compatible macOS default pair; opening it without VoiceProcessingIO"
            )
        }

        do {
            try startOrdinaryAudio(
                inputDeviceID: inputDeviceID,
                outputDeviceID: outputDeviceID
            )
            Log.write("jarvis voice: microphone active without VoiceProcessingIO")
            return
        } catch {
            let nativeDetail = voiceProcessingError.map(Self.describe) ?? "not attempted"
            let routeDetail = Self.describe(error)
            Log.write(
                "jarvis voice: selected microphone startup failed — voice processing: \(nativeDetail); selected route: \(routeDetail)"
            )
            resetGraph(recreateEngine: true)
            throw AudioError.startFailed(routeDetail)
        }
    }

    func stop() {
        guard running else { return }
        // A healthy engine can be reused. Releasing a VoiceProcessingIO engine
        // while Core Audio still has a property notification queued is unsafe on
        // macOS 26; the failed-unit path below deliberately quarantines it.
        resetGraph(recreateEngine: false)
        smoothedLevel = 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }

    func setMuted(_ value: Bool) {
        audioQueue.async { [weak self] in self?.muted = value }
    }

    func pausePlayback() {
        let player = activePlaybackPlayer
        if player.isPlaying { player.pause() }
    }

    func resumePlayback() {
        let engine = activePlaybackEngine
        let player = activePlaybackPlayer
        guard running, engine.isRunning, !player.isPlaying else { return }
        player.play()
    }

    func clearPlayback() {
        guard running else { return }
        let player = activePlaybackPlayer
        player.stop()
        player.reset()
    }

    func schedule(pcm16 data: Data) {
        let engine = activePlaybackEngine
        let player = activePlaybackPlayer
        guard running, engine.isRunning, !data.isEmpty else { return }
        let count = data.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: playbackFormat,
                frameCapacity: AVAudioFrameCount(count)
              ), let channel = buffer.floatChannelData?[0] else { return }

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                channel[index] = Float(Int16(bitPattern: low | high)) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let level = Self.rms(buffer)
            self.publish(level: level)
            guard !self.muted else { return }
            guard let data = self.convert(buffer) else {
                self.conversionFailureCount += 1
                if self.conversionFailureCount <= 3 {
                    Log.write(
                        "jarvis voice: PCM conversion failed — input=\(Int(buffer.format.sampleRate))Hz/\(buffer.format.channelCount)ch frames=\(buffer.frameLength)"
                    )
                }
                return
            }
            self.inputFrameCount += Int(buffer.frameLength)
            if self.inputFrameCount == Int(buffer.frameLength) {
                Log.write(
                    "jarvis voice: first microphone PCM reached Realtime boundary — bytes=\(data.count) level=\(String(format: "%.4f", level))"
                )
            }
            self.onInputPCM?(data)
        }
    }

    private func startEngine(
        voiceProcessing: Bool,
        inputDeviceID: UInt32?,
        outputDeviceID: UInt32?,
        keepOtherAudioPlaying: Bool
    ) throws {
        let input = engine.inputNode

        // Enabling VoiceProcessingIO replaces the engine's I/O unit. Do it before
        // reading formats or connecting playback; both values can change as part of
        // that replacement on macOS.
        if input.isVoiceProcessingEnabled != voiceProcessing {
            try perform(stage: "configuring Apple voice processing") {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            }
        }
        echoCancellationEnabled = voiceProcessing && input.isVoiceProcessingEnabled

        if let inputDeviceID {
            try perform(stage: "opening the selected microphone") {
                try input.auAudioUnit.setDeviceID(inputDeviceID)
            }
        }

        if voiceProcessing && keepOtherAudioPlaying {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        }

        if voiceProcessing {
            if let outputDeviceID {
                try engine.outputNode.auAudioUnit.setDeviceID(outputDeviceID)
            }
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            playerConnected = true
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }

        // A nil tap format follows the I/O node's current hardware format. This is
        // important after VoiceProcessingIO has rebuilt an aggregate device.
        input.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try perform(stage: "starting microphone capture") {
            try engine.start()
        }
        running = true

        inputFrameCount = 0
        conversionFailureCount = 0
        Log.write(
            "jarvis voice: microphone active — input=\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)ch input_device=\(inputDeviceID.map(String.init) ?? "system") output_device=\(outputDeviceID.map(String.init) ?? "system") echo_cancellation=\(echoCancellationEnabled) keep_other_audio=\(keepOtherAudioPlaying)"
        )
    }

    private func resetGraph(recreateEngine: Bool = false) {
        running = false
        stopCaptureUnit()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        if playerConnected {
            engine.disconnectNodeOutput(player)
            playerConnected = false
        }
        engine.reset()
        resetResponseGraph(recreateEngine: recreateEngine)
        converter = nil
        inputFrameCount = 0
        conversionFailureCount = 0
        captureCallbackObserved = false
        captureRenderErrorLogged = false
        echoCancellationEnabled = false
        if recreateEngine {
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            engine.attach(player)
        }
    }

    /// Core Audio may deliver a VoiceProcessingIO property callback after a failed
    /// initialization. Deallocating the engine during that window crashes inside
    /// `AVAudioIOUnit::IOUnitPropertyListener`, so retain the failed graph for the
    /// process lifetime and continue on a fresh ordinary AVAudioEngine.
    private func quarantineVoiceProcessingGraph() {
        running = false
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        if playerConnected {
            engine.disconnectNodeOutput(player)
            playerConnected = false
        }
        JarvisFailedAudioGraphQuarantine.shared.retain(engine: engine, player: player)
        resetResponseGraph(recreateEngine: true)
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        converter = nil
        inputFrameCount = 0
        conversionFailureCount = 0
        captureCallbackObserved = false
        captureRenderErrorLogged = false
        echoCancellationEnabled = false
    }

    private var activePlaybackEngine: AVAudioEngine {
        echoCancellationEnabled ? engine : responseEngine
    }

    private var activePlaybackPlayer: AVAudioPlayerNode {
        echoCancellationEnabled ? player : responsePlayer
    }

    private func startResponseEngine(outputDeviceID: UInt32?) throws {
        let output = responseEngine.outputNode
        try perform(stage: "configuring speaker-only playback") {
            try configureOutputOnly(output)
        }
        if let outputDeviceID {
            try perform(stage: "opening the selected speakers") {
                try output.auAudioUnit.setDeviceID(outputDeviceID)
            }
        }
        responseEngine.connect(
            responsePlayer,
            to: responseEngine.mainMixerNode,
            format: playbackFormat
        )
        responsePlayerConnected = true
        responseEngine.prepare()
        try perform(stage: "starting response playback") {
            try responseEngine.start()
        }
        responseRunning = true
        Log.write(
            "jarvis voice: response playback active — output_device=\(outputDeviceID.map(String.init) ?? "system")"
        )
    }

    /// Ordinary app-specific capture uses AUHAL directly rather than an AVAudioEngine
    /// input tap. AVAudioEngine needs its output render loop to drive that tap, but
    /// enabling output on an input-only device fails format negotiation. Worse, a
    /// stopped/silent tap can remain registered inside AVFAudio and abort the process
    /// when a second tap is installed. Input-only AUHAL is the native Core Audio path
    /// for this topology and creates a fresh callback unit on every start.
    private func startOrdinaryAudio(
        inputDeviceID: UInt32?,
        outputDeviceID: UInt32?
    ) throws {
        let format = try startCaptureUnit(inputDeviceID: inputDeviceID)
        running = true
        do {
            try startResponseEngine(outputDeviceID: outputDeviceID)
        } catch {
            playbackErrorDetail = Self.describe(error)
            Log.write(
                "jarvis voice: response playback could not start, but microphone capture remains active — \(Self.describe(error))"
            )
        }
        inputFrameCount = 0
        conversionFailureCount = 0
        captureCallbackObserved = false
        captureRenderErrorLogged = false
        echoCancellationEnabled = false
        Log.write(
            "jarvis voice: microphone active — input=\(Int(format.sampleRate))Hz/\(format.channelCount)ch input_device=\(inputDeviceID.map(String.init) ?? "system") output_device=\(outputDeviceID.map(String.init) ?? "system") echo_cancellation=false"
        )
    }

    private func startCaptureUnit(inputDeviceID: UInt32?) throws -> AVAudioFormat {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioStageError(
                stage: "creating microphone capture",
                detail: "Core Audio did not provide an AUHAL component"
            )
        }
        var candidate: AudioUnit?
        try checked(
            AudioComponentInstanceNew(component, &candidate),
            stage: "creating microphone capture"
        )
        guard let unit = candidate else {
            throw AudioStageError(
                stage: "creating microphone capture",
                detail: "Core Audio returned no AUHAL instance"
            )
        }

        do {
            try setIOEnabled(false, unit: unit, scope: kAudioUnitScope_Output, bus: 0)
            try setIOEnabled(true, unit: unit, scope: kAudioUnitScope_Input, bus: 1)
            if var deviceID = inputDeviceID {
                try checked(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &deviceID,
                        UInt32(MemoryLayout<AudioDeviceID>.size)
                    ),
                    stage: "opening the selected microphone"
                )
            }

            // TN2091: AUHAL performs no sample-rate conversion on the input side.
            // The client format on (output scope, bus 1) defaults to 44.1 kHz, so a
            // 48 kHz microphone opens successfully but never produces a callback.
            // Read the device-side format and pin the client format to its rate.
            var deviceStream = AudioStreamBasicDescription()
            var deviceStreamSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(
                AudioUnitGetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    1,
                    &deviceStream,
                    &deviceStreamSize
                ),
                stage: "reading the microphone format"
            )
            guard deviceStream.mSampleRate > 0, deviceStream.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(
                    standardFormatWithSampleRate: deviceStream.mSampleRate,
                    channels: deviceStream.mChannelsPerFrame
                  ) else {
                throw AudioError.noInputDevice
            }
            var clientStream = format.streamDescription.pointee
            try checked(
                AudioUnitSetProperty(
                    unit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    1,
                    &clientStream,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                stage: "matching the microphone sample rate"
            )

            var callback = AURenderCallbackStruct(
                inputProc: { reference, flags, timestamp, _, frames, _ in
                    return Unmanaged<JarvisNativeAudio>
                        .fromOpaque(reference)
                        .takeUnretainedValue()
                        .renderCapture(flags: flags, timestamp: timestamp, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try checked(
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                stage: "installing the microphone callback"
            )
            try checked(AudioUnitInitialize(unit), stage: "initializing microphone capture")

            captureUnit = unit
            captureFormat = format
            let status = AudioOutputUnitStart(unit)
            if status != noErr {
                captureUnit = nil
                captureFormat = nil
                AudioUnitUninitialize(unit)
                throw AudioStageError(
                    stage: "starting microphone capture",
                    detail: "OSStatus \(status)"
                )
            }
            return format
        } catch {
            if captureUnit == unit {
                captureUnit = nil
                captureFormat = nil
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private func renderCapture(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        if !captureCallbackObserved {
            captureCallbackObserved = true
            audioQueue.async {
                Log.write("jarvis voice: first microphone callback arrived — frames=\(frames)")
            }
        }
        guard let unit = captureUnit, let format = captureFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return kAudio_ParamError
        }
        let status = AudioUnitRender(
            unit,
            flags,
            timestamp,
            1,
            frames,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            if !captureRenderErrorLogged {
                captureRenderErrorLogged = true
                audioQueue.async {
                    Log.write("jarvis voice: microphone render failed — OSStatus \(status)")
                }
            }
            return status
        }
        buffer.frameLength = frames
        consume(buffer)
        return noErr
    }

    private func stopCaptureUnit() {
        guard let unit = captureUnit else { return }
        AudioOutputUnitStop(unit)
        captureUnit = nil
        captureFormat = nil
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func resetResponseGraph(recreateEngine: Bool) {
        responseRunning = false
        responsePlayer.stop()
        responseEngine.stop()
        if responsePlayerConnected {
            responseEngine.disconnectNodeOutput(responsePlayer)
            responsePlayerConnected = false
        }
        responseEngine.reset()
        if recreateEngine {
            responseEngine = AVAudioEngine()
            responsePlayer = AVAudioPlayerNode()
            responseEngine.attach(responsePlayer)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let staged = error as? AudioStageError {
            return "\(staged.stage): \(staged.detail)"
        }
        let value = error as NSError
        return "\(value.domain) \(value.code): \(value.localizedDescription)"
    }

    private func configureOutputOnly(_ output: AVAudioOutputNode) throws {
        guard let unit = output.audioUnit else {
            throw AudioStageError(stage: "accessing speaker hardware", detail: "Core Audio did not provide an output unit")
        }
        try setIOEnabled(false, unit: unit, scope: kAudioUnitScope_Input, bus: 1)
        try setIOEnabled(true, unit: unit, scope: kAudioUnitScope_Output, bus: 0)
    }

    private func setIOEnabled(
        _ enabled: Bool,
        unit: AudioUnit,
        scope: AudioUnitScope,
        bus: AudioUnitElement
    ) throws {
        var value: UInt32 = enabled ? 1 : 0
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            scope,
            bus,
            &value,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw AudioStageError(
                stage: "setting Core Audio I/O mode",
                detail: "OSStatus \(status)"
            )
        }
    }

    private func perform(stage: String, _ work: () throws -> Void) throws {
        do {
            try work()
        } catch let error as AudioStageError {
            throw error
        } catch {
            throw AudioStageError(stage: stage, detail: Self.describe(error))
        }
    }

    private func checked(_ status: OSStatus, stage: String) throws {
        guard status == noErr else {
            throw AudioStageError(stage: stage, detail: "OSStatus \(status)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0,
              let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
    }

    private func publish(level: Float) {
        let scaled = min(1, level * 14)
        smoothedLevel = scaled > smoothedLevel
            ? smoothedLevel + (scaled - smoothedLevel) * 0.6
            : smoothedLevel + (scaled - smoothedLevel) * 0.15
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelAt >= 1.0 / 24.0 else { return }
        lastLevelAt = now
        let value = smoothedLevel
        DispatchQueue.main.async { [weak self] in self?.onLevel?(value) }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = channels[0][index]
            energy += value * value
        }
        return sqrt(energy / Float(buffer.frameLength))
    }

    enum AudioError: LocalizedError {
        case noInputDevice
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No usable microphone format was reported by macOS. Text mode is still available."
            case let .startFailed(detail):
                return "macOS found the microphone but could not start its audio stream (\(detail)). Text mode is still available."
            }
        }
    }

    private struct AudioStageError: LocalizedError {
        let stage: String
        let detail: String

        var errorDescription: String? { "\(stage): \(detail)" }
    }
}

/// Owns failed VoiceProcessingIO graphs until process exit. This intentionally small
/// quarantine avoids a macOS 26 use-after-free in AVFAudio's asynchronous listener.
private final class JarvisFailedAudioGraphQuarantine {
    static let shared = JarvisFailedAudioGraphQuarantine()

    private var graphs: [(AVAudioEngine, AVAudioPlayerNode)] = []

    func retain(engine: AVAudioEngine, player: AVAudioPlayerNode) {
        graphs.append((engine, player))
    }
}

/// Applies FluidAudio's 80 ms owner-speaker decision to Realtime PCM.
/// Rejected or missing decisions fail closed to equal-duration silence so server VAD
/// still observes the timing needed to end a preceding accepted utterance.
enum JarvisPCMFrameMask {
    static func apply(
        pcm16: Data,
        mask: [Bool],
        frameDurationMilliseconds: Int,
        sampleRate: Int = 24_000
    ) -> Data {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2),
              frameDurationMilliseconds > 0, sampleRate > 0 else { return Data() }
        let frameSamples = max(1, sampleRate * frameDurationMilliseconds / 1_000)
        let source = [UInt8](pcm16)
        var output = [UInt8](repeating: 0, count: source.count)
        let sampleCount = source.count / 2
        let fadeStep = 1 / Float(max(1, sampleRate * 12 / 1_000))
        var gain: Float = 0

        for index in 0..<sampleCount {
            let frame = index / frameSamples
            let allow = frame < mask.count && mask[frame]
            let target: Float = allow ? 1 : 0
            if gain < target { gain = min(target, gain + fadeStep) }
            if gain > target { gain = max(target, gain - fadeStep) }

            let low = UInt16(source[index * 2])
            let high = UInt16(source[index * 2 + 1]) << 8
            let sample = Float(Int16(bitPattern: low | high)) * gain
            let value = Int16(max(Float(Int16.min), min(Float(Int16.max), sample.rounded())))
            let bits = UInt16(bitPattern: value)
            output[index * 2] = UInt8(bits & 0xff)
            output[index * 2 + 1] = UInt8(bits >> 8)
        }
        return Data(output)
    }
}
