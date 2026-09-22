import AppKit
// The SDK exposes the immutable AX option key as a legacy mutable C global.
// Permission requests stay on the main actor; keep Swift 6 checking elsewhere.
@preconcurrency import ApplicationServices
import Foundation
import LocalAuthentication
import Security

@MainActor public enum PermissionManager {
  public static func state() -> PermissionState {
    PermissionState(screen: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
  }
  public static func requestScreen() { _ = CGRequestScreenCaptureAccess() }
  public static func requestAccessibility() {
    let options =
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
  public static func openSettings() {
    // Open the documented application, not a guessed private deep-link API.
    if let url = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.systempreferences")
    {
      NSWorkspace.shared.openApplication(
        at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
  }
  public static let instructions =
    "System Settings → Privacy & Security → Screen Recording / Accessibility. Enable Luti at its final installation path. macOS may require restarting the app."
}
public enum KeychainService {
  /// One account per secret. The Tunnel Token is the default because it is the
  /// only one that existed before OAuth; a client secret gets an account derived
  /// from its client id, so deleting a client deletes exactly its own secret.
  public static let tunnelToken = "cloudflare-tunnel-token"
  public static func clientSecret(_ clientID: String) -> String {
    "oauth-client-secret:" + clientID
  }
  private static func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Identity.keychainService,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
  }
  public static func read(account: String = tunnelToken) throws -> String? {
    var q = query(account)
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
  public static func exists(account: String = tunnelToken) -> Bool {
    var q = query(account)
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    q[kSecUseAuthenticationContext as String] = context
    return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
  }
  public static func save(_ value: String, account: String = tunnelToken) throws {
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
  public static func remove(account: String = tunnelToken) throws {
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
