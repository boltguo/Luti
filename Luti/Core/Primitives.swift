import Foundation

public enum Identity {
  public static let name = "Luti"
  public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
  public static let bundleID = "com.aouos.luti"
  public static let keychainService = "com.aouos.luti.tunnel"
}
public struct Failure: Error, LocalizedError, Sendable, Equatable {
  public let code: String
  public let message: String
  public let recovery: String
  public let effect: String?
  public init(_ code: String, _ message: String, _ recovery: String, effect: String? = nil) {
    self.code = code
    self.message = message
    self.recovery = recovery
    self.effect = effect
  }
  public var errorDescription: String? { "\(message)\n\(recovery)" }
  public var json: JSONValue {
    var value: JSONValue = [
      "error": .string(code), "message": .string(message), "recovery": .string(recovery),
    ]
    if let effect { value = value.adding("effect", .string(effect)) }
    return value
  }
  public static func invalid(_ text: String) -> Failure {
    Failure(
      "invalid_arguments", text,
      "Read the tool schema and correct the input; do not repeat it unchanged.")
  }
  public static let stopped = Failure(
    "runtime_stopped", "The runtime is stopped.",
    "Start Luti with the intended project selected.")
  public static func safe(_ error: Error) -> Failure {
    (error as? Failure)
      ?? Failure(
        "native_operation_failed", "The native operation failed.",
        "Check local permissions and the target. Re-observe before retrying an action.")
  }
}
public enum Budget {
  public static func prefix(_ text: String, bytes: Int) -> String {
    guard bytes > 0 else { return "" }
    if text.utf8.count <= bytes { return text }
    var data = Array(text.utf8.prefix(bytes))
    while !data.isEmpty && String(bytes: data, encoding: .utf8) == nil { data.removeLast() }
    return String(bytes: data, encoding: .utf8) ?? ""
  }
  public static func sha256(_ data: Data) -> String {
    digest(data).map { String(format: "%02x", $0) }.joined()
  }
  /// The raw digest. PKCE compares base64url of these 32 bytes, not of their hex
  /// spelling, so the two forms are kept separate rather than reconstructed.
  public static func digest(_ data: Data) -> [UInt8] {
    precondition(data.count <= 67_108_864)
    var digest = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { raw in
      mc_sha256(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &digest)
    }
    return digest
  }
  public static func token() -> String {
    var random = SystemRandomNumberGenerator()
    return (0..<32).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &random))
    }.joined()
  }
  public static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
  }
}
public struct Redactor: Sendable {
  private let known: [String]
  public init(known: [String] = []) { self.known = known.filter { !$0.isEmpty } }
  public func clean(_ source: String) -> String {
    var value = source
    for secret in known { value = value.replacingOccurrences(of: secret, with: "[REDACTED]") }
    for pattern in [
      #"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})\b"#,
      // Quoted JSON/YAML keys and quoted values must be removed as a unit.
      // The old token=value pattern missed {"access_token": "..."} entirely.
      #"(?i)["']?(?:authorization|proxy-authorization|cookie|set-cookie)["']?\s*[:=]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n]+)"#,
      #"(?i)["']?(?:api[_-]?key|(?:access[_-]?|refresh[_-]?|client[_-]?|id[_-]?|auth[_-]?|tunnel[_-]?)?(?:secret|password|token|credential))["']?\s*[:=]\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}&\]]+)"#,
      #"(?i)--(?:api[_-]?key|secret|password|token|credential)(?:=|\s+)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s]+)"#,
      #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#,
      #"(?i)https?://[^\s/@]+:[^\s/@]+@"#,
      #"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)"#,
      #"\x1b\[[0-?]*[ -/]*[@-~]"#,
    ] {
      if let re = try? NSRegularExpression(pattern: pattern) {
        value = re.stringByReplacingMatches(
          in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[REDACTED]")
      }
    }
    return value
  }
}
public struct ToolOutput: Sendable {
  public let data: JSONValue
  public let extraContent: [JSONValue]
  public let isError: Bool
  public init(_ data: JSONValue, content: [JSONValue] = [], isError: Bool = false) {
    self.data = data
    self.extraContent = content
    self.isError = isError
  }
  public static func failure(_ failure: Failure) -> Self { Self(failure.json, isError: true) }
  public var mcp: JSONValue {
    // Text fallback is intentional for clients that hide structuredContent.
    [
      "structuredContent": data, "isError": .bool(isError),
      "content": .array([["type": "text", "text": .string(data.text())]] + extraContent),
    ]
  }
}
public struct PermissionState: Sendable, Equatable {
  public let screen: Bool
  public let accessibility: Bool
  public init(screen: Bool, accessibility: Bool) {
    self.screen = screen
    self.accessibility = accessibility
  }
  public var json: JSONValue {
    ["screenRecording": .bool(screen), "accessibility": .bool(accessibility)]
  }
}
public protocol ComputerBackend: Sendable {
  func permissions() async -> PermissionState
  func observe(_ args: JSONValue) async throws -> ToolOutput
  func wait(_ args: JSONValue) async throws -> ToolOutput
  func action(_ args: JSONValue) async throws -> ToolOutput
  func stop() async
}
public actor NoComputerBackend: ComputerBackend {
  public init() {}
  public func permissions() -> PermissionState {
    PermissionState(screen: false, accessibility: false)
  }
  public func observe(_ args: JSONValue) throws -> ToolOutput {
    throw Failure(
      "screen_permission_missing", "Native screen capture is unavailable on this test host.",
      "Run the Luti app on macOS and grant Screen Recording.")
  }
  public func wait(_ args: JSONValue) throws -> ToolOutput {
    throw Failure(
      "computer_wait_unavailable", "Native desktop waiting is unavailable on this test host.",
      "Run the Luti app on macOS to wait for real window or Accessibility state.")
  }
  public func action(_ args: JSONValue) throws -> ToolOutput {
    throw Failure(
      "accessibility_permission_missing",
      "Native desktop control is unavailable on this test host.",
      "Run the Luti app on macOS and grant Accessibility.")
  }
  public func stop() {}
}
