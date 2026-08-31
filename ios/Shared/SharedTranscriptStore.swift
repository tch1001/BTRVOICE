// The App Group bridge for app-to-keyboard drafts and keyboard-to-app listening commands.

import Foundation
import UIKit

struct SharedTranscript: Codable, Equatable {
  let text: String
  let committedAt: Date
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
