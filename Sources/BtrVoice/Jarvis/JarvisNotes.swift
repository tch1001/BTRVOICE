import Foundation

/// One thing the user told Jarvis to remember.
struct JarvisNote: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
    }
}

/// Jarvis's persistent memory. Every note is injected into every Jarvis prompt,
/// so "remember that github dot com means tch1001.github.io" becomes a standing
/// rule the model applies from then on. Stored as plain JSON the user can inspect.
final class JarvisNotes: ObservableObject {
    static let shared = JarvisNotes()

    @Published private(set) var notes: [JarvisNote] = []

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtrVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("jarvis-notes.json")
        load()
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.append(JarvisNote(text: trimmed))
        save()
        Log.write("jarvis: remembered — \(trimmed)")
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        save()
        Log.write("jarvis: forgot note \(id)")
    }

    func deleteAll() {
        notes.removeAll()
        save()
        Log.write("jarvis: forgot all notes")
    }

    /// The notes as a block for the model prompt, oldest first.
    var promptBlock: String {
        guard !notes.isEmpty else { return "" }
        return notes.map { "- \($0.text)" }.joined(separator: "\n")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([JarvisNote].self, from: data) else { return }
        notes = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
