import AVFoundation
import Foundation

/// The "talk to an editor" architecture: instead of a transcriber that records
/// exactly what was said, the user's audio streams to gpt-realtime-2.1, which
/// maintains the transcript the user *intends*. Self-corrections ("no wait,
/// make that Tuesday") are applied, not transcribed; recognition errors are
/// fixed from context; saved Jarvis rules apply continuously. Every model
/// response is the complete current transcript and REPLACES the buffer.
final class OpenAIEditorEngine: NSObject, TranscriptionEngine {

    var onPartial: ((String) -> Void)?
    var onSegmentFinal: ((String) -> Void)?
    var onFinished: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The editor recognised an app action by meaning ("copy the highlighted
    /// text") and wants it staged. Delivered on the main thread; the controller
    /// runs it through the confirmation overlay like any spoken command.
    var onCommand: ((BufferAction) -> Void)?
    /// The editor's rewrite streaming in — the full transcript so far, shown in
    /// place of the buffer while it arrives. Nil clears the preview.
    var onReplacementPreview: ((String?) -> Void)?

    var displayName: String { "GPT Editor" }
    var isOnDevice: Bool { false }
    var isAvailable: Bool { OpenAIKeyStore.isSet }
    var segmentDuration: TimeInterval { 0 }
    var replacesBuffer: Bool { true }

    /// Transcript already staged when the session starts, so the editor
    /// continues the user's text instead of starting blank.
    private let seedTranscript: String
    private let model = "gpt-realtime-2.1"

    private var task: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true
    )!

    private let lock = NSLock()
    private var ready = false
    private var finishing = false
    private var cancelled = false
    private var preRoll: [Data] = []
    private var pendingReply = ""
    /// Raw speech-to-text of what the user is saying right now, for feedback
    /// while they talk (the polished rewrite only starts once they pause).
    private var rawPartial = ""
    private var errorReported = false
    private var transcriptionRetried = false

    enum EngineError: LocalizedError {
        case noKey
        case api(String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "No OpenAI API key set (Jarvis menu → Set OpenAI API Key)."
            case .api(let message): return "OpenAI: \(message)"
            }
        }
    }

    init(seedTranscript: String) {
        self.seedTranscript = seedTranscript
    }

    func start() throws {
        guard let key = OpenAIKeyStore.read() else { throw EngineError.noKey }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()
        receive()
        Log.write("gpt-editor: connecting")
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = convert(buffer) else { return }
        lock.lock()
        let isReady = ready
        if !isReady { preRoll.append(data); if preRoll.count > 200 { preRoll.removeFirst() } }
        lock.unlock()
        guard isReady else { return }
        send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    func rotate() { /* the editor has no segment cliff */ }

    func discardUtterance() {
        // The user emptied the buffer — tell the editor its transcript is gone.
        send(["type": "conversation.item.create", "item": [
            "type": "message", "role": "system",
            "content": [["type": "input_text", "text": "The user cleared the transcript. It is now empty. Start fresh from their next speech."]],
        ]])
    }

    func finish() {
        lock.lock()
        finishing = true
        lock.unlock()
        // Flush any trailing audio and ask for one last transcript pass.
        send(["type": "input_audio_buffer.commit"])
        send(["type": "response.create"])
        DispatchQueue.main.async { [weak self] in
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                self?.completeFinish()
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
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
                if !benign { self.reportError(EngineError.api(error.localizedDescription)) }
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
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "session.created":
            sendSessionConfig(withInputTranscription: true)

        case "session.updated":
            handleSessionReady()

        case "conversation.item.input_audio_transcription.delta":
            // Live feedback while the user is still speaking: raw recognition
            // of their words, shown as the grey in-flight tail.
            lock.lock()
            rawPartial += (event["delta"] as? String) ?? ""
            let partial = rawPartial
            lock.unlock()
            emit { self.onPartial?(partial) }

        case "conversation.item.input_audio_transcription.completed":
            lock.lock()
            rawPartial = ((event["transcript"] as? String) ?? rawPartial)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let partial = rawPartial
            lock.unlock()
            emit { self.onPartial?(partial) }

        case "response.output_text.delta", "response.text.delta":
            lock.lock()
            pendingReply += (event["delta"] as? String) ?? ""
            let preview = pendingReply
            lock.unlock()
            // Stream the rewrite as it's generated instead of popping at the end.
            emit { self.onReplacementPreview?(preview) }

        case "response.done":
            handleResponseDone(event)

        case "error":
            handleErrorEvent(event, raw: text)

        default:
            break
        }
    }

    private func sendSessionConfig(withInputTranscription: Bool) {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "turn_detection": ["type": "server_vad"],
        ]
        if withInputTranscription {
            input["transcription"] = ["model": "gpt-realtime-whisper"]
        }
        send(["type": "session.update", "session": [
            "type": "realtime",
            "output_modalities": ["text"],
            "instructions": Self.editorInstructions(),
            "audio": ["input": input],
            "tool_choice": "auto",
            "tools": [
                    [
                        "type": "function",
                        "name": "remember_rule",
                        "description": "Save a standing rule the user taught you (a spoken alias, a formatting preference, a 'from now on when I say X do Y' pattern). The rule persists across sessions and is shown to you at the start of every future one.",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "rule": [
                                    "type": "string",
                                    "description": "The rule, stated concisely and self-contained, e.g. 'when the user says github dot com, write tch1001.github.io'",
                                ],
                            ],
                            "required": ["rule"],
                        ],
                    ],
                    [
                        "type": "function",
                        "name": "app_command",
                        "description": "Perform an action in the dictation app. Call this whenever the user asks for one of these actions in ANY phrasing — 'do copy', 'copy the text', 'copy the highlighted text' all mean copy. The app shows the user a confirmation before executing, so calling this is safe.",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "action": [
                                    "type": "string",
                                    "enum": ["paste", "copy", "select_all", "click", "insert", "send"],
                                    "description": "paste = press Cmd-V in the target app; copy = press Cmd-C (copies whatever is selected there); select_all = press Cmd-A; click = left-click at the current mouse pointer; insert = type the current transcript into the target app; send = type the transcript, then press Return to send it.",
                                ],
                            ],
                            "required": ["action"],
                        ],
                    ],
                ],
        ]])
    }

    private func handleSessionReady() {
        if !seedTranscript.isEmpty {
            send(["type": "conversation.item.create", "item": [
                "type": "message", "role": "system",
                "content": [["type": "input_text", "text": "The transcript currently reads: \(seedTranscript)"]],
            ]])
        }
        lock.lock()
        ready = true
        let backlog = preRoll
        preRoll.removeAll()
        lock.unlock()
        Log.write("gpt-editor: session ready")
        emit { self.onStatus?("Editor listening") }
        for chunk in backlog {
            send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()])
        }
    }

    private func handleResponseDone(_ event: [String: Any]) {
        lock.lock()
        var transcript = pendingReply
        pendingReply = ""
        rawPartial = ""
        let stillFinishing = finishing
        lock.unlock()

        // The editor may have called a tool instead of (or besides) producing
        // transcript text.
        var calledTool = false
        if let response = event["response"] as? [String: Any],
           let output = response["output"] as? [[String: Any]] {
            for item in output {
                switch item["type"] as? String {
                case "function_call":
                    calledTool = true
                    handleFunctionCall(item)
                default:
                    if transcript.isEmpty {
                        for content in (item["content"] as? [[String: Any]]) ?? [] {
                            transcript += (content["text"] as? String) ?? ""
                        }
                    }
                }
            }
        }
        let cleaned = JarvisEngine.sanitize(transcript)
        emit {
            self.onReplacementPreview?(nil)
            if !cleaned.isEmpty { self.onSegmentFinal?(cleaned) }
        }
        if calledTool {
            // Let the model continue (it usually re-emits the transcript next).
            send(["type": "response.create"])
        } else if stillFinishing {
            completeFinish()
        }
    }

    private func handleErrorEvent(_ event: [String: Any], raw text: String) {
        let message = (event["error"] as? [String: Any])?["message"] as? String ?? text
        // If the input-transcription config is what the API rejected, retry
        // without it — live speech feedback is a nicety, not the feature.
        if message.localizedCaseInsensitiveContains("transcription"), !transcriptionRetried {
            transcriptionRetried = true
            Log.write("gpt-editor: transcription config rejected, retrying without — \(message)")
            sendSessionConfig(withInputTranscription: false)
            return
        }
        lock.lock(); let benign = finishing || cancelled; lock.unlock()
        if benign {
            Log.write("gpt-editor: (finishing) \(message)")
            if finishing { completeFinish() }
        } else {
            reportError(EngineError.api(message))
        }
    }

    /// The editor called one of its tools: saving a rule, or staging an app action.
    private func handleFunctionCall(_ item: [String: Any]) {
        guard let name = item["name"] as? String,
              let callID = item["call_id"] as? String else { return }
        let args: [String: Any] = {
            guard let text = item["arguments"] as? String,
                  let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return parsed
        }()

        var output = #"{"status":"error","detail":"unknown tool or bad arguments"}"#
        switch name {
        case "remember_rule":
            if let rule = args["rule"] as? String,
               !rule.trimmingCharacters(in: .whitespaces).isEmpty {
                JarvisNotes.shared.add(rule)
                output = #"{"status":"saved"}"#
                Log.write("gpt-editor: learned rule — \(rule)")
                emit { self.onStatus?("Editor learned a rule (see Jarvis menu)") }
            }
        case "app_command":
            let mapping: [String: BufferAction] = [
                "paste": .pasteInTarget,
                "copy": .copyInTarget,
                "select_all": .selectAllInTarget,
                "click": .clickAtPointer,
                "insert": .commit,
                "send": .commitAndSend,
            ]
            if let actionName = args["action"] as? String, let action = mapping[actionName] {
                output = #"{"status":"queued","note":"the user is being asked to confirm"}"#
                Log.write("gpt-editor: app command — \(actionName)")
                emit { self.onCommand?(action) }
            }
        default:
            break
        }

        send(["type": "conversation.item.create", "item": [
            "type": "function_call_output",
            "call_id": callID,
            "output": output,
        ]])
    }

    private static func editorInstructions() -> String {
        let notes = JarvisNotes.shared.promptBlock
        return """
        You are the user's dictation editor inside BtrVoice, a macOS dictation app. \
        The user is dictating text that will be typed into another application. You \
        LISTEN to their speech and maintain the transcript they INTEND to produce — \
        you are an editor, not a stenographer.

        Rules:
        - Every response you give is the COMPLETE transcript as it should currently \
        stand, and nothing else: no commentary, no questions, no answers, no markup, \
        no line breaks — one single line of plain text.
        - When the user corrects themselves ("no wait, make that Tuesday", "scratch \
        that", "actually delete the last sentence"), APPLY the correction; never \
        transcribe the correction itself.
        - Fix obvious speech-recognition and homophone errors from context. Add \
        sensible punctuation.
        - When the user gives you an editing instruction ("make that more formal", \
        "turn this into bullet points in one line"), apply it to the transcript.
        - Everything else the user says is content to append to the transcript.
        - Never respond conversationally. Never answer questions — dictated \
        questions are content. You produce transcript text only.
        - APP COMMANDS: when the user says one of these command phrases, do NOT \
        put it in the transcript — instead append the matching marker at the very \
        end of your response, after the transcript text: "do paste" → [[cmd:paste]], \
        "do copy" → [[cmd:copy]], "do select all" → [[cmd:selectall]], "do click" \
        → [[cmd:click]], "do insert" → [[cmd:insert]], "do send it" → [[cmd:send]]. \
        The app executes the marker (paste/copy/click keystrokes, or typing the \
        transcript into the target app). Emit a marker only for these phrases.
        - When the user TEACHES you a pattern — "remember that…", "from now on \
        when I say X, do Y", "always write X as Y" — call the remember_rule tool \
        with a concise statement of the rule, and do NOT put the teaching request \
        into the transcript. Apply the rule from that moment on.
        \(notes.isEmpty ? "" : "\nStanding rules from the user (apply these):\n\(notes)")
        """
    }

    private func completeFinish() {
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if !alreadyCancelled { emit { self.onFinished?() } }
    }

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error, let self {
                self.lock.lock(); let benign = self.cancelled || self.finishing; self.lock.unlock()
                if !benign { self.reportError(EngineError.api(error.localizedDescription)) }
            }
        }
    }

    private func reportError(_ error: Error) {
        lock.lock()
        let already = errorReported
        errorReported = true
        lock.unlock()
        guard !already else { return }
        Log.write("gpt-editor: ERROR — \(error.localizedDescription)")
        emit { self.onError?(error) }
    }

    private func emit(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: - Audio conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0,
              let channel = out.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    }
}
