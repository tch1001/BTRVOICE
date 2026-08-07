import Foundation

/// The user's OpenAI API key, kept in a 0600 file under Application Support —
/// out of the repo, out of UserDefaults, readable only by this user.
enum OpenAIKeyStore {

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtrVoice", isDirectory: true)
            .appendingPathComponent("openai-key")
    }

    static func read() -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static var isSet: Bool { read() != nil }

    static func write(_ key: String) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? key.trimmingCharacters(in: .whitespacesAndNewlines)
            .write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Log.write("openai: API key stored")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        Log.write("openai: API key cleared")
    }
}
