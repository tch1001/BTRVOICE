/// Structured, owner-only diagnostics. Disk work stays off the interaction thread;
/// correlation IDs connect model payloads, rejected calls, AX reads and timings.
import Foundation

final class DesktopVoiceTrace {
    let directory: URL
    let sessionID: UUID
    var fileURL: URL { directory.appendingPathComponent("events.jsonl") }
    private let queue = DispatchQueue(label: "com.btr.voice.trace", qos: .utility)
    private let maximumBytes: UInt64

    init(directory: URL, sessionID: UUID, maximumBytes: UInt64 = 8_000_000) {
        self.directory = directory.appendingPathComponent("Diagnostics", isDirectory: true)
        self.sessionID = sessionID
        self.maximumBytes = maximumBytes
    }

    func record(_ event: String, turnID: UUID?, spanID: String? = nil, fields: [String: Any] = [:]) {
        let timestamp = Date()
        queue.async { [self] in
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                var record: [String: Any] = ["schema_version": 1, "at": timestamp.timeIntervalSince1970,
                    "event": event, "session_id": sessionID.uuidString,
                    "turn_id": turnID?.uuidString ?? "none", "span_id": spanID ?? UUID().uuidString,
                    "fields": Self.redacted(fields)]
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                if data.count > 256_000 {
                    record["fields"] = ["payload_truncated": true, "original_bytes": data.count,
                        "preview": String(String(decoding: data, as: UTF8.self).prefix(48_000))]
                    data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                }
                data.append(0x0A)
                let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
                if size + UInt64(data.count) > maximumBytes {
                    for index in stride(from: 2, through: 1, by: -1) {
                        let source = index == 1 ? fileURL : directory.appendingPathComponent("events.1.jsonl")
                        let destination = directory.appendingPathComponent("events.\(index).jsonl")
                        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                        if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
                    }
                }
                if !fm.fileExists(atPath: fileURL.path) {
                    guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
                let file = try FileHandle(forUpdating: fileURL)
                defer { try? file.close() }
                let end = try file.seekToEnd()
                if end > 0 {
                    try file.seek(toOffset: end - 1)
                    let tail = try file.read(upToCount: 1)
                    try file.seekToEnd()
                    if tail?.first != 0x0A { try file.write(contentsOf: Data([0x0A])) }
                }
                try file.write(contentsOf: data)
            } catch {
                Log.write("voice-trace: diagnostic write failed — \(error.localizedDescription)")
            }
        }
    }

    func flush() { queue.sync {} }

    /// No HTTP headers are passed in. Also scrub credentials embedded in model
    /// strings, URLs or tool arguments, and omit image/audio bytes altogether.
    static func redacted(_ value: Any, key: String = "") -> Any {
        let secretKeys = ["authorization", "api_key", "apikey", "access_token", "refresh_token", "password", "cookie", "set-cookie"]
        if secretKeys.contains(key.lowercased()) { return "[redacted]" }
        if ["image_url", "audio", "jpeg"].contains(key.lowercased()) { return "[media omitted]" }
        if let object = value as? [String: Any] { return object.mapValuesWithKeys { redacted($1, key: $0) } }
        if let array = value as? [Any] { return array.map { redacted($0) } }
        if var text = value as? String {
            // Function arguments arrive as JSON encoded inside a string.
            if let bytes = text.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: bytes),
               nested is [String: Any] || nested is [Any],
               let clean = try? JSONSerialization.data(withJSONObject: redacted(nested), options: [.sortedKeys]) {
                return String(decoding: clean, as: UTF8.self)
            }
            for pattern in [#"(?i)Bearer\s+[^\s\"\\]+"#, #"sk-[A-Za-z0-9_-]{12,}"#,
                            #"(?i)(?:api[_-]?key|access_token|refresh_token|password)[\"']?\s*[=:]\s*[\"']?[^\s&\"'\\]+"#,
                            #"(?i)https?://[^/\s:@]+:[^/\s@]+@"#] {
                text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
            }
            return text
        }
        return value
    }

    static func recent(directory: URL, turnID: String? = nil) -> String {
        let folder = directory.appendingPathComponent("Diagnostics")
        let files = ["events.2.jsonl", "events.1.jsonl", "events.jsonl"]
        let lines = files.flatMap { name -> [String] in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return [] }
            return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter {
                !$0.isEmpty && (turnID == nil || $0.contains(turnID!))
            }
        }
        return lines.suffix(60).joined(separator: "\n")
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
