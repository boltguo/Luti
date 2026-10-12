import Foundation

public enum Identity {
  #if DEBUG
  public static let isDevelopmentBuild = true
  public static let name = "Luti Dev"
  public static let bundleID = "com.aouos.luti.debug"
  #else
  public static let isDevelopmentBuild = false
  public static let name = "Luti"
  public static let bundleID = "com.aouos.luti"
  #endif
  public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
  public static let keychainService = bundleID + ".tunnel"
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
  /// Compiled once; NSRegularExpression is immutable and safe to share.
  private static let expressions: [NSRegularExpression] = [
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
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  public func clean(_ source: String) -> String {
    var value = source
    for secret in known { value = value.replacingOccurrences(of: secret, with: "[REDACTED]") }
    for re in Self.expressions {
      value = re.stringByReplacingMatches(
        in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "[REDACTED]")
    }
    return value
  }

  /// Sorted, merged byte ranges `clean` would hide. Matching keeps Unicode
  /// semantics; each UTF-16 unit maps back to the byte offset of its scalar, and an
  /// invalid byte sequence becomes one U+FFFD covering exactly those bytes.
  func sensitiveRanges(_ data: Data) -> [Range<Int>] {
    var scalars = String.UnicodeScalarView()
    var offsets: [Int] = []
    var parser = Unicode.UTF8.ForwardParser()
    var input = data.makeIterator()
    var position = 0
    decoding: while true {
      switch parser.parseScalar(from: &input) {
      case .valid(let encoded):
        let scalar = Unicode.UTF8.decode(encoded)
        scalars.append(scalar)
        offsets += repeatElement(position, count: scalar.utf16.count)
        position += encoded.count
      case .error(let length):
        scalars.append("\u{FFFD}")
        offsets.append(position)
        position += length
      case .emptyInput:
        break decoding
      }
    }
    offsets.append(position)
    let text = String(scalars)
    let ns = text as NSString
    func bytes(_ range: NSRange) -> Range<Int> {
      offsets[range.location]..<offsets[NSMaxRange(range)]
    }
    var ranges: [Range<Int>] = []
    for secret in known {
      var search = NSRange(location: 0, length: ns.length)
      while true {
        let found = ns.range(of: secret, options: .literal, range: search)
        guard found.location != NSNotFound, found.length > 0 else { break }
        ranges.append(bytes(found))
        search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
      }
    }
    for re in Self.expressions {
      for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length))
      where match.range.length > 0 {
        ranges.append(bytes(match.range))
      }
    }
    var merged: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = merged.last, range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
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
