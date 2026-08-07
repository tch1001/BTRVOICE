import Foundation

/// One thing the user taught Jarvis / the GPT Editor. Rules are versioned:
/// editing a rule bumps `version` and keeps the superseded text in `history`,
/// so "actually, make that rule say…" revises in place instead of piling up
/// near-duplicates.
struct JarvisNote: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var version: Int
    /// Superseded texts, oldest first. Capped.
    var history: [String]

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.updatedAt = self.createdAt
        self.version = 1
        self.history = []
    }

    // Notes saved before versioning existed lack the new fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        history = try container.decodeIfPresent([String].self, forKey: .history) ?? []
    }
}

/// Persistent memory shared by Jarvis and the GPT Editor. Every rule is
/// injected (numbered) into every prompt; stored as plain JSON.
final class JarvisNotes: ObservableObject {
    static let shared = JarvisNotes()

    @Published private(set) var notes: [JarvisNote] = []

    private let fileURL: URL
    private let historyCap = 10

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

    /// Revises rule number `number` (1-based, as shown in prompts and the UI).
    /// Returns the new version, or nil if the number doesn't exist.
    @discardableResult
    func update(number: Int, text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = number - 1
        guard !trimmed.isEmpty, notes.indices.contains(index) else { return nil }
        notes[index].history.append(notes[index].text)
        if notes[index].history.count > historyCap {
            notes[index].history.removeFirst(notes[index].history.count - historyCap)
        }
        notes[index].text = trimmed
        notes[index].version += 1
        notes[index].updatedAt = Date()
        save()
        Log.write("jarvis: rule #\(number) updated to v\(notes[index].version) — \(trimmed)")
        return notes[index].version
    }

    /// UI-side revision of a rule; same versioning as the model's update_rule.
    @discardableResult
    func update(id: UUID, text: String) -> Int? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        return update(number: index + 1, text: text)
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

    /// Numbered for the model, so update_rule can reference "rule 2".
    var promptBlock: String {
        guard !notes.isEmpty else { return "" }
        return notes.enumerated()
            .map { "\($0.offset + 1). (v\($0.element.version)) \($0.element.text)" }
            .joined(separator: "\n")
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
