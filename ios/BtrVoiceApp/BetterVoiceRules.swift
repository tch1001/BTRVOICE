// Persistent, versioned editing rules taught to the Better Voice listening editor.

import Foundation

struct BetterVoiceRule: Codable, Identifiable, Equatable {
  let id: UUID
  var text: String
  let createdAt: Date
  var updatedAt: Date
  var version: Int
  var history: [String]

  init(text: String) {
    id = UUID()
    self.text = text
    createdAt = Date()
    updatedAt = createdAt
    version = 1
    history = []
  }

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

@MainActor
final class BetterVoiceRules: ObservableObject {
  static let shared = BetterVoiceRules()

  @Published private(set) var rules: [BetterVoiceRule] = []

  private let fileURL: URL
  private let historyLimit = 10

  private init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BetterVoice", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    fileURL = support.appendingPathComponent("editor-rules.json")
    load()
  }

  func add(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    rules.append(BetterVoiceRule(text: text))
    save()
  }

  @discardableResult
  func update(number: Int, text rawText: String) -> Int? {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let index = number - 1
    guard !text.isEmpty, rules.indices.contains(index) else { return nil }

    rules[index].history.append(rules[index].text)
    if rules[index].history.count > historyLimit {
      rules[index].history.removeFirst(rules[index].history.count - historyLimit)
    }
    rules[index].text = text
    rules[index].updatedAt = Date()
    rules[index].version += 1
    save()
    return rules[index].version
  }

  func update(id: UUID, text: String) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    update(number: index + 1, text: text)
  }

  func delete(id: UUID) {
    rules.removeAll { $0.id == id }
    save()
  }

  func deleteAll() {
    rules.removeAll()
    save()
  }

  var promptBlock: String {
    rules.enumerated()
      .map { "\($0.offset + 1). (v\($0.element.version)) \($0.element.text)" }
      .joined(separator: "\n")
  }

  private func load() {
    guard
      let data = try? Data(contentsOf: fileURL),
      let decoded = try? JSONDecoder().decode([BetterVoiceRule].self, from: data)
    else {
      return
    }
    rules = decoded
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(rules) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
