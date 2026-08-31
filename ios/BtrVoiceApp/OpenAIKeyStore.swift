// The user's OpenAI API key, stored in the iOS Keychain and never shared with the keyboard.

import Foundation
import Security

enum OpenAIKeyStore {
  private static let service = "com.tanchienhao.BtrVoice.openai"
  private static let account = "api-key"

  static var isSet: Bool { read() != nil }

  static func read() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let raw = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return key.isEmpty ? nil : key
  }

  static func write(_ rawKey: String) throws {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      clear()
      return
    }

    let data = Data(key.utf8)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw KeyStoreError.status(addStatus) }
    } else if status != errSecSuccess {
      throw KeyStoreError.status(status)
    }
  }

  static func clear() {
    SecItemDelete(baseQuery as CFDictionary)
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private enum KeyStoreError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
      switch self {
      case .status(let status):
        return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
      }
    }
  }
}
