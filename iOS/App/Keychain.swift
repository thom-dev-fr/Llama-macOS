import Foundation
import Security

/// The Hugging Face token, in the Keychain. It stays on this device: not synced
/// through iCloud Keychain, not restored onto another device from a backup.
nonisolated enum Keychain {
  private static let service = "app.llama.ios"
  private static let account = "huggingface-token"

  static var huggingFaceToken: String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func setHuggingFaceToken(_ token: String) throws {
    removeHuggingFaceToken()
    var item = baseQuery
    item[kSecValueData as String] = Data(token.utf8)
    // Readable once the device has been unlocked, so downloads resuming in the
    // background can still authenticate.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
        NSLocalizedDescriptionKey: "The token could not be saved in the Keychain (\(status)).",
      ])
    }
  }

  static func removeHuggingFaceToken() {
    SecItemDelete(baseQuery as CFDictionary)
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}
