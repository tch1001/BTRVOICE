import Combine
import Foundation

/// A small, declarative action language for voice-taught fast paths. Skills can
/// open an installed application or press a validated keyboard chord; they never
/// persist executable code or bypass the existing desktop executor.
enum DesktopVoiceSkillActionKind: String, Codable, CaseIterable, Identifiable {
    case openApplication = "open_application"
    case shortcut

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openApplication: return "Open application"
        case .shortcut: return "Keyboard shortcut"
        }
    }
}

struct DesktopVoiceSkillActionSpec: Identifiable, Codable, Equatable {
    var id: UUID
    var kind: DesktopVoiceSkillActionKind
    var value: String

    init(id: UUID = UUID(), kind: DesktopVoiceSkillActionKind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }

    var readableDescription: String {
        switch kind {
        case .openApplication: return "Open \(value)"
        case .shortcut: return "Press \(TextInjector.parseCombo(value)?.display ?? value)"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.value == rhs.value
    }
}

struct DesktopVoiceLearnedSkill: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var triggers: [String]
    var summary: String
    var actions: [DesktopVoiceSkillActionSpec]
    var createdAt: Date
    var updatedAt: Date
}

struct DesktopVoiceSkillDraft: Equatable {
    var name: String
    var triggers: [String]
    var summary: String
    var actions: [DesktopVoiceSkillActionSpec]
}

enum DesktopVoiceSkillError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Persists voice-taught fast paths in Application Support and publishes edits so
/// the command router and manager window see the same catalog immediately.
final class DesktopVoiceSkillStore: ObservableObject {
    static let shared = DesktopVoiceSkillStore()

    private struct FileState: Codable {
        var version = 1
        var skills: [DesktopVoiceLearnedSkill]
    }

    @Published private(set) var skills: [DesktopVoiceLearnedSkill] = []

    let fileURL: URL

    init(fileURL: URL = DesktopVoiceSkillStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    @discardableResult
    func add(
        _ draft: DesktopVoiceSkillDraft,
        resolveApplication: DesktopVoiceCommandRouter.ApplicationResolver
    ) throws -> DesktopVoiceLearnedSkill {
        guard skills.count < 100 else {
            throw DesktopVoiceSkillError.invalid("The learned-skill limit is 100.")
        }
        let normalized = try validated(draft, excluding: nil, resolveApplication: resolveApplication)
        let now = Date()
        let skill = DesktopVoiceLearnedSkill(
            id: UUID(),
            name: normalized.name,
            triggers: normalized.triggers,
            summary: normalized.summary,
            actions: normalized.actions,
            createdAt: now,
            updatedAt: now
        )
        let previous = skills
        skills.append(skill)
        do {
            try persist()
        } catch {
            skills = previous
            throw error
        }
        return skill
    }

    func update(
        _ skill: DesktopVoiceLearnedSkill,
        resolveApplication: DesktopVoiceCommandRouter.ApplicationResolver
    ) throws {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else {
            throw DesktopVoiceSkillError.invalid("That learned skill no longer exists.")
        }
        let draft = DesktopVoiceSkillDraft(
            name: skill.name,
            triggers: skill.triggers,
            summary: skill.summary,
            actions: skill.actions
        )
        let normalized = try validated(draft, excluding: skill.id, resolveApplication: resolveApplication)
        let previous = skills
        skills[index].name = normalized.name
        skills[index].triggers = normalized.triggers
        skills[index].summary = normalized.summary
        skills[index].actions = normalized.actions
        skills[index].updatedAt = Date()
        do {
            try persist()
        } catch {
            skills = previous
            throw error
        }
    }

    func delete(id: UUID) throws {
        let previous = skills
        skills.removeAll { $0.id == id }
        do {
            try persist()
        } catch {
            skills = previous
            throw error
        }
    }

    func matching(_ utterance: String) -> DesktopVoiceLearnedSkill? {
        let command = DesktopVoiceCommandRouter.normalized(utterance)
        return skills.first { skill in
            skill.triggers.contains { DesktopVoiceCommandRouter.normalized($0) == command }
        }
    }

    static func plan(
        for skill: DesktopVoiceLearnedSkill,
        resolveApplication: DesktopVoiceCommandRouter.ApplicationResolver
    ) throws -> DesktopVoicePlan {
        let actions = try skill.actions.map { action -> DesktopVoiceAction in
            switch action.kind {
            case .openApplication:
                guard let application = resolveApplication(action.value) else {
                    throw DesktopVoiceSkillError.invalid("I couldn't find \(action.value) for the learned skill “\(skill.name)”.")
                }
                return .openApplication(application)
            case .shortcut:
                guard TextInjector.parseCombo(action.value) != nil else {
                    throw DesktopVoiceSkillError.invalid("The learned shortcut \(action.value) is no longer valid.")
                }
                return .pressShortcut(action.value)
            }
        }
        return DesktopVoicePlan(summary: skill.summary, actions: actions)
    }

    private func validated(
        _ draft: DesktopVoiceSkillDraft,
        excluding id: UUID?,
        resolveApplication: DesktopVoiceCommandRouter.ApplicationResolver
    ) throws -> DesktopVoiceSkillDraft {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw DesktopVoiceSkillError.invalid("Give the skill a name of at most 80 characters.")
        }

        var seen: Set<String> = []
        let triggers = draft.triggers.compactMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = DesktopVoiceCommandRouter.normalized(trimmed)
            guard !normalized.isEmpty, trimmed.count <= 120, seen.insert(normalized).inserted else { return nil }
            return trimmed
        }
        guard !triggers.isEmpty, triggers.count <= 8 else {
            throw DesktopVoiceSkillError.invalid("A skill needs between one and eight distinct voice phrases.")
        }
        let occupied = Set(skills.filter { $0.id != id }.flatMap(\.triggers).map(DesktopVoiceCommandRouter.normalized))
        if let duplicate = triggers.first(where: { occupied.contains(DesktopVoiceCommandRouter.normalized($0)) }) {
            throw DesktopVoiceSkillError.invalid("“\(duplicate)” is already used by another learned skill.")
        }

        guard !draft.actions.isEmpty, draft.actions.count <= 8 else {
            throw DesktopVoiceSkillError.invalid("A skill needs between one and eight actions.")
        }
        var actions: [DesktopVoiceSkillActionSpec] = []
        for var action in draft.actions {
            action.value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.value.isEmpty, action.value.count <= 120 else {
                throw DesktopVoiceSkillError.invalid("Every action needs a short value.")
            }
            switch action.kind {
            case .openApplication:
                guard resolveApplication(action.value) != nil else {
                    throw DesktopVoiceSkillError.invalid("I couldn't find an installed application called \(action.value).")
                }
            case .shortcut:
                guard TextInjector.parseCombo(action.value) != nil else {
                    throw DesktopVoiceSkillError.invalid("\(action.value) is not a supported keyboard shortcut.")
                }
            }
            actions.append(action)
        }

        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesktopVoiceSkillDraft(
            name: name,
            triggers: triggers,
            summary: summary.isEmpty ? name : String(summary.prefix(160)),
            actions: actions
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            skills = try decoder.decode(FileState.self, from: data).skills
        } catch {
            Log.write("desktop-voice: could not read learned skills: \(error.localizedDescription)")
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(FileState(skills: skills))
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BtrVoice", isDirectory: true)
            .appendingPathComponent("desktop-voice-skills.json")
    }
}
