import Foundation

public enum ConnectionProviderID: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
  case cloudflare

  public var id: String { rawValue }
  public var title: String { "Cloudflare BYO" }
  public var transport: TransportProviderID { .cloudflare }
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
