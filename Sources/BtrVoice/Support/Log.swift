import Foundation
import os

/// Logging that survives the app being launched by Finder rather than a terminal.
///
/// `NSLog` from a background accessory app is awkward to retrieve after the fact, so
/// everything also lands in a plain file you can `tail`. When something silently does
/// nothing — a hotkey that never fires, a commit into an app that ignored it — this
/// file is the record of what actually happened.
enum Log {

    static let fileURL: URL = {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("BtrVoice.log")
    }()

    private static let logger = Logger(subsystem: "com.btr.voice", category: "app")
    private static let queue = DispatchQueue(label: "com.btr.voice.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// Keeps the file from growing without bound across sessions.
    static func startSession() {
        queue.async {
            if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > 256_000 {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        write("──── launched \(Bundle.main.bundleURL.path)")
    }
}
