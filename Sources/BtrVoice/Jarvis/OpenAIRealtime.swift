import Foundation

/// One-shot text request to an OpenAI Realtime model (gpt-realtime-2.1) over
/// WebSocket: open, configure a text-only session, send the prompt, collect the
/// streamed reply, close. Used as Jarvis's cloud brain.
enum OpenAIRealtimeText {

    enum OpenAIError: LocalizedError {
        case noKey
        case api(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .noKey: return "No OpenAI API key set (Jarvis menu → Set OpenAI API Key)."
            case .api(let message): return "OpenAI: \(message)"
            case .timeout: return "OpenAI timed out."
            }
        }
    }

    static func respond(
        instructions: String,
        prompt: String,
        model: String = "gpt-realtime-2.1",
        timeout: TimeInterval = 45
    ) async throws -> String {
        guard let key = OpenAIKeyStore.read() else { throw OpenAIError.noKey }

        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        func send(_ event: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: event)
            try await task.send(.string(String(data: data, encoding: .utf8)!))
        }

        var reply = ""
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try await task.receive() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0.1, deadline.timeIntervalSinceNow) * 1_000_000_000))
                    return nil
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            guard case .string(let text) = message else {
                if message == nil { throw OpenAIError.timeout }
                continue
            }
            guard let data = text.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "session.created":
                try await send(["type": "session.update", "session": [
                    "type": "realtime",
                    "output_modalities": ["text"],
                    "instructions": instructions,
                ]])
                try await send(["type": "conversation.item.create", "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": prompt]],
                ]])
                try await send(["type": "response.create"])
            case "response.output_text.delta", "response.text.delta":
                reply += (event["delta"] as? String) ?? ""
            case "response.done":
                if reply.isEmpty {
                    // Fallback: dig the text out of the completed response object.
                    if let response = event["response"] as? [String: Any],
                       let output = response["output"] as? [[String: Any]] {
                        for item in output {
                            for content in (item["content"] as? [[String: Any]]) ?? [] {
                                reply += (content["text"] as? String) ?? ""
                            }
                        }
                    }
                }
                return reply
            case "error":
                let detail = (event["error"] as? [String: Any])?["message"] as? String ?? text
                throw OpenAIError.api(detail)
            default:
                break
            }
        }
        throw OpenAIError.timeout
    }
}
