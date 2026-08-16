import FluidAudio
import Foundation

/// Keeps untrusted room audio off the Realtime connection.
///
/// Native VoiceProcessingIO applies acoustic echo cancellation against Jarvis's
/// speaker playback. Before AVAudioEngine forwards a microphone window to OpenAI,
/// this actor classifies it with a locally enrolled Sortformer speaker. Only frames
/// belonging to the owner receive a non-zero mask. Model weights and the enrollment
/// clip stay on this Mac.
actor JarvisSpeakerGate {
    static let shared = JarvisSpeakerGate()

    private enum Phase: String {
        case idle
        case loading
        case needsEnrollment = "needs_enrollment"
        case enrolling
        case ready
        case failed
    }

    private struct EnrollmentProfile: Codable {
        let sampleRate: Double
        let pcm16: Data
        let createdAt: Date
    }

    private let modelConfig = SortformerConfig.fastV2_1
    private let profileURL: URL
    private var phase: Phase
    private var progress: Double = 0
    private var detail = ""
    private var diarizer: SortformerDiarizer?
    private var ownerSpeakerIndex: Int?

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        profileURL = support
            .appendingPathComponent("BtrVoice", isDirectory: true)
            .appendingPathComponent("VoiceGate", isDirectory: true)
            .appendingPathComponent("owner-voice.json")
        phase = FileManager.default.fileExists(atPath: profileURL.path)
            ? .idle
            : .needsEnrollment
    }

    func handle(_ body: Any) async -> [String: Any] {
        guard let request = body as? [String: Any],
              let operation = request["operation"] as? String else {
            return failure("The local voice-filter request was malformed.")
        }

        switch operation {
        case "status":
            return state()
        case "prepare":
            return await prepare()
        case "enroll":
            return await enroll(request)
        case "classify":
            return classify(request)
        case "forget":
            return forget()
        default:
            return failure("Unknown local voice-filter operation.")
        }
    }

    private func prepare() async -> [String: Any] {
        if diarizer != nil {
            phase = ownerSpeakerIndex == nil ? .needsEnrollment : .ready
            return state()
        }
        if phase == .loading {
            return state()
        }

        phase = .loading
        progress = 0
        detail = "Loading the local speaker model…"
        do {
            let config = modelConfig
            let models = try await SortformerModels.loadFromHuggingFace(
                config: config,
                progressHandler: { [weak self] update in
                    Task { await self?.noteProgress(update.fractionCompleted) }
                }
            )
            let loaded = SortformerDiarizer(config: config)
            loaded.initialize(models: models)
            diarizer = loaded
            progress = 1

            if let profile = loadProfile() {
                guard try enroll(profile, with: loaded) else {
                    phase = .failed
                    detail = "The saved voice profile could not be recognized. Enroll it again."
                    return state()
                }
                phase = .ready
                detail = "Only your enrolled voice will be forwarded to Realtime."
            } else {
                phase = .needsEnrollment
                detail = "The model is ready. Enroll your voice to turn on filtering."
            }
        } catch {
            diarizer = nil
            ownerSpeakerIndex = nil
            phase = .failed
            detail = "Could not load the local speaker model: \(error.localizedDescription)"
        }
        return state()
    }

    private func enroll(_ request: [String: Any]) async -> [String: Any] {
        if diarizer == nil {
            let prepared = await prepare()
            guard diarizer != nil else { return prepared }
        }
        guard let loaded = diarizer,
              let profile = profile(from: request) else {
            return failure("The enrollment recording was missing or invalid.")
        }

        let duration = Double(profile.pcm16.count / 2) / profile.sampleRate
        guard (4.0...12.0).contains(duration) else {
            return failure("Please provide between 4 and 12 seconds of enrollment speech.")
        }
        let samples = Self.floatSamples(fromPCM16: profile.pcm16)
        guard Self.rms(samples) >= 0.006 else {
            return failure("The enrollment was too quiet. Speak naturally and try again.")
        }

        phase = .enrolling
        detail = "Learning your voice locally…"
        let previousProfile = loadProfile()
        do {
            loaded.reset()
            ownerSpeakerIndex = nil
            guard try enroll(profile, with: loaded) else {
                restore(previousProfile, with: loaded)
                detail = ownerSpeakerIndex == nil
                    ? "I could not find enough clear speech. Please enroll again."
                    : "The new sample was unclear, so the previous voice profile remains active."
                return state()
            }
            try save(profile)
            phase = .ready
            detail = "Voice filter active. Only your enrolled voice is forwarded."
            return state()
        } catch {
            restore(previousProfile, with: loaded)
            detail = ownerSpeakerIndex == nil
                ? "Voice enrollment failed: \(error.localizedDescription)"
                : "The new sample failed, so the previous voice profile remains active."
            return state()
        }
    }

    private func classify(_ request: [String: Any]) -> [String: Any] {
        guard phase == .ready,
              let loaded = diarizer,
              let ownerSpeakerIndex,
              let profile = profile(from: request) else {
            return [
                "ok": false,
                "phase": phase.rawValue,
                "mask": [],
                "detail": "The local voice filter is not ready.",
            ]
        }

        let duration = Double(profile.pcm16.count / 2) / profile.sampleRate
        guard (0.8...2.5).contains(duration) else {
            return failure("The voice-filter audio window had an invalid duration.")
        }

        do {
            let samples = Self.floatSamples(fromPCM16: profile.pcm16)
            let timeline = try loaded.processComplete(
                samples,
                sourceSampleRate: profile.sampleRate,
                keepingEnrolledSpeakers: true,
                finalizeOnCompletion: true
            )
            let predictions = timeline.finalizedPredictions + timeline.tentativePredictions
            let classification = SpeakerFrameGate.classify(
                predictions: predictions,
                speakerCount: timeline.speakerCapacity,
                ownerIndex: ownerSpeakerIndex
            )
            return [
                "ok": true,
                "phase": phase.rawValue,
                "mask": classification.mask.map { $0 ? 1 : 0 },
                "frame_duration_ms": Int(timeline.config.frameDurationSeconds * 1_000),
                "accepted": classification.mask.contains(true),
                "overlap": classification.overlap,
                "speech_detected": classification.speechDetected,
                "confidence": classification.confidence,
                "detail": classification.mask.contains(true)
                    ? "Owner voice accepted locally."
                    : (classification.overlap
                        ? "Overlapping speakers were withheld."
                        : "Non-owner audio was withheld."),
            ]
        } catch {
            phase = .failed
            detail = "Local speaker classification failed: \(error.localizedDescription)"
            return [
                "ok": false,
                "phase": phase.rawValue,
                "mask": [],
                "detail": detail,
            ]
        }
    }

    private func forget() -> [String: Any] {
        try? FileManager.default.removeItem(at: profileURL)
        diarizer?.reset()
        ownerSpeakerIndex = nil
        phase = diarizer == nil ? .idle : .needsEnrollment
        detail = "The saved local voice profile was removed."
        return state()
    }

    private func enroll(
        _ profile: EnrollmentProfile,
        with loaded: SortformerDiarizer
    ) throws -> Bool {
        let samples = Self.floatSamples(fromPCM16: profile.pcm16)
        let speaker = try loaded.enrollSpeaker(
            withAudio: samples,
            sourceSampleRate: profile.sampleRate,
            named: "Owner",
            overwritingAssignedSpeakerName: true
        )
        ownerSpeakerIndex = speaker?.index
        return speaker != nil
    }

    private func restore(
        _ profile: EnrollmentProfile?,
        with loaded: SortformerDiarizer
    ) {
        loaded.reset()
        ownerSpeakerIndex = nil
        if let profile, (try? enroll(profile, with: loaded)) == true {
            phase = .ready
        } else {
            phase = .needsEnrollment
        }
    }

    private func profile(from request: [String: Any]) -> EnrollmentProfile? {
        guard let encoded = request["pcm16"] as? String,
              encoded.count <= 2_500_000,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count.isMultiple(of: 2),
              let sampleRate = (request["sample_rate"] as? NSNumber)?.doubleValue,
              (8_000...96_000).contains(sampleRate) else {
            return nil
        }
        return EnrollmentProfile(sampleRate: sampleRate, pcm16: data, createdAt: Date())
    }

    private func loadProfile() -> EnrollmentProfile? {
        guard let data = try? Data(contentsOf: profileURL) else { return nil }
        return try? JSONDecoder().decode(EnrollmentProfile.self, from: data)
    }

    private func save(_ profile: EnrollmentProfile) throws {
        let directory = profileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(profile)
        try data.write(to: profileURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: profileURL.path
        )
    }

    private func noteProgress(_ value: Double) {
        guard phase == .loading else { return }
        progress = max(progress, min(1, value))
        detail = "Loading the local speaker model… \(Int(progress * 100))%"
    }

    private func state() -> [String: Any] {
        [
            "ok": phase != .failed,
            "available": true,
            "phase": phase.rawValue,
            "has_profile": FileManager.default.fileExists(atPath: profileURL.path),
            "progress": progress,
            "model": "FluidAudio Sortformer · Core ML",
            "detail": detail,
        ]
    }

    private func failure(_ message: String) -> [String: Any] {
        [
            "ok": false,
            "available": true,
            "phase": phase.rawValue,
            "mask": [],
            "detail": message,
        ]
    }

    private static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let bytes = [UInt8](data)
        var samples = [Float]()
        samples.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let word = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            samples.append(Float(Int16(bitPattern: word)) / 32_768)
        }
        return samples
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(energy / Float(samples.count))
    }
}

/// Pure frame policy kept separate from model loading so `--self-test` can protect
/// the safety rule: owner speech passes, other speakers and overlaps do not.
enum SpeakerFrameGate {
    struct Classification {
        let mask: [Bool]
        let overlap: Bool
        let speechDetected: Bool
        let confidence: Double
    }

    static func classify(
        predictions: [Float],
        speakerCount: Int,
        ownerIndex: Int,
        ownerThreshold: Float = 0.45,
        overlapThreshold: Float = 0.50
    ) -> Classification {
        guard speakerCount > 0,
              ownerIndex >= 0,
              ownerIndex < speakerCount,
              predictions.count.isMultiple(of: speakerCount) else {
            return Classification(
                mask: [],
                overlap: false,
                speechDetected: false,
                confidence: 0
            )
        }

        var mask: [Bool] = []
        var overlap = false
        var ownerPeak: Float = 0
        var speakerPeak: Float = 0
        for frame in 0..<(predictions.count / speakerCount) {
            let offset = frame * speakerCount
            let owner = predictions[offset + ownerIndex]
            ownerPeak = max(ownerPeak, owner)
            var strongestOther: Float = 0
            for speaker in 0..<speakerCount where speaker != ownerIndex {
                strongestOther = max(strongestOther, predictions[offset + speaker])
            }
            speakerPeak = max(speakerPeak, max(owner, strongestOther))
            let frameOverlaps = owner >= ownerThreshold && strongestOther >= overlapThreshold
            overlap = overlap || frameOverlaps
            mask.append(
                owner >= ownerThreshold
                    && !frameOverlaps
                    && owner >= strongestOther + 0.08
            )
        }

        // Preserve soft consonant edges adjacent to a confidently accepted owner
        // frame, but never pad across a frame that looks like another speaker.
        let strict = mask
        for frame in mask.indices where !strict[frame] {
            let adjacentOwner = (frame > 0 && strict[frame - 1])
                || (frame + 1 < strict.count && strict[frame + 1])
            guard adjacentOwner else { continue }
            let offset = frame * speakerCount
            let owner = predictions[offset + ownerIndex]
            let other = (0..<speakerCount)
                .filter { $0 != ownerIndex }
                .map { predictions[offset + $0] }
                .max() ?? 0
            if owner >= 0.25 && other < overlapThreshold {
                mask[frame] = true
            }
        }

        return Classification(
            mask: mask,
            overlap: overlap,
            speechDetected: speakerPeak >= ownerThreshold,
            confidence: Double(ownerPeak)
        )
    }
}
