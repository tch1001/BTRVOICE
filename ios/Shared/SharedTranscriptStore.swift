// The App Group bridge for app-to-keyboard drafts and keyboard-to-app listening commands.

import Foundation
import UIKit

struct SharedTranscript: Codable, Equatable {
  let text: String
  let committedAt: Date
}

struct SharedInsertionHistoryEntry: Codable, Equatable, Identifiable {
  let id: UUID
  let text: String
  let insertedAt: Date
}

private struct SharedInsertionHistory: Codable {
  let version: Int
  var entries: [SharedInsertionHistoryEntry]
}

struct SharedLiveDraft: Codable, Equatable {
  let text: String
  let isListening: Bool
  let updatedAt: Date
  let heardText: String?
  let isProcessing: Bool?
  let supportsGating: Bool?

  var rawHeardText: String { heardText ?? "" }
  var processingEnabled: Bool { isProcessing ?? isListening }
  var canGateProcessing: Bool { supportsGating ?? false }
}

enum SharedKeyboardAction: String, Codable {
  case clearDraft
  case startProcessing
  case stopProcessing
  case finishDraft
}

struct SharedKeyboardCommand: Codable, Equatable {
  let id: UUID
  let action: SharedKeyboardAction
  let createdAt: Date
}

enum SharedTranscriptStore {
  static let appGroupID = "group.com.tanchienhao.BtrVoice"
  static let insertionHistoryLimit = 100

  private enum Key {
    static let text = "latestCommittedTranscript"
    static let committedAt = "latestCommittedTranscriptDate"
  }

  private static var sharedFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent("latest-transcript.json", isDirectory: false)
  }

  private static var liveDraftFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent("live-draft.json", isDirectory: false)
  }

  private static var keyboardCommandFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent("keyboard-command.json", isDirectory: false)
  }

  private static var insertionHistoryFileURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent("insertion-history.json", isDirectory: false)
  }

  @discardableResult
  static func save(_ rawText: String) -> SharedTranscript? {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !text.isEmpty,
      let sharedFileURL,
      let data = try? JSONEncoder().encode(SharedTranscript(text: text, committedAt: Date())),
      (try? data.write(to: sharedFileURL, options: .atomic)) != nil
    else {
      return nil
    }

    let transcript = (try? JSONDecoder().decode(SharedTranscript.self, from: data))
      ?? SharedTranscript(text: text, committedAt: Date())

    // Keep a preferences mirror for migration and easier diagnostics. The file in the
    // App Group container is authoritative because it is reliably visible cross-process.
    let defaults = UserDefaults(suiteName: appGroupID)
    defaults?.set(transcript.text, forKey: Key.text)
    defaults?.set(transcript.committedAt, forKey: Key.committedAt)
    defaults?.synchronize()

    // This is an explicit user commit. Keeping the same text on the clipboard gives
    // locally-installed builds a useful fallback when App Group provisioning is absent.
    UIPasteboard.general.string = transcript.text
    return transcript
  }

  static func load() -> SharedTranscript? {
    if
      let sharedFileURL,
      let data = try? Data(contentsOf: sharedFileURL),
      let transcript = try? JSONDecoder().decode(SharedTranscript.self, from: data),
      !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return transcript
    }

    guard
      let defaults = UserDefaults(suiteName: appGroupID),
      let text = defaults.string(forKey: Key.text)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !text.isEmpty
    else {
      return nil
    }

    return SharedTranscript(
      text: text,
      committedAt: defaults.object(forKey: Key.committedAt) as? Date ?? .distantPast
    )
  }

  static func clearCommittedTranscript() {
    if let sharedFileURL { try? FileManager.default.removeItem(at: sharedFileURL) }
    let defaults = UserDefaults(suiteName: appGroupID)
    defaults?.removeObject(forKey: Key.text)
    defaults?.removeObject(forKey: Key.committedAt)
    defaults?.synchronize()
  }

  /// Records an explicit keyboard insertion before it is sent to the target app.
  /// Keeping this separate from `save` means committing an edited draft does not
  /// claim that the text was actually inserted.
  @discardableResult
  static func recordInsertion(_ rawText: String) -> SharedInsertionHistoryEntry? {
    recordInsertion(rawText, at: Date(), to: insertionHistoryFileURL)
  }

  static func loadInsertionHistory() -> [SharedInsertionHistoryEntry] {
    loadInsertionHistory(from: insertionHistoryFileURL)
  }

  static func deleteInsertionHistoryEntry(id: UUID) {
    guard let insertionHistoryFileURL else { return }
    var entries = loadInsertionHistory(from: insertionHistoryFileURL)
    entries.removeAll { $0.id == id }
    writeInsertionHistory(entries, to: insertionHistoryFileURL)
  }

  static func clearInsertionHistory() {
    guard let insertionHistoryFileURL else { return }
    try? FileManager.default.removeItem(at: insertionHistoryFileURL)
  }

  // File-injected variants keep persistence behavior testable without requiring
  // an App Group container in the unit-test host.
  @discardableResult
  static func recordInsertion(
    _ rawText: String,
    at insertedAt: Date,
    to fileURL: URL?
  ) -> SharedInsertionHistoryEntry? {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let fileURL else { return nil }

    let entry = SharedInsertionHistoryEntry(id: UUID(), text: text, insertedAt: insertedAt)
    var entries = loadInsertionHistory(from: fileURL)
    entries.insert(entry, at: 0)
    if entries.count > insertionHistoryLimit {
      entries.removeLast(entries.count - insertionHistoryLimit)
    }
    guard writeInsertionHistory(entries, to: fileURL) else { return nil }
    return entry
  }

  static func loadInsertionHistory(from fileURL: URL?) -> [SharedInsertionHistoryEntry] {
    guard
      let fileURL,
      let data = try? Data(contentsOf: fileURL),
      let history = try? JSONDecoder().decode(SharedInsertionHistory.self, from: data),
      history.version == 1
    else {
      return []
    }
    return history.entries
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted { $0.insertedAt > $1.insertedAt }
  }

  @discardableResult
  static func writeInsertionHistory(
    _ entries: [SharedInsertionHistoryEntry],
    to fileURL: URL
  ) -> Bool {
    if entries.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
      return true
    }

    guard
      let data = try? JSONEncoder().encode(
        SharedInsertionHistory(version: 1, entries: Array(entries.prefix(insertionHistoryLimit)))
      )
    else {
      return false
    }

    do {
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
      return true
    } catch {
      return false
    }
  }

  static func clearLiveDraft() {
    if let liveDraftFileURL { try? FileManager.default.removeItem(at: liveDraftFileURL) }
  }

  /// Publishes the in-progress buffer for the keyboard to preview. This never
  /// inserts text or touches the clipboard; insertion remains an explicit tap
  /// inside the keyboard extension.
  static func updateLiveDraft(
    _ rawText: String,
    heardText: String = "",
    isListening: Bool,
    isProcessing: Bool,
    supportsGating: Bool
  ) {
    guard
      let liveDraftFileURL,
      let data = try? JSONEncoder().encode(
        SharedLiveDraft(
          text: rawText,
          isListening: isListening,
          updatedAt: Date(),
          heardText: heardText,
          isProcessing: isProcessing,
          supportsGating: supportsGating
        )
      )
    else {
      return
    }

    do {
      try data.write(to: liveDraftFileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: liveDraftFileURL.path
      )
    } catch {
      // The App Group may be unavailable in an unsigned preview. The normal
      // device build has the entitlement and will take this path successfully.
    }
  }

  static func loadLiveDraft() -> SharedLiveDraft? {
    guard
      let liveDraftFileURL,
      let data = try? Data(contentsOf: liveDraftFileURL),
      let draft = try? JSONDecoder().decode(SharedLiveDraft.self, from: data)
    else {
      return nil
    }
    return draft
  }

  static func postKeyboardCommand(_ action: SharedKeyboardAction) {
    guard
      let keyboardCommandFileURL,
      let data = try? JSONEncoder().encode(
        SharedKeyboardCommand(id: UUID(), action: action, createdAt: Date())
      )
    else {
      return
    }
    try? data.write(to: keyboardCommandFileURL, options: .atomic)
  }

  static func loadKeyboardCommand() -> SharedKeyboardCommand? {
    guard
      let keyboardCommandFileURL,
      let data = try? Data(contentsOf: keyboardCommandFileURL)
    else {
      return nil
    }
    return try? JSONDecoder().decode(SharedKeyboardCommand.self, from: data)
  }
}
