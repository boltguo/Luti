import Foundation

enum LocalURLDetector {
  static func find(_ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"https?://(?:localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?(?=[\s<>\"']|$)"#, options: .caseInsensitive) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
      let value = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
      guard var url = URLComponents(string: value), let host = url.host,
            ["localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0"].contains(host.lowercased()),
            url.port == nil || (1...65535).contains(url.port!) else { return nil }
      if host == "0.0.0.0" { url.host = "127.0.0.1" }
      // Query values can contain credentials; localhost discovery needs only origin + path.
      url.query = nil; url.fragment = nil
      return url.string
    }
  }
}
