import Foundation

/// A client for the jarvis daemon's bus — the unix socket at `~/.jarvis/run/jarvisd.sock`.
///
/// This is what makes BtrVoice a *surface* for the fleet's Jarvis rather than a client
/// of some HTTP API: the protocol is the same newline-delimited JSON every jarvis
/// plugin speaks, so the app appears on the bus as `btrvoice` exactly the way the
/// Telegram surface appears as `telegram`. No token, no port — the socket is uid-gated,
/// which is the bus's whole authentication story.
///
/// Deliberately not a `provide`r: BtrVoice offers nothing to the fleet yet, it only
/// calls (`llm.chat`) and listens (`llm.progress`, so long turns narrate themselves
/// instead of looking hung).
final class JarvisBusClient {

    enum BusError: LocalizedError {
        case notRunning
        case closed
        case timeout(String)
        case remote(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "Jarvis isn't running on this Mac (no daemon socket). Is jarvisd up?"
            case .closed:
                return "the Jarvis daemon closed the connection"
            case .timeout(let method):
                return "\(method) did not answer in time"
            case .remote(let code, let message):
                return "\(code): \(message)"
            }
        }
    }

    /// Where the daemon listens. Mirrors `jarvis_proto::bus::socket_path`.
    static func socketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["JARVIS_SOCKET"], !explicit.isEmpty { return explicit }
        let home = env["JARVIS_HOME"] ?? (NSHomeDirectory() + "/.jarvis")
        return home + "/run/jarvisd.sock"
    }

    /// Called on the main thread with each `llm.progress` note while a turn runs.
    var onProgress: ((String) -> Void)?
    /// The node's name from the welcome frame, once connected ("mac").
    private(set) var nodeName = ""

    private var fd: Int32 = -1
    /// Writes and timeouts. The read loop lives on its own queue below — it blocks in
    /// `read(2)` for the life of the connection, and the first version put both on one
    /// serial queue, where the loop silently starved every frame this client ever
    /// tried to send. The daemon saw a client that connected and never spoke.
    private let io = DispatchQueue(label: "jarvis.bus.io")
    private let reading = DispatchQueue(label: "jarvis.bus.read")
    private var nextId = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private let stateLock = NSLock()
    private var readBuffer = Data()

    var isConnected: Bool { fd >= 0 }

    // MARK: - Connection

    /// Connects, consumes the welcome, says hello, subscribes to progress. Synchronous
    /// and quick — the daemon answers a welcome immediately or the socket is dead.
    func connect() throws {
        guard fd < 0 else { return }
        let path = Self.socketPath()
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw BusError.notRunning }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                guard path.utf8.count < raw.count else { return false }
                raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: cstr, count: path.utf8.count + 1)
                return true
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = ok && withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, size) == 0
            }
        }
        guard connected else {
            close(sock)
            throw BusError.notRunning
        }
        fd = sock

        reading.async { [weak self] in self?.readLoop(sock) }
        send(["t": "hello", "name": "btrvoice"])
        send(["t": "subscribe", "topics": ["llm.progress"]])
    }

    func disconnect() {
        stateLock.lock()
        let sock = fd
        fd = -1
        let waiting = pending
        pending.removeAll()
        stateLock.unlock()
        if sock >= 0 { close(sock) }
        for (_, completion) in waiting {
            DispatchQueue.main.async { completion(.failure(BusError.closed)) }
        }
    }

    // MARK: - Calling

    /// Calls a bus method; the completion arrives on the main thread. The generous
    /// default exists because an orchestrator turn runs a whole agent — minutes are
    /// normal, and a surface that gives up first shows an error for a turn that then
    /// completes without it.
    func call(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 240,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        stateLock.lock()
        nextId += 1
        let id = nextId
        pending[id] = completion
        stateLock.unlock()

        send(["t": "call", "id": id, "target": "self", "method": method, "params": params])

        io.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let waiting = self.pending.removeValue(forKey: id)
            self.stateLock.unlock()
            if let waiting {
                DispatchQueue.main.async { waiting(.failure(BusError.timeout(method))) }
            }
        }
    }

    // MARK: - Wire

    private func send(_ frame: [String: Any]) {
        io.async { [weak self] in
            guard let self, self.fd >= 0,
                  var data = try? JSONSerialization.data(withJSONObject: frame) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(self.fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }
    }

    private func readLoop(_ sock: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sock, &chunk, chunk.count)
            if n <= 0 { break }
            readBuffer.append(contentsOf: chunk[0..<n])
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                if let frame = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] {
                    handle(frame)
                }
            }
        }
        disconnect()
    }

    private func handle(_ frame: [String: Any]) {
        switch frame["t"] as? String {
        case "welcome":
            nodeName = frame["node_name"] as? String ?? ""
        case "result":
            guard let id = frame["id"] as? Int else { return }
            stateLock.lock()
            let completion = pending.removeValue(forKey: id)
            stateLock.unlock()
            guard let completion else { return }
            if let error = frame["error"] as? [String: Any] {
                let code = error["code"] as? String ?? "error"
                let message = error["message"] as? String ?? ""
                DispatchQueue.main.async {
                    completion(.failure(BusError.remote(code: code, message: message)))
                }
            } else {
                let ok = frame["ok"] as? [String: Any] ?? [:]
                DispatchQueue.main.async { completion(.success(ok)) }
            }
        case "event":
            if frame["topic"] as? String == "llm.progress",
               let note = (frame["payload"] as? [String: Any])?["note"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onProgress?(note) }
            }
        default:
            // Unknown frame kinds are ignored on purpose, exactly as the Python client
            // does: a newer daemon must be able to add one without breaking us.
            break
        }
    }
}
