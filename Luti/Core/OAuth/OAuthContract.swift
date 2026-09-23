import Foundation

/// A scope is admission, never execution permission. The effective permission is
/// always the intersection of the granted scopes, the project/session policy, the
/// tool's own policy and macOS TCC, so holding `computer:control` still fails when
/// Accessibility is not granted.
public enum OAuthScope: String, CaseIterable, Codable, Sendable {
  case projectRead = "project:read"
  case projectWrite = "project:write"
  case processRun = "process:run"
  case browserUse = "browser:use"
  case computerRead = "computer:read"
  case computerControl = "computer:control"

  /// Grok makes the Mac's owner retype this string by hand, so the order is fixed
  /// and the names stay short enough to type without a mistake.
  public static let catalog = allCases.map(\.rawValue)
  public static var spaceSeparated: String { catalog.joined(separator: " ") }

  /// nil when the request names a scope this build does not issue. An unknown
  /// scope is never silently dropped: dropping it would hand the client a token
  /// weaker than the one the approval dialog described.
  public static func parse(_ value: String) -> Set<OAuthScope>? {
    let names = value.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
    guard names.count <= 32 else { return nil }
    var scopes: Set<OAuthScope> = []
    for name in names {
      guard let scope = OAuthScope(rawValue: name) else { return nil }
      scopes.insert(scope)
    }
    return scopes
  }

  /// nil for a tool this mapping does not cover, which the caller must treat as a
  /// denial. Returning an empty set instead would make every unmapped tool public.
  public static func required(tool: String, arguments: JSONValue) -> Set<OAuthScope>? {
    switch tool {
    case "project_info", "read_files", "search_project", "list_directory", "read_image",
      "inspect_project", "skills", "git_query", "export_artifact", "runtime_status":
      return [.projectRead]
    case "code_query":
      return [.projectRead, .processRun]
    case "memory":
      return ["remember", "forget"].contains(arguments["action"].string ?? "") ? [.projectWrite] : [.projectRead]
    case "edit_files", "path_action", "import_artifact":
      return [.projectWrite]
    case "projects":
      // Listing the approved projects is a read; switching the active one changes
      // what every later write lands on, so it needs the write scope too.
      return arguments["action"].string == "switch" ? [.projectRead, .projectWrite] : [.projectRead]
    case "run_process", "run_shell", "job_query", "job_action":
      return [.processRun]
    case "browser_transfer":
      return arguments["action"] == "upload" ? [.browserUse, .projectRead] : [.browserUse]
    case "browser_session", "browser_observe", "browser_action",
      "browser_inspect", "browser_dialog", "browser_evaluate":
      return [.browserUse]
    case "computer_observe", "computer_wait":
      return [.computerRead]
    case "computer_action":
      return [.computerControl]
    default:
      return nil
    }
  }

  @MainActor public var title: String {
    switch self {
    case .projectRead: L10n.text("oauth.readProject")
    case .projectWrite: L10n.text("oauth.changeProject")
    case .processRun: L10n.text("oauth.runCommands")
    case .browserUse: L10n.text("oauth.useBrowser")
    case .computerRead: L10n.text("oauth.viewScreen")
    case .computerControl: L10n.text("oauth.controlDesktop")
    }
  }
  public var symbol: String {
    switch self {
    case .projectRead: "doc.text"
    case .projectWrite: "square.and.pencil"
    case .processRun: "terminal"
    case .browserUse: "globe"
    case .computerRead: "rectangle.on.rectangle"
    case .computerControl: "hand.point.up.left"
    }
  }
}

/// Which pipe a call arrived on. The tool runtime never branches on it; it exists
/// so Activity can say where an effect came from.
public enum TransportProviderID: String, Codable, Sendable {
  case loopback, cloudflare, openAI = "openai", ngrok, quick
}

/// What the tool runtime is told about an authenticated remote caller.
public struct RequestContext: Sendable, Equatable {
  public let transport: TransportProviderID
  public let clientID: String
  public let clientName: String
  public let authorizationID: UUID
  public let scopes: Set<OAuthScope>
  public let resource: String
  public init(
    transport: TransportProviderID, clientID: String, clientName: String, authorizationID: UUID,
    scopes: Set<OAuthScope>, resource: String
  ) {
    self.transport = transport
    self.clientID = clientID
    self.clientName = clientName
    self.authorizationID = authorizationID
    self.scopes = scopes
    self.resource = resource
  }
}

/// `.local` is the in-process bearer minted for one Start: it never leaves this
/// machine and is not an OAuth grant, so it carries no scope restriction. Every
/// request that came off the tunnel is `.remote` and is always scope-checked.
public enum ToolGrant: Sendable, Equatable {
  case local
  case remote(RequestContext)

  public var context: RequestContext? {
    if case .remote(let context) = self { return context }
    return nil
  }
  /// nil means "not delegated", not "everything allowed by OAuth".
  public var scopes: Set<OAuthScope>? { context?.scopes }

  public func authorize(tool: String, arguments: JSONValue) throws {
    guard let context else { return }
    // Mutating project capabilities need a context precondition even when the
    // Host has no file-read scope. This action returns only the minimal binding.
    if tool == "projects", arguments["action"] == "current",
       !context.scopes.isDisjoint(with: [.projectWrite, .processRun, .browserUse]) {
      return
    }
    guard let required = OAuthScope.required(tool: tool, arguments: arguments) else {
      throw Failure(
        "scope_unmapped", "This build does not map \(tool) onto an OAuth scope.",
        "Update Luti, or call this tool from a locally started session.")
    }
    try authorize(scopes: required, operation: tool)
  }

  /// Resources retain the same capability boundary as the tool that produced
  /// them. A resource URI identifies bytes; it does not grant permission.
  public func authorize(scopes required: Set<OAuthScope>, operation: String) throws {
    guard let context else { return }
    let missing = required.subtracting(context.scopes)
    guard missing.isEmpty else {
      throw Failure(
        "insufficient_scope",
        "This connection was granted \(context.scopes.map(\.rawValue).sorted().joined(separator: " ")) and \(operation) needs \(missing.map(\.rawValue).sorted().joined(separator: " ")).",
        "Reconnect the client and approve the missing permission on the Mac; do not retry this call unchanged."
      )
    }
  }
}

/// A client uses exactly one token-endpoint authentication method. The method is
/// fixed per client record and never chosen per request: metadata advertises the
/// capabilities, and the server enforces the registered method so a client cannot
/// downgrade to `none` after receiving a secret.
public enum TokenEndpointAuthMethod: String, Codable, Sendable, CaseIterable {
  case clientSecretBasic = "client_secret_basic"
  case clientSecretPost = "client_secret_post"
  case none = "none"
}

/// Best-effort platform classification for a dynamically registered MCP client.
/// This is display metadata only. A client name is self-asserted, so classification
/// is derived only from callback hostnames recognized with a domain-boundary check.
public enum RemoteMCPHost: String, Codable, Sendable, CaseIterable, Identifiable {
  case chatGPT = "chatgpt"
  case claude
  case grok
  case gemini
  case custom

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .chatGPT: "ChatGPT"
    case .claude: "Claude"
    case .grok: "Grok"
    case .gemini: "Gemini"
    case .custom: "Custom"
    }
  }

  public static func detected(redirectURIs: [String]) -> RemoteMCPHost {
    let hosts = redirectURIs.compactMap { URL(string: $0)?.host?.lowercased() }
    func contains(_ domain: String) -> Bool {
      hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
    }
    if contains("chatgpt.com") { return .chatGPT }
    if contains("claude.ai") { return .claude }
    if contains("grok.com") || contains("x.ai") { return .grok }
    // Each Gemini surface calls back from its own host: Spark through Google's
    // account-linking proxy, Gemini Enterprise through Vertex AI Search,
    // Antigravity through its own domain. Match the documented redirect hosts
    // instead of treating arbitrary googleusercontent.com callbacks as Gemini.
    if contains("gemini.google.com")
      || contains("oauth-redirect.googleusercontent.com")
      || contains("oauth-redirect-sandbox.googleusercontent.com")
      || contains("vertexaisearch.cloud.google.com")
      || contains("antigravity.google")
    {
      return .gemini
    }
    return .custom
  }

  public var symbol: String {
    switch self {
    case .chatGPT: "message.fill"
    case .claude: "sparkles"
    case .grok: "bolt.fill"
    case .gemini: "diamond.fill"
    case .custom: "app.connected.to.app.below.fill"
    }
  }
}

public struct OAuthClientRecord: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var name: String
  public var redirectURIs: [String]
  public var authMethod: TokenEndpointAuthMethod
  public var host: RemoteMCPHost?
  /// Optional for backward compatibility. Older records infer enabled state from
  /// `disabledAt`; new records persist it explicitly so `disabledAt` can remain as
  /// a security epoch after the Host is re-enabled.
  public var enabled: Bool?
  public var disabledAt: Date?
  public var createdAt: Date
  /// Set only after the Mac owner has approved this client at least once.
  /// Older builds did not persist this field; OAuthStore infers legacy approval
  /// from issued/used token history so old unused Host presets stay hidden.
  public var approvedAt: Date?
  public var lastUsedAt: Date?
  public var isEnabled: Bool { enabled ?? (disabledAt == nil) }
  public init(
    id: String, name: String, redirectURIs: [String] = [],
    authMethod: TokenEndpointAuthMethod = .clientSecretPost, host: RemoteMCPHost? = nil,
    enabled: Bool? = true, disabledAt: Date? = nil, createdAt: Date = Date(),
    approvedAt: Date? = nil, lastUsedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.redirectURIs = redirectURIs
    self.authMethod = authMethod
    self.host = host
    self.enabled = enabled
    self.disabledAt = disabledAt
    self.createdAt = createdAt
    self.approvedAt = approvedAt
    self.lastUsedAt = lastUsedAt
  }
}

public enum OAuthContract {
  /// Minutes for anything that is only in flight, an hour for an access token, a
  /// month for a refresh token that rotates on every use.
  public static let pendingSeconds: TimeInterval = 300
  public static let registrationSeconds: TimeInterval = 30 * 60
  public static let codeSeconds: TimeInterval = 60
  public static let accessSeconds: TimeInterval = 3600
  public static let refreshSeconds: TimeInterval = 30 * 24 * 3600

  public static let clientIDPrefix = "ot_cid_"
  public static let clientSecretPrefix = "ot_cs_"
  public static let accessPrefix = "ot_at_"
  public static let refreshPrefix = "ot_rt_"

  public static func newClientID() -> String { clientIDPrefix + Budget.token() }
  public static func newClientSecret() -> String { clientSecretPrefix + Budget.token() }
  public static func newAccessToken() -> String { accessPrefix + Budget.token() }
  public static func newRefreshToken() -> String { refreshPrefix + Budget.token() }

  /// A client identifier arrives in query strings and form bodies, so its shape is
  /// checked before it is ever used as a dictionary key or written to a log line.
  public static func isWellFormedClientID(_ value: String) -> Bool {
    value.hasPrefix(clientIDPrefix) && value.utf8.count == clientIDPrefix.utf8.count + 64
      && value.dropFirst(clientIDPrefix.count).allSatisfy(\.isHexDigit)
  }

  /// Hosts hand out their callback in their own UI and the Mac's owner pastes it
  /// here, so this only has to reject shapes that cannot be a real callback.
  @discardableResult
  public static func validateRedirectURI(_ value: String) throws -> String {
    guard value.utf8.count <= 512, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      let host = url.host, url.fragment == nil, !host.isEmpty
    else {
      throw Failure.invalid(
        "A redirect URI must be an absolute URL with no fragment, such as https://claude.ai/api/mcp/auth_callback."
      )
    }
    switch scheme {
    case "https": break
    case "http":
      // RFC 8252 loopback redirects, for a client running on this same Mac. Any
      // other plaintext callback would put the code on the wire in the clear.
      guard ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host.lowercased()) else {
        throw Failure.invalid("A plaintext redirect URI is only accepted on loopback.")
      }
    default:
      throw Failure.invalid("A redirect URI must use https, or http on loopback.")
    }
    return value
  }

  /// Exact string comparison, as OAuth 2.1 requires. No prefix match, no wildcard,
  /// no normalization: a registered callback either is the presented one or is not.
  public static func isRegistered(_ value: String, in record: OAuthClientRecord) -> Bool {
    record.redirectURIs.contains(value)
  }

  /// RFC 7636 §4.2: 43 to 128 characters from the unreserved set. Checking the
  /// shape here means `/authorize` rejects a malformed challenge while it can
  /// still tell the client why, instead of failing an hour later at `/token`.
  public static func isCodeChallenge(_ value: String) -> Bool {
    (43...128).contains(value.utf8.count) && value.utf8.allSatisfy(isBase64URL)
  }

  /// PKCE S256 only. `plain` is not accepted and is not advertised: it would let
  /// anyone who intercepts the authorization request redeem the code themselves.
  public static func matchesChallenge(verifier: String, challenge: String) -> Bool {
    guard (43...128).contains(verifier.utf8.count), verifier.utf8.allSatisfy(isBase64URL) else {
      return false
    }
    return Budget.constantTimeEqual(base64URL(Budget.digest(Data(verifier.utf8))), challenge)
  }

  private static func isBase64URL(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"):
      return true
    case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
      return true
    default:
      return false
    }
  }

  /// base64url without padding, as PKCE specifies.
  static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
