import Foundation

struct OAuthClient: Codable, Sendable, Equatable {
  let id: String
  let name: String
  let redirects: [String]
  let authMethod: String
  let secretHash: String?
  let createdAt: Date
}

struct OAuthGrant: Codable, Sendable, Equatable, Identifiable {
  let id: UUID
  let clientID: String
  let createdAt: Date
  let expiresAt: Date
  var accessHash: String = ""
  var accessExpiresAt: Date = .distantPast
  var refreshHash: String = ""
  var spentRefreshHashes: [String] = []
}

struct OAuthPending: Sendable, Equatable, Identifiable {
  let id: UUID
  let client: OAuthClient
  let redirect: String
  let state: String?
  let challenge: String
  let createdAt: Date
  let verification: String
  let ticketHash: String
  var outcome: String?
}

struct OAuthApplication: Sendable, Equatable, Identifiable {
  let id: UUID
  let name: String
  let callbackHost: String
  let createdAt: Date
}

struct OAuthSnapshot: Sendable, Equatable {
  var pending: [OAuthPending] = []
  var applications: [OAuthApplication] = []
}

enum OAuthContract {
  static let scope = "mcp"
  static let accessSeconds: TimeInterval = 3600
  static let grantSeconds: TimeInterval = 30 * 24 * 3600
  static let pendingSeconds: TimeInterval = 300
  static let paths: Set<String> = [
    "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
    "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp",
    "/oauth/register", "/oauth/authorize", "/oauth/wait", "/oauth/token", "/oauth/revoke",
  ]
  static func hash(_ value: String) -> String { Budget.sha256(Data(value.utf8)) }
  static func challenge(_ verifier: String) -> String {
    Data(Budget.digest(Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  static func validVerifier(_ value: String) -> Bool {
    (43...128).contains(value.utf8.count) && value.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || "-._~".utf8.contains($0)
    }
  }
  static func validRedirect(_ value: String) -> Bool {
    guard value.utf8.count <= 2048, let u = URLComponents(string: value),
      u.scheme == "https", let host = u.host, CloudflareContract.publicHostname(host.lowercased()),
      u.user == nil, u.password == nil, u.fragment == nil, u.port == nil || u.port == 443
    else { return false }
    return !(u.queryItems ?? []).contains { ["code", "state", "error", "iss"].contains($0.name) }
  }
  /// Reject duplicate parameters instead of silently choosing an attacker-controlled value.
  static func form(_ raw: String) throws -> [String: String] {
    guard raw.utf8.count <= 16_384 else { throw Failure.invalid("OAuth request too large.") }
    var result: [String: String] = [:]
    for field in raw.split(separator: "&", omittingEmptySubsequences: true) {
      let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      func decode(_ value: Substring) -> String? {
        String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
      }
      guard let key = decode(parts[0]), !key.isEmpty, key.utf8.count <= 64,
        let value = decode(parts.count == 2 ? parts[1] : ""), value.utf8.count <= 4096,
        result[key] == nil, result.count < 24
      else { throw Failure.invalid("Malformed or duplicate OAuth parameter.") }
      result[key] = value
    }
    return result
  }
}
