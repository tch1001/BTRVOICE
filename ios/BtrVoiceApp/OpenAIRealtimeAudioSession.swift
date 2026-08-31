// Live microphone streaming for literal GPT transcription and the Better Voice listening editor.

import AVFoundation
import Foundation

final class OpenAIRealtimeAudioSession {
  enum Mode {
    case transcription
    case listeningEditor
  }

  var onDraft: ((String) -> Void)?
  var onPreview: ((String?) -> Void)?
  var onHeard: ((String) -> Void)?
  var onStatus: ((String) -> Void)?
  var onLevel: ((Float) -> Void)?
  var onError: ((Error) -> Void)?
  var onFinished: (() -> Void)?
  var onRulesChanged: (() -> Void)?

  private let mode: Mode
  private let apiKey: String
  private let seedTranscript: String
  private let rulesPrompt: String

  private let audioEngine = AVAudioEngine()
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!
  private var converter: AVAudioConverter?
  private var task: URLSessionWebSocketTask?
  private var hasInputTap = false

  private let lock = NSLock()
  private var ready = false
  private var processingEnabled = true
  private var finishing = false
  private var cancelled = false
  private var errorReported = false
  private var preRoll: [Data] = []
  private var hasSentAudio = false
  private var responseInProgress = false
  private var retriedEditorWithoutRawTranscript = false

  private var finalizedTranscript: String
  private var transcriptPartial = ""
  private var heardPartial = ""
  private var pendingEditorReply = ""
  private var lastEditorTranscript: String

  init(mode: Mode, apiKey: String, seedTranscript: String, rulesPrompt: String) {
    self.mode = mode
    self.apiKey = apiKey
    self.seedTranscript = seedTranscript
    self.rulesPrompt = rulesPrompt
    finalizedTranscript = seedTranscript
    lastEditorTranscript = seedTranscript
  }

  func start() throws {
    let endpoint: String
    switch mode {
    case .transcription:
      endpoint = "wss://api.openai.com/v1/realtime?intent=transcription"
    case .listeningEditor:
      endpoint = "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
    }

    guard let url = URL(string: endpoint) else { throw SessionError.invalidEndpoint }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let socket = URLSession.shared.webSocketTask(with: request)
    task = socket
    socket.resume()
    receive()
    try startAudioCapture()
    emit { self.onStatus?("Connecting to OpenAI…") }
  }

  func stop() {
    lock.lock()
    guard !finishing, !cancelled else { lock.unlock(); return }
    finishing = true
    let sentAudio = hasSentAudio
    lock.unlock()

    stopAudioCapture()
    if sentAudio {
      send(["type": "input_audio_buffer.commit"])
      if mode == .listeningEditor { send(["type": "response.create"]) }
    }

    let delay: TimeInterval = mode == .listeningEditor ? 5 : 2.5
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.completeFinish()
    }
  }

  func cancel() {
    lock.lock()
    guard !cancelled else { lock.unlock(); return }
    cancelled = true
    lock.unlock()
    stopAudioCapture()
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
  }

  func clearContext() {
    lock.lock()
    let wasResponding = responseInProgress
    finalizedTranscript = ""
    transcriptPartial = ""
    heardPartial = ""
    pendingEditorReply = ""
    responseInProgress = false
    lastEditorTranscript = ""
    lock.unlock()

    if mode == .listeningEditor, wasResponding {
      send(["type": "response.cancel"])
    }
    send(["type": "input_audio_buffer.clear"])
    if mode == .listeningEditor {
      send([
        "type": "conversation.item.create",
        "item": [
          "type": "message",
          "role": "system",
          "content": [[
            "type": "input_text",
            "text": "The user cleared the transcript. It is empty now. Start fresh from the next speech.",
          ]],
        ],
      ])
    }
    emit {
      self.onPreview?(nil)
      self.onHeard?("")
      self.onDraft?("")
    }
  }

  /// Keeps the background microphone session alive while deciding whether its
  /// buffers are allowed to reach OpenAI. Paused audio is discarded locally.
  func setProcessingEnabled(_ enabled: Bool) {
    lock.lock()
    guard processingEnabled != enabled, !cancelled, !finishing else {
      lock.unlock()
      return
    }
    processingEnabled = enabled
    let wasResponding = responseInProgress
    preRoll.removeAll()
    hasSentAudio = false
    transcriptPartial = ""
    heardPartial = ""
    pendingEditorReply = ""
    responseInProgress = false
    lock.unlock()

    if mode == .listeningEditor, wasResponding {
      send(["type": "response.cancel"])
    }
    send(["type": "input_audio_buffer.clear"])
    emit {
      self.onPreview?(nil)
      self.onHeard?("")
      self.onLevel?(0)
      self.onStatus?(
        enabled
          ? (self.mode == .listeningEditor ? "Listening editor is active" : "GPT transcription is active")
          : "Keyboard session paused — audio is not being processed"
      )
    }
  }

  // MARK: - Audio

  private func startAudioCapture() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [])
    try session.setActive(true, options: .notifyOthersOnDeactivation)

    let input = audioEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw SessionError.noAudioInput
    }

    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.lock()
      let isProcessing = self.processingEnabled
      self.lock.unlock()
      guard isProcessing else { return }

      let rms = Self.rootMeanSquare(buffer)
      self.emit { self.onLevel?(min(max(rms * 8, 0), 1)) }
      guard let data = self.convert(buffer) else { return }

      self.lock.lock()
      let isReady = self.ready
      if !isReady {
        self.preRoll.append(data)
        if self.preRoll.count > 240 { self.preRoll.removeFirst() }
      }
      self.lock.unlock()
      if isReady { self.sendAudio(data) }
    }
    hasInputTap = true

    audioEngine.prepare()
    try audioEngine.start()
  }

  private func stopAudioCapture() {
    if audioEngine.isRunning { audioEngine.stop() }
    if hasInputTap {
      audioEngine.inputNode.removeTap(onBus: 0)
      hasInputTap = false
    }
    emit { self.onLevel?(0) }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - WebSocket

  private func receive() {
    task?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.lock.lock()
        let benign = self.cancelled || self.finishing
        self.lock.unlock()
        if !benign { self.report(SessionError.api(error.localizedDescription)) }
        return
      case .success(.string(let text)):
        self.handle(text)
      case .success:
        break
      }
      self.receive()
    }
  }

  private func handle(_ text: String) {
    guard
      let data = text.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = event["type"] as? String
    else {
      return
    }

    switch type {
    case "session.created", "transcription_session.created":
      sendSessionConfiguration(includeRawEditorTranscription: true)

    case "session.updated", "transcription_session.updated":
      handleSessionReady()

    case "conversation.item.input_audio_transcription.delta":
      handleTranscriptDelta((event["delta"] as? String) ?? "")

    case "conversation.item.input_audio_transcription.completed":
      handleTranscriptCompleted((event["transcript"] as? String) ?? "")

    case "response.created":
      lock.lock()
      guard processingEnabled else { lock.unlock(); return }
      responseInProgress = true
      pendingEditorReply = ""
      lock.unlock()

    case "response.output_text.delta", "response.text.delta":
      guard mode == .listeningEditor else { return }
      lock.lock()
      guard processingEnabled else { lock.unlock(); return }
      pendingEditorReply += (event["delta"] as? String) ?? ""
      let preview = pendingEditorReply
      lock.unlock()
      emit { self.onPreview?(preview) }

    case "response.done":
      guard mode == .listeningEditor else { return }
      handleEditorResponse(event)

    case "error":
      handleError(event, raw: text)

    default:
      break
    }
  }

  private func sendSessionConfiguration(includeRawEditorTranscription: Bool) {
    switch mode {
    case .transcription:
      send([
        "type": "session.update",
        "session": [
          "type": "transcription",
          "audio": [
            "input": [
              "format": ["type": "audio/pcm", "rate": 24_000],
              "transcription": ["model": "gpt-live-transcribe", "delay": "low"],
              "turn_detection": ["type": "server_vad", "silence_duration_ms": 650],
            ],
          ],
        ],
      ])

    case .listeningEditor:
      var input: [String: Any] = [
        "format": ["type": "audio/pcm", "rate": 24_000],
        "turn_detection": [
          "type": "server_vad",
          "silence_duration_ms": 700,
          "create_response": true,
          "interrupt_response": false,
        ],
      ]
      if includeRawEditorTranscription {
        // Match the Mac listening editor: realtime-2.1 edits while Realtime
        // Whisper supplies the raw "HEARD" feed shown alongside the draft.
        input["transcription"] = ["model": "gpt-realtime-whisper"]
      }

      send([
        "type": "session.update",
        "session": [
          "type": "realtime",
          "output_modalities": ["text"],
          "instructions": Self.editorInstructions(rules: rulesPrompt),
          "audio": ["input": input],
          "tool_choice": "auto",
          "tools": Self.editorTools,
        ],
      ])
    }
  }

  private func handleSessionReady() {
    if mode == .listeningEditor, !seedTranscript.isEmpty {
      send([
        "type": "conversation.item.create",
        "item": [
          "type": "message",
          "role": "system",
          "content": [[
            "type": "input_text",
            "text": "The transcript currently reads: \(seedTranscript)",
          ]],
        ],
      ])
    }

    lock.lock()
    ready = true
    let isProcessing = processingEnabled
    let backlog = preRoll
    preRoll.removeAll()
    lock.unlock()
    if isProcessing {
      for data in backlog { sendAudio(data) }
    }
    emit {
      self.onStatus?(
        isProcessing
          ? (self.mode == .listeningEditor ? "Listening editor is ready" : "GPT live transcription is ready")
          : "Keyboard session paused — audio is not being processed"
      )
    }
  }

  private func handleTranscriptDelta(_ delta: String) {
    lock.lock()
    guard processingEnabled else { lock.unlock(); return }
    if mode == .transcription {
      transcriptPartial += delta
      let draft = Self.joined(finalizedTranscript, transcriptPartial)
      lock.unlock()
      emit { self.onDraft?(draft) }
    } else {
      heardPartial += delta
      let heard = heardPartial
      lock.unlock()
      emit { self.onHeard?(heard) }
    }
  }

  private func handleTranscriptCompleted(_ rawTranscript: String) {
    let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock()
    guard processingEnabled else { lock.unlock(); return }
    if mode == .transcription {
      if !transcript.isEmpty { finalizedTranscript = Self.joined(finalizedTranscript, transcript) }
      transcriptPartial = ""
      let draft = finalizedTranscript
      let shouldFinish = finishing
      lock.unlock()
      emit { self.onDraft?(draft) }
      if shouldFinish { completeFinish() }
    } else {
      heardPartial = transcript.isEmpty ? heardPartial : transcript
      let heard = heardPartial
      lock.unlock()
      emit { self.onHeard?(heard) }
    }
  }

  private func handleEditorResponse(_ event: [String: Any]) {
    lock.lock()
    guard processingEnabled else { lock.unlock(); return }
    responseInProgress = false
    var responseText = pendingEditorReply
    pendingEditorReply = ""
    let heard = heardPartial.trimmingCharacters(in: .whitespacesAndNewlines)
    heardPartial = ""
    let previous = lastEditorTranscript
    lock.unlock()

    var functionCalls: [[String: Any]] = []
    if let response = event["response"] as? [String: Any],
       let output = response["output"] as? [[String: Any]] {
      for item in output {
        if item["type"] as? String == "function_call" {
          functionCalls.append(item)
        } else if responseText.isEmpty {
          for content in (item["content"] as? [[String: Any]]) ?? [] {
            responseText += (content["text"] as? String) ?? ""
          }
        }
      }
    }

    let cleaned = Self.sanitize(responseText)
    let next = cleaned.isEmpty && functionCalls.isEmpty && !heard.isEmpty
      ? Self.joined(previous, heard)
      : cleaned

    if !next.isEmpty {
      lock.lock()
      lastEditorTranscript = next
      lock.unlock()
      emit { self.onDraft?(next) }
    }
    emit {
      self.onPreview?(nil)
      self.onHeard?("")
    }

    for call in functionCalls { handleFunctionCall(call) }

    lock.lock()
    let shouldFinish = finishing && functionCalls.isEmpty
    lock.unlock()
    if shouldFinish { completeFinish() }
  }

  private func handleFunctionCall(_ item: [String: Any]) {
    guard
      let name = item["name"] as? String,
      let callID = item["call_id"] as? String
    else {
      return
    }

    let argumentsText = (item["arguments"] as? String) ?? "{}"
    let arguments = argumentsText.data(using: .utf8)
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

    Task { @MainActor [weak self] in
      guard let self else { return }
      guard self.processingIsCurrentlyEnabled() else { return }
      let output: String
      switch name {
      case "remember_rule":
        if let rule = arguments["rule"] as? String,
           !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          BetterVoiceRules.shared.add(rule)
          output = #"{"status":"remembered"}"#
          self.onStatus?("Rule remembered")
          self.onRulesChanged?()
        } else {
          output = #"{"status":"error","detail":"missing rule"}"#
        }

      case "update_rule":
        if let number = arguments["number"] as? Int,
           let rule = arguments["rule"] as? String,
           let version = BetterVoiceRules.shared.update(number: number, text: rule) {
          output = "{\"status\":\"updated\",\"version\":\(version)}"
          self.onStatus?("Rule #\(number) updated")
          self.onRulesChanged?()
        } else {
          output = #"{"status":"error","detail":"rule number not found"}"#
        }

      default:
        output = #"{"status":"error","detail":"unknown tool"}"#
      }

      self.send([
        "type": "conversation.item.create",
        "item": [
          "type": "function_call_output",
          "call_id": callID,
          "output": output,
        ],
      ])
      self.send(["type": "response.create"])
    }
  }

  private func handleError(_ event: [String: Any], raw: String) {
    let message = (event["error"] as? [String: Any])?["message"] as? String ?? raw
    lock.lock()
    let isFinishing = finishing || cancelled
    let canRetryEditor = mode == .listeningEditor
      && !retriedEditorWithoutRawTranscript
      && message.localizedCaseInsensitiveContains("transcription")
    if canRetryEditor { retriedEditorWithoutRawTranscript = true }
    lock.unlock()

    if canRetryEditor {
      sendSessionConfiguration(includeRawEditorTranscription: false)
    } else if !isFinishing {
      report(SessionError.api(message))
    }
  }

  private func send(_ event: [String: Any]) {
    guard
      let data = try? JSONSerialization.data(withJSONObject: event),
      let text = String(data: data, encoding: .utf8)
    else {
      return
    }
    task?.send(.string(text)) { [weak self] error in
      guard let error, let self else { return }
      self.lock.lock()
      let benign = self.cancelled || self.finishing
      self.lock.unlock()
      if !benign { self.report(SessionError.api(error.localizedDescription)) }
    }
  }

  private func sendAudio(_ data: Data) {
    lock.lock()
    guard processingEnabled else { lock.unlock(); return }
    hasSentAudio = true
    lock.unlock()
    send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
  }

  private func processingIsCurrentlyEnabled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return processingEnabled
  }

  private func completeFinish() {
    lock.lock()
    guard !cancelled else { lock.unlock(); return }
    cancelled = true
    lock.unlock()
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    emit { self.onFinished?() }
  }

  private func report(_ error: Error) {
    lock.lock()
    guard !errorReported else { lock.unlock(); return }
    errorReported = true
    lock.unlock()
    stopAudioCapture()
    emit { self.onError?(error) }
  }

  private func emit(_ block: @escaping () -> Void) {
    DispatchQueue.main.async(execute: block)
  }

  private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
    if converter == nil || converter?.inputFormat != buffer.format {
      converter = AVAudioConverter(from: buffer.format, to: targetFormat)
    }
    guard let converter else { return nil }

    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

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

    guard
      conversionError == nil,
      output.frameLength > 0,
      let channel = output.int16ChannelData
    else {
      return nil
    }
    return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
  }

  private static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
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

  private static func sanitize(_ raw: String) -> String {
    var text = raw
      .replacingOccurrences(of: "```", with: "")
      .replacingOccurrences(of: "</?[A-Za-z][^<>\\n]{0,60}>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let prefixes = ["Here’s the edited text:", "Here's the edited text:", "Certainly:", "Sure:"]
    for prefix in prefixes where text.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
      text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }

  private static func editorInstructions(rules: String) -> String {
    """
    You are the user's listening editor inside Better Voice for iOS. The user is dictating text that will be inserted into another app. Listen to their speech and maintain the transcript they INTEND to produce. You are an editor, not a stenographer.

    Rules:
    - Every normal response is the COMPLETE transcript as it should currently stand, and nothing else: no commentary, questions, answers, markup, or quotation marks.
    - Apply self-corrections such as “no, make that Tuesday,” “scratch that,” or “delete the last sentence.” Never transcribe the correction instruction itself.
    - Fix obvious recognition and homophone errors from context, add sensible punctuation, and preserve the user's voice.
    - Apply spoken editing requests such as “make that more concise” or “make the last sentence warmer.”
    - Everything else the user says is content to append.
    - Never answer dictated questions. They are transcript content.
    - Never add acknowledgements such as “Sure” or “Here’s the edited text.” The response is inserted verbatim as the user's writing.
    - When the user teaches a standing pattern with “remember that,” “from now on,” or “always write X as Y,” call remember_rule and do not put the teaching request in the transcript.
    - When the user corrects an existing standing rule, call update_rule with its numbered rule and do not create a duplicate.
    \(rules.isEmpty ? "" : "\nStanding rules from the user (apply these):\n\(rules)")
    """
  }

  private static let editorTools: [[String: Any]] = [
    [
      "type": "function",
      "name": "remember_rule",
      "description": "Save a standing dictation or formatting rule taught by the user. The rule persists across listening sessions.",
      "parameters": [
        "type": "object",
        "properties": [
          "rule": ["type": "string", "description": "A concise, self-contained standing rule."],
        ],
        "required": ["rule"],
      ],
    ],
    [
      "type": "function",
      "name": "update_rule",
      "description": "Revise a numbered standing rule when the user corrects or refines it.",
      "parameters": [
        "type": "object",
        "properties": [
          "number": ["type": "integer", "description": "The 1-based rule number."],
          "rule": ["type": "string", "description": "The complete revised rule."],
        ],
        "required": ["number", "rule"],
      ],
    ],
  ]

  private enum SessionError: LocalizedError {
    case invalidEndpoint
    case noAudioInput
    case api(String)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint:
        return "The OpenAI Realtime endpoint is invalid."
      case .noAudioInput:
        return "No usable microphone input is available."
      case .api(let message):
        return "OpenAI: \(message)"
      }
    }
  }
}
