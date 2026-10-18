import Foundation
import Security

struct QFKeychainStore {
  let service: String

  func read(_ account: String) throws -> Data? {
    var query = baseQuery(account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw QFKeychainError(status: status) }
    guard let data = result as? Data else { throw QFKeychainError(status: errSecDecode) }
    return data
  }

  func write(_ data: Data, account: String) throws {
    let query = baseQuery(account)
    let changes: [CFString: Any] = [
      kSecValueData: data,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
    if status == errSecItemNotFound {
      let addition = query.merging(changes) { _, new in new }
      let inserted = SecItemAdd(addition as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw QFKeychainError(status: inserted) }
    } else if status != errSecSuccess {
      throw QFKeychainError(status: status)
    }
  }

  func remove(_ account: String) throws {
    let status = SecItemDelete(baseQuery(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw QFKeychainError(status: status)
    }
  }

  private func baseQuery(_ account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
  }
}

struct QFKeychainError: Error {
  let status: OSStatus
}

enum QFCredentialError: Error {
  case invalidStoredCredential
}

enum QFCredentials {
  static func generate() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw QFKeychainError(status: status) }
    return encode(Data(bytes))
  }

  static func isValid(_ text: String) -> Bool {
    guard text.utf8.count == 43,
      let data = Data(
        base64Encoded: text.replacingOccurrences(of: "-", with: "+")
          .replacingOccurrences(of: "_", with: "/") + "=")
    else { return false }
    return data.count == 32 && encode(data) == text
  }

  private static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

/// Main-actor ownership prevents concurrent first requests from generating competing identities.
@MainActor
final class QFDeviceIdentity {
  private let keychain: QFKeychainStore
  init(service: String = "com.talka.qiafanyoupu.device") {
    keychain = QFKeychainStore(service: service)
  }

  func deviceID() throws -> String {
    if let data = try keychain.read("device-id"), let value = String(data: data, encoding: .utf8),
      UUID(uuidString: value) != nil
    {
      return value
    }
    let value = UUID().uuidString.lowercased()
    try keychain.write(Data(value.utf8), account: "device-id")
    return value
  }

  func credential(environment: String) throws -> String {
    let key = "credential-\(environment)"
    if let data = try keychain.read(key) {
      guard let value = String(data: data, encoding: .utf8), QFCredentials.isValid(value) else {
        throw QFCredentialError.invalidStoredCredential
      }
      return value
    }
    let value = try QFCredentials.generate()
    // Persist before the first network request; a failed request must reuse this credential.
    try keychain.write(Data(value.utf8), account: key)
    return value
  }

  /// Remove quick-login material only after the server confirms account erasure.
  func forgetDeletedAccount(environment: String) throws {
    try keychain.remove("credential-\(environment)")
    try keychain.remove("device-id")
  }
}
