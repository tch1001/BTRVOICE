import Combine
import Foundation

/// A durable recovery log of text the user explicitly asked BtrVoice to insert.
/// Drafts and live partial recognition never enter this store: its contents are
/// limited to the exact finalized text that crossed an Insert boundary.
struct InsertionHistoryEntry: Identifiable, Codable, Equatable {
    enum Action: String, Codable {
        case insert
        case insertAndSend

        var label: String {
            switch self {
            case .insert: return "Insert"
            case .insertAndSend: return "Insert & Send"
            }
        }
    }

    let id: UUID
    let text: String
    let createdAt: Date
    let targetName: String?
    let action: Action

    var sendsAfterInsertion: Bool { action == .insertAndSend }
}

/// Persists recent insertion boundaries in Application Support so a failed or
/// misdirected commit can be recovered after the app—or the Mac—restarts.
final class InsertionHistoryStore: ObservableObject {
    static let shared = InsertionHistoryStore()
    static let defaultMaximumEntries = 100

    private struct FileState: Codable {
        var version = 1
        var entries: [InsertionHistoryEntry]
    }

    @Published private(set) var entries: [InsertionHistoryEntry] = []

    let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL = InsertionHistoryStore.defaultFileURL,
        maximumEntries: Int = InsertionHistoryStore.defaultMaximumEntries
    ) {
        self.fileURL = fileURL
        self.maximumEntries = max(1, maximumEntries)
        load()
    }

    @discardableResult
    func record(
        text: String,
        targetName: String?,
        send: Bool,
        at date: Date = Date()
    ) -> InsertionHistoryEntry? {
        guard !text.isEmpty else { return nil }
        let entry = InsertionHistoryEntry(
            id: UUID(),
            text: text,
            createdAt: date,
            targetName: targetName,
            action: send ? .insertAndSend : .insert
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries {
            entries.removeSubrange(maximumEntries..<entries.count)
        }
        do {
            try persist()
        } catch {
            // Keep the in-memory copy: immediate recovery is more valuable than
            // discarding it merely because persistence failed this time.
            Log.write("history: could not save insertion — \(error.localizedDescription)")
        }
        return entry
    }

    func clear() throws {
        let previous = entries
        entries.removeAll()
        do {
            try persist()
        } catch {
            entries = previous
            throw error
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(FileState.self, from: data)
            entries = Array(
                decoded.entries
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(maximumEntries)
            )
        } catch {
            Log.write("history: could not read insertion history — \(error.localizedDescription)")
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(FileState(entries: entries)).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtrVoice", isDirectory: true)
            .appendingPathComponent("insertion-history.json")
    }
}
