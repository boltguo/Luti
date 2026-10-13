import Foundation

public enum ConnectionProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
  case openAI = "openai"
  case cloudflare

  public var id: String { rawValue }
  public var title: String { self == .openAI ? "OpenAI Secure MCP Tunnel" : "Cloudflare Tunnel" }
  public var transport: TransportProviderID { self == .openAI ? .openAI : .cloudflare }
}

public enum ConnectionContract {
  public static func validateIngressEndpoint(_ url: URL) throws {
    guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
      (1...65535).contains(port), url.path == "/mcp", url.user == nil,
      url.password == nil, url.query == nil, url.fragment == nil
    else { throw Failure.invalid("A provider can forward only its own loopback MCP listener.") }
  }

  public static func validateTunnelID(_ value: String) throws {
    // Matches tunnel-client's own contract: ^tunnel_[a-z0-9]{32}$.
    let suffix = value.utf8.dropFirst("tunnel_".utf8.count)
    guard value.hasPrefix("tunnel_"), suffix.count == 32,
      suffix.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) })
    else { throw Failure.invalid("Enter the tunnel_id from OpenAI Platform tunnel settings.") }
  }

  /// A runtime API key: printable, single-line and `sk-` prefixed.
  public static func validateAPIKey(_ value: String) throws {
    guard (20...8192).contains(value.utf8.count), value.hasPrefix("sk-"),
      value.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw Failure.invalid("Enter the OpenAI runtime API key, without spaces or line breaks.") }
  }
}
