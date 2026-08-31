// The iOS listening/editor coordinator with Apple, GPT transcription, and GPT editor modes.

import AVFoundation
import Foundation
import Speech

enum SpeechEngineMode: String, CaseIterable, Identifiable {
  case listeningEditor
  case gptTranscription
  case appleSpeech

  var id: String { rawValue }

  var title: String {
    switch self {
    case .listeningEditor: return "Listening Editor"
    case .gptTranscription: return "GPT Transcript"
    case .appleSpeech: return "Apple Local"
    }
  }

  var shortTitle: String {
    switch self {
    case .listeningEditor: return "Editor"
    case .gptTranscription: return "Transcript"
    case .appleSpeech: return "Local"
    }
  }

  var detail: String {
    switch self {
    case .listeningEditor:
      return "The Mac app’s GPT editor: applies corrections, rewrites, and remembered rules."
    case .gptTranscription:
      return "Literal low-latency speech-to-text with gpt-live-transcribe."
    case .appleSpeech:
      return "Apple Speech fallback without an OpenAI key."
    }
  }

  var needsOpenAIKey: Bool { self != .appleSpeech }
}

@MainActor
final class SpeechTranscriber: NSObject, ObservableObject {
  @Published var transcript = ""
  @Published private(set) var heardText = ""
  @Published private(set) var editorPreview: String?
  @Published private(set) var isRecording = false
  @Published private(set) var isProcessingAudio = false
  @Published private(set) var status = "Ready to listen"
  @Published private(set) var level: Float = 0
  @Published private(set) var hasOpenAIKey = OpenAIKeyStore.isSet
  @Published var engineMode: SpeechEngineMode {
    didSet { UserDefaults.standard.set(engineMode.rawValue, forKey: Self.engineKey) }
  }

  private static let engineKey = "iosSpeechEngineMode"

  private var realtimeSession: OpenAIRealtimeAudioSession?

  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: .current)
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var hasInputTap = false
  private var appleSeedTranscript = ""
  private var liveDraftPublishWorkItem: DispatchWorkItem?
  private var keyboardCommandTimer: Timer?
  private var lastKeyboardCommandID: UUID?
  private var lastLiveHeartbeat = Date.distantPast

  override init() {
    engineMode = SpeechEngineMode(
      rawValue: UserDefaults.standard.string(forKey: Self.engineKey) ?? ""
    ) ?? .listeningEditor
    super.init()
  }

  var displayedTranscript: String { editorPreview ?? transcript }

  func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      Task { await startRecording() }
    }
  }

  func selectEngine(_ mode: SpeechEngineMode) {
    guard !isRecording else { return }
    engineMode = mode
    heardText = ""
    editorPreview = nil
    status = mode.needsOpenAIKey && !hasOpenAIKey
      ? "Add an OpenAI API key in Settings"
      : "Ready — \(mode.title)"
  }

  func clear() {
    if isRecording, engineMode != .appleSpeech {
      realtimeSession?.clearContext()
    }
    guard !isRecording || engineMode != .appleSpeech else { return }
    transcript = ""
    heardText = ""
    editorPreview = nil
    publishLiveDraft(isListening: isRecording, immediately: true)
    status = isRecording ? "Listening from a fresh draft" : "Draft cleared"
  }

  func markCommitted() {
    status = "Edited draft committed — switch to the Better Voice keyboard"
  }

  func apiKeyDidChange() {
    hasOpenAIKey = OpenAIKeyStore.isSet
    if engineMode.needsOpenAIKey {
      status = hasOpenAIKey ? "OpenAI key saved — ready to listen" : "Add an OpenAI API key in Settings"
    }
  }

  func stopRecording() {
    guard isRecording else { return }
    switch engineMode {
    case .appleSpeech:
      finishAppleSession(cancelRecognition: false)
      status = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "No speech captured"
        : "Review or edit the draft, then commit it"
    case .listeningEditor, .gptTranscription:
      status = "Finishing the current phrase…"
      realtimeSession?.stop()
    }
  }

  private func startRecording() async {
    guard !isRecording else { return }
    guard await requestMicrophonePermission() else { return }

    switch engineMode {
    case .appleSpeech:
      guard await requestSpeechPermission() else { return }
      startAppleSession()
    case .listeningEditor, .gptTranscription:
      startOpenAISession()
    }
  }

  private func startOpenAISession() {
    guard let key = OpenAIKeyStore.read() else {
      hasOpenAIKey = false
      status = "Add your OpenAI API key in Settings first"
      return
    }

    let mode: OpenAIRealtimeAudioSession.Mode = engineMode == .listeningEditor
      ? .listeningEditor
      : .transcription
    let session = OpenAIRealtimeAudioSession(
      mode: mode,
      apiKey: key,
      seedTranscript: transcript,
      rulesPrompt: BetterVoiceRules.shared.promptBlock
    )
    realtimeSession = session

    session.onDraft = { [weak self] draft in
      guard let self else { return }
      self.transcript = draft
      self.publishLiveDraft(isListening: true)
    }
    session.onPreview = { [weak self] preview in
      guard let self else { return }
      self.editorPreview = preview
      self.publishLiveDraft(isListening: true)
    }
    session.onHeard = { [weak self] heard in
      guard let self else { return }
      self.heardText = heard
      self.publishLiveDraft(isListening: true)
    }
    session.onStatus = { [weak self] status in self?.status = status }
    session.onLevel = { [weak self] level in self?.level = level }
    session.onRulesChanged = { [weak self] in
      self?.status = "Standing rule saved — it will apply to future sessions"
    }
    session.onError = { [weak self] error in
      guard let self else { return }
      self.realtimeSession = nil
      self.isRecording = false
      self.isProcessingAudio = false
      self.level = 0
      self.editorPreview = nil
      self.status = error.localizedDescription
      self.stopKeyboardCommandPolling()
      self.publishLiveDraft(isListening: false, immediately: true)
    }
    session.onFinished = { [weak self] in
      guard let self else { return }
      self.realtimeSession = nil
      self.isRecording = false
      self.isProcessingAudio = false
      self.level = 0
      self.editorPreview = nil
      self.heardText = ""
      self.stopKeyboardCommandPolling()
      self.status = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "No speech captured"
        : "Review or edit the draft, then commit it"
      self.publishLiveDraft(isListening: false, immediately: true)
    }

    do {
      try session.start()
      isRecording = true
      isProcessingAudio = true
      startKeyboardCommandPolling()
      publishLiveDraft(isListening: true, immediately: true)
      status = engineMode == .listeningEditor
        ? "Connecting the listening editor…"
        : "Connecting GPT live transcription…"
    } catch {
      realtimeSession = nil
      isRecording = false
      isProcessingAudio = false
      level = 0
      status = "Could not start listening: \(error.localizedDescription)"
    }
  }

  // MARK: - Apple Speech fallback

  private func startAppleSession() {
    guard let recognizer, recognizer.isAvailable else {
      status = "Apple Speech recognition is currently unavailable"
      return
    }

    finishAppleSession(cancelRecognition: true)
    appleSeedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
      status = "Listening with Apple on-device recognition"
    } else {
      status = "Listening with Apple Speech"
    }
    recognitionRequest = request

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [])
      try session.setActive(true, options: .notifyOthersOnDeactivation)

      let input = audioEngine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw AppleTranscriptionError.noAudioInput
      }

      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
        self?.recognitionRequest?.append(buffer)
        let rms = Self.rootMeanSquare(buffer)
        Task { @MainActor [weak self] in self?.level = min(max(rms * 8, 0), 1) }
      }
      hasInputTap = true

      audioEngine.prepare()
      try audioEngine.start()
      isRecording = true
      isProcessingAudio = true
      startKeyboardCommandPolling()
      publishLiveDraft(isListening: true, immediately: true)

      recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let result {
            self.transcript = Self.joined(self.appleSeedTranscript, result.bestTranscription.formattedString)
            self.publishLiveDraft(isListening: true)
          }
          if error != nil {
            self.finishAppleSession(cancelRecognition: true)
            self.status = self.transcript.isEmpty
              ? "Apple Speech stopped before capturing words"
              : "Recognition ended — review the draft"
          } else if result?.isFinal == true {
            self.finishAppleSession(cancelRecognition: false)
            self.status = "Review or edit the draft, then commit it"
          }
        }
      }
    } catch {
      finishAppleSession(cancelRecognition: true)
      status = "Could not start Apple Speech: \(error.localizedDescription)"
    }
  }

  private func finishAppleSession(cancelRecognition: Bool) {
    if audioEngine.isRunning { audioEngine.stop() }
    if hasInputTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasInputTap = false
    }
    recognitionRequest?.endAudio()
    if cancelRecognition { recognitionTask?.cancel() } else { recognitionTask?.finish() }
    recognitionRequest = nil
    recognitionTask = nil
    isRecording = false
    isProcessingAudio = false
    level = 0
    stopKeyboardCommandPolling()
    publishLiveDraft(isListening: false, immediately: true)
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func publishLiveDraft(isListening: Bool, immediately: Bool = false) {
    liveDraftPublishWorkItem?.cancel()
    let text = displayedTranscript
    let heard = heardText
    let processing = isProcessingAudio
    let supportsGating = engineMode != .appleSpeech
    if immediately {
      SharedTranscriptStore.updateLiveDraft(
        text,
        heardText: heard,
        isListening: isListening,
        isProcessing: processing,
        supportsGating: supportsGating
      )
      return
    }

    let work = DispatchWorkItem {
      SharedTranscriptStore.updateLiveDraft(
        text,
        heardText: heard,
        isListening: isListening,
        isProcessing: processing,
        supportsGating: supportsGating
      )
    }
    liveDraftPublishWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
  }

  private func startKeyboardCommandPolling() {
    keyboardCommandTimer?.invalidate()
    lastKeyboardCommandID = SharedTranscriptStore.loadKeyboardCommand()?.id
    lastLiveHeartbeat = Date()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.handleKeyboardCommandIfNeeded() }
    }
    keyboardCommandTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopKeyboardCommandPolling() {
    keyboardCommandTimer?.invalidate()
    keyboardCommandTimer = nil
  }

  private func handleKeyboardCommandIfNeeded() {
    if isRecording, Date().timeIntervalSince(lastLiveHeartbeat) >= 1 {
      lastLiveHeartbeat = Date()
      SharedTranscriptStore.updateLiveDraft(
        displayedTranscript,
        heardText: heardText,
        isListening: true,
        isProcessing: isProcessingAudio,
        supportsGating: engineMode != .appleSpeech
      )
    }

    guard
      isRecording,
      let command = SharedTranscriptStore.loadKeyboardCommand(),
      command.id != lastKeyboardCommandID
    else {
      return
    }
    lastKeyboardCommandID = command.id

    switch command.action {
    case .clearDraft:
      clear()
      status = "Draft cleared from the keyboard"
    case .startProcessing:
      guard let realtimeSession else {
        status = "Keyboard listening control requires a GPT session"
        return
      }
      realtimeSession.setProcessingEnabled(true)
      isProcessingAudio = true
      heardText = ""
      editorPreview = nil
      status = "Listening from the keyboard"
      publishLiveDraft(isListening: true, immediately: true)
    case .stopProcessing:
      guard let realtimeSession else {
        status = "Keyboard listening control requires a GPT session"
        return
      }
      realtimeSession.setProcessingEnabled(false)
      isProcessingAudio = false
      heardText = ""
      editorPreview = nil
      level = 0
      status = "Paused from the keyboard — audio is not being processed"
      publishLiveDraft(isListening: true, immediately: true)
    case .finishDraft:
      guard let realtimeSession else {
        clear()
        return
      }
      clear()
      realtimeSession.setProcessingEnabled(false)
      isProcessingAudio = false
      heardText = ""
      editorPreview = nil
      level = 0
      status = "Inserted — tap Listen in the keyboard for the next draft"
      publishLiveDraft(isListening: true, immediately: true)
    }
  }

  // MARK: - Permissions

  private func requestMicrophonePermission() async -> Bool {
    let allowed = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
    }
    guard allowed else {
      status = "Microphone permission is required"
      return false
    }
    return true
  }

  private func requestSpeechPermission() async -> Bool {
    let authorization = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard authorization == .authorized else {
      status = "Speech Recognition permission is required for Apple Local mode"
      return false
    }
    return true
  }

  nonisolated private static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?.pointee else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<count {
      let sample = channel[index]
      sum += sample * sample
    }
    return sqrt(sum / Float(count))
  }

  private static func joined(_ lhs: String, _ rhs: String) -> String {
    let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    if left.isEmpty { return right }
    if right.isEmpty { return left }
    return left + " " + right
  }

  private enum AppleTranscriptionError: LocalizedError {
    case noAudioInput

    var errorDescription: String? { "No usable microphone input is available." }
  }
}
