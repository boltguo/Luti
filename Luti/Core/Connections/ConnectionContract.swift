import Foundation

public enum ConnectionProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
  case cloudflare, openAI = "openai", ngrok, quick

  /// Providers whose configuration is user-owned, persisted and eligible for
  /// automatic startup with the Runtime. Quick Tunnel is deliberately session-only.
  public static let persistentProviders: [ConnectionProviderID] = [.cloudflare, .openAI, .ngrok]

  public var id: String { rawValue }
  public var usesOAuth: Bool { self != .openAI }
  public var isPersistent: Bool { Self.persistentProviders.contains(self) }
  public var title: String {
    switch self {
    case .cloudflare: "Cloudflare BYO"
    case .openAI: "OpenAI Secure MCP Tunnel"
    case .ngrok: "ngrok"
    case .quick: "Cloudflare Quick Tunnel"
    }
  }
  public var transport: TransportProviderID {
    switch self {
    case .cloudflare: .cloudflare
    case .openAI: .openAI
    case .ngrok: .ngrok
    case .quick: .quick
    }
  }
}

/// Shared public-ingress validation, independent of any tunnel vendor.
public enum ConnectionContract {
  /// An explicitly configured public HTTPS origin. It becomes the OAuth issuer, so it
  /// is never derived from a request header.
  @discardableResult
  public static func validatePublicBaseURL(_ value: String) throws -> URL {
    guard value.utf8.count <= 255, let url = URL(string: value), url.scheme == "https",
      let host = url.host, url.port == nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, ["", "/"].contains(url.path)
    else {
      throw Failure.invalid(
        "Public Base URL must be https://host with no port, path, query string or credentials.")
    }
    try validateHostname(host)
    return url
  }

  public static func validateIngressEndpoint(_ url: URL) throws {
    guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
      (1...65535).contains(port), url.path == "/mcp", url.user == nil,
      url.password == nil, url.query == nil, url.fragment == nil
    else { throw Failure.invalid("A provider can forward only its own loopback MCP listener.") }
  }

  public static func validateTunnelID(_ value: String) throws {
    guard value.hasPrefix("tunnel_"), (8...128).contains(value.utf8.count),
      value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
        || (97...122).contains($0) || $0 == 95 || $0 == 45 })
    else { throw Failure.invalid("Enter the tunnel_id from OpenAI Platform tunnel settings.") }
  }

  public static func validateCredential(_ value: String, provider: ConnectionProviderID) throws {
    if provider == .cloudflare { try TunnelContract.validateToken(value); return }
    guard (20...8192).contains(value.utf8.count),
      value.utf8.allSatisfy({ (33...126).contains($0) }),
      provider != .openAI || value.hasPrefix("sk-")
    else { throw Failure.invalid("Enter the provider's runtime credential, without spaces or line breaks.") }
  }

  /// Lowercase DNS hostname only: no IP literal, no port, no wildcard.
  public static func validateHostname(_ host: String) throws {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard host.utf8.count <= 253, labels.count >= 2,
      labels.allSatisfy({ label in
        (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
          && label.allSatisfy { character in
            character.isASCII
              && (character.isNumber || (character.isLetter && character.isLowercase)
                || character == "-")
          }
      }), let top = labels.last, top.contains(where: { $0.isLetter })
    else {
      throw Failure.invalid(
        "Hostname must be a lowercase DNS name such as mcp.example.com, not an IP address or a wildcard."
      )
    }
  }

}
