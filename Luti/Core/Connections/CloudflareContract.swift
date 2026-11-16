import Foundation

enum PublicConnectionContract {
  // Public transports have distinct fixed listeners; OpenAI uses an ephemeral private listener.
  static let port = Identity.isDevelopmentBuild ? 39395 : 39393
  static func port(for provider: ConnectionProviderID) -> Int { provider == .vps ? port + 1 : port }
  static var localService: String { "http://127.0.0.1:\(port)" }

  static func origin(_ value: String) throws -> URL {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = !trimmed.isEmpty && !trimmed.contains("://") ? "https://" + trimmed : trimmed
    guard let url = URL(string: normalized), url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(), publicHostname(host),
      url.port == nil || url.port == 443, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
    else { throw Failure.invalid("Enter an HTTPS domain without a path, query or credentials.") }
    return URL(string: "https://" + host)!
  }

  static func publicHostname(_ value: String) -> Bool {
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return value.utf8.count <= 253 && labels.count >= 2
      && !["localhost", "local", "internal", "test", "invalid"].contains(String(labels.last ?? ""))
      && labels.last!.contains(where: { $0.isASCII && $0.isLetter })
      && labels.allSatisfy { label in
        (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      }
  }

}

enum CloudflareContract {
  static let port = PublicConnectionContract.port
  static let tokenAccount = "cloudflare.tunnel-token.v2"
  static var localService: String { PublicConnectionContract.localService }
  static func origin(_ value: String) throws -> URL { try PublicConnectionContract.origin(value) }
  static func publicHostname(_ value: String) -> Bool { PublicConnectionContract.publicHostname(value) }

  static func validateToken(_ value: String) throws {
    guard (40...8192).contains(value.utf8.count),
      value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
        || (48...57).contains($0) || "+/=_-.".utf8.contains($0) })
    else { throw Failure.invalid("Paste the Tunnel Token from Cloudflare, without the install command.") }
  }
}
