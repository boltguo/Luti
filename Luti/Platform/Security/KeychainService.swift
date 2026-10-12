import Foundation
import LocalAuthentication
import Security

public enum KeychainService {
  /// The OpenAI runtime API key is the only stored secret.
  public static let openAIAPIKey = "openai-api-key"
  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Identity.keychainService,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
  }
  public static func read(account: String = openAIAPIKey, allowInteraction: Bool = true) throws -> String? {
    var q = query(account)
    if !allowInteraction {
      let context = LAContext()
      context.interactionNotAllowed = true
      q[kSecUseAuthenticationContext as String] = context
    }
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data,
      let text = String(data: data, encoding: .utf8)
    else { throw failure(status) }
    return text
  }
  public static func exists(account: String = openAIAPIKey) throws -> Bool {
    var q = query(account)
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    q[kSecUseAuthenticationContext as String] = context
    let status = SecItemCopyMatching(q as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw failure(status) }
    return true
  }
  public static func save(_ value: String, account: String = openAIAPIKey) throws {
    guard !value.isEmpty, value.utf8.count <= 8192,
      value.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw Failure.invalid("A stored secret must be a non-empty printable value.") }
    let bytes = Data(value.utf8)
    let status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    if status == errSecItemNotFound {
      var q = query(account)
      q[kSecValueData as String] = bytes
      let added = SecItemAdd(q as CFDictionary, nil)
      guard added == errSecSuccess else { throw failure(added) }
    } else if status != errSecSuccess {
      throw failure(status)
    }
  }
  public static func remove(account: String = openAIAPIKey) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
  }
  private static func failure(_ status: OSStatus) -> Failure {
    Failure(
      "keychain_unavailable", "Keychain access failed (status \(status)).",
      "Unlock your login keychain and keep the app's signing identity stable. No key is written to a JSON fallback."
    )
  }
}

/// Credential access for connection settings and recovery.
/// Fixtures supply an in-memory store instead of touching the login Keychain.
struct KeychainClient: Sendable {
  var read: @Sendable (String, Bool) throws -> String?
  var save: @Sendable (String, String) throws -> Void
  var remove: @Sendable (String) throws -> Void
  var exists: @Sendable (String) throws -> Bool

  static let live = KeychainClient(
    read: { try KeychainService.read(account: $0, allowInteraction: $1) },
    save: { try KeychainService.save($0, account: $1) },
    remove: { try KeychainService.remove(account: $0) },
    exists: { try KeychainService.exists(account: $0) })
  static let empty = KeychainClient(
    read: { _, _ in nil }, save: { _, _ in throw Failure.invalid("No credential store configured.") },
    remove: { _ in }, exists: { _ in false })
}
