import Foundation

/// Carries JSON events between the native Jarvis console and OpenAI Realtime.
///
/// Audio capture, playback, tool authorization, and conversation state deliberately
/// live elsewhere. This object only owns the authenticated WebSocket and reports every
/// decoded event to the console controller.
final class JarvisRealtimeSocket {
    enum SocketError: LocalizedError {
        case invalidModel
        case invalidEvent
        case closed(String)

        var errorDescription: String? {
            switch self {
            case .invalidModel:
                return "The configured Realtime model name is invalid."
            case .invalidEvent:
                return "A Realtime event could not be encoded."
            case .closed(let detail):
                return "The Realtime connection closed: \(detail)"
            }
        }
    }

    var onEvent: (([String: Any]) -> Void)?
    var onError: ((Error) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var stopped = true

    func connect(model: String, apiKey: String, safetyIdentifier: String = "") throws {
        disconnect()
        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw SocketError.invalidModel
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw SocketError.invalidModel }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !safetyIdentifier.isEmpty {
            request.setValue(safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        }
        let socket = URLSession.shared.webSocketTask(with: request)
        lock.lock()
        task = socket
        stopped = false
        lock.unlock()
        socket.resume()
        receive()
    }

    @discardableResult
    func send(_ event: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else {
            report(SocketError.invalidEvent)
            return false
        }
        lock.lock()
        let socket = stopped ? nil : task
        lock.unlock()
        guard let socket else { return false }
        socket.send(.string(text)) { [weak self] error in
            if let error { self?.report(error) }
        }
        return true
    }

    func disconnect() {
        lock.lock()
        stopped = true
        let socket = task
        task = nil
        lock.unlock()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        lock.lock()
        let socket = stopped ? nil : task
        lock.unlock()
        socket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.decode(text)
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) { self.decode(text) }
            case .failure(let error):
                self.lock.lock()
                let expected = self.stopped
                self.lock.unlock()
                if !expected { self.report(SocketError.closed(error.localizedDescription)) }
                return
            @unknown default:
                break
            }
            self.receive()
        }
    }

    private func decode(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report(SocketError.invalidEvent)
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func report(_ error: Error) {
        lock.lock()
        let expected = stopped
        lock.unlock()
        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
