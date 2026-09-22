import Foundation

/// The Cloudflare BYO provider pins its binary. Version, per-architecture
/// digests and the signing team are all pinned, and all three are checked before
/// the executable is ever run.
public enum TunnelContract {
  public static let version = "2026.9.1"
  public static let binaryName = "cloudflared"
  /// Cloudflare's Developer ID team. Their macOS builds are signed with the
  /// hardened runtime but are NOT notarized, so a digest match alone proves only
  /// "same bytes I reviewed", never "published by Cloudflare". The signature is
  /// checked as well; see TunnelInstaller.verify.
  public static let teamIdentifier = "68WVV388M8"

  /// Fixed Cloudflare ingress port, matching its dashboard service rule.
  /// Local MCP uses a separate ephemeral port and does not depend on this one.
  public static let defaultPort = 39393
  /// cloudflared's own metrics listener, used only for its /ready probe.
  public static let metricsPort = 39394

  public struct Build: Sendable {
    public let slug: String
    public let archiveSHA: String
    public let binarySHA: String
    public var downloadURL: URL {
      URL(
        string:
          "https://github.com/cloudflare/cloudflared/releases/download/\(TunnelContract.version)/cloudflared-darwin-\(slug).tgz"
      )!
    }
  }
  public static let appleSilicon = Build(
    slug: "arm64",
    archiveSHA: "c27ab8fd0aa489449e3d201eb02f957ef460a13b613662928b1b23394bf1bcfe",
    binarySHA: "9a0b19f67dc7a3011bc6b972c7ce06a5fcea8784ac6bd599ffa382ea4aeb5a6e")
  public static let intel = Build(
    slug: "amd64",
    archiveSHA: "ff0d3b51d5ff70eceef89d6b32145fee985018a2174596a5dbe405e2766e2ac4",
    binarySHA: "1ea07ae775b03236bd6be18ca1848d6bdc4af2f4f3bce398823b5a36e5761b75")
  /// nil on an architecture this build has no reviewed digest for; the installer
  /// fails closed rather than running an unpinned download.
  public static var current: Build? {
    #if arch(arm64)
      return appleSilicon
    #elseif arch(x86_64)
      return intel
    #else
      return nil
    #endif
  }
  public static var downloadURL: URL { (current ?? appleSilicon).downloadURL }

  /// A Cloudflare Tunnel token is base64 text. Only its shape is checked here;
  /// cloudflared is the authority on whether it is valid.
  public static func validateToken(_ value: String) throws {
    guard (40...8192).contains(value.utf8.count),
      value.allSatisfy({ character in
        character.isASCII
          && (character.isLetter || character.isNumber || "+/=_-.".contains(character))
      })
    else {
      throw Failure.invalid(
        "Tunnel Token must be the base64 token Cloudflare shows when you create a tunnel.")
    }
  }
}
