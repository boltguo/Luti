import Foundation

/// An authorization the Host has asked for and the Mac has not answered yet. It
/// only ever lives in memory: it is worthless after five minutes, and persisting
/// it would mean a restart could resurrect a dialog nobody is waiting on.
public struct PendingAuthorization: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let clientID: String
  public let clientName: String
  public let clientPlatform: RemoteMCPHost
  public let isDynamicallyRegistered: Bool
  public let redirectURI: String
  /// Still percent-encoded, exactly as the client put it on the wire. See
  /// `FormBody.rawValue`.
  public let state: String?
  public let codeChallenge: String
  public let scopes: Set<OAuthScope>
  public let resource: String
  public let createdAt: Date
  public var decidedAt: Date?
  public var approved: Bool?
  /// The redirect is delivered exactly once, so a second poll of the wait page
  /// cannot pick the code up again.
  public var delivered = false

  public var isExpired: Bool {
    decidedAt == nil && Date().timeIntervalSince(createdAt) > OAuthContract.pendingSeconds
  }
  public var sortedScopes: [OAuthScope] {
    OAuthScope.allCases.filter { scopes.contains($0) }
  }
}

private struct IssuedCode: Sendable {
  let clientID: String
  let authorizationID: UUID
  let redirectURI: String
  let codeChallenge: String
  let scopes: Set<OAuthScope>
  let resource: String
  let issuedAt: Date
}

/// A DCR result is deliberately transient. Registration proves no identity and
/// grants no Mac access; only the later native approval can promote it to the
/// durable OAuth store. Keeping the candidate in memory also bounds registration
/// spam and avoids filling the Keychain with unauthenticated Internet input.
private struct PendingRegistration: Sendable {
  let id: String
  let name: String
  let redirectURIs: [String]
  let authMethod: TokenEndpointAuthMethod
  let platform: RemoteMCPHost
  let clientSecret: String?
  let applicationType: String
  let createdAt: Date

  var isExpired: Bool {
    Date().timeIntervalSince(createdAt) > OAuthContract.registrationSeconds
  }
  var record: OAuthClientRecord {
    OAuthClientRecord(
      id: id, name: name, redirectURIs: redirectURIs, authMethod: authMethod,
      host: platform, enabled: true, createdAt: createdAt)
  }
}

private enum OAuthPageLanguage: String, Sendable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"
  case japanese = "ja"

  private struct Preference {
    let tag: String
    let quality: Double
    let order: Int
  }

  static func preferred(from values: [String]) -> OAuthPageLanguage {
    let preferences = values.joined(separator: ",")
      .split(separator: ",", omittingEmptySubsequences: true)
      .enumerated()
      .compactMap { order, raw -> Preference? in
        let fields = raw.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = fields.first else { return nil }
        let tag = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        var quality = 1.0
        for field in fields.dropFirst() {
          let parameter = field.trimmingCharacters(in: .whitespacesAndNewlines)
          guard parameter.lowercased().hasPrefix("q=") else { continue }
          guard let parsed = Double(String(parameter.dropFirst(2))), parsed >= 0, parsed <= 1
          else {
            quality = 0
            break
          }
          quality = parsed
        }
        guard quality > 0 else { return nil }
        return Preference(tag: tag.lowercased(), quality: quality, order: order)
      }
      .sorted {
        $0.quality == $1.quality ? $0.order < $1.order : $0.quality > $1.quality
      }

    for preference in preferences {
      if preference.tag == "zh" || preference.tag.hasPrefix("zh-") {
        return .simplifiedChinese
      }
      if preference.tag == "ja" || preference.tag.hasPrefix("ja-") {
        return .japanese
      }
      if preference.tag == "en" || preference.tag.hasPrefix("en-")
        || preference.tag == "*"
      {
        return .english
      }
    }
    return .english
  }

  var waitingHeading: String {
    switch self {
    case .english: "Waiting for approval on your Mac\u{2026}"
    case .simplifiedChinese: "正在等待你在 Mac 上批准\u{2026}"
    case .japanese: "Macでの承認を待っています\u{2026}"
    }
  }

  func waitingBody(client: String) -> String {
    switch self {
    case .english: "\(client) is requesting access. Open Luti and choose Allow."
    case .simplifiedChinese: "\(client) 正在请求访问。请打开 Luti 并选择“允许”。"
    case .japanese: "\(client)がアクセスを求めています。Lutiを開いて「許可」を選択してください。"
    }
  }
}

/// Luti's own OAuth 2.1 authorization server.
///
/// Transport never owns the durable authorization store. Each remote connection
/// owns a short-lived service: closing it retires pending flows, not approved
/// clients or existing grants. Dynamic registration remains transient until the
/// Mac's owner explicitly approves it.
public actor LutiOAuthService {
  public struct Paths {
    public static let protectedResource = "/.well-known/oauth-protected-resource"
    public static let protectedResourceMCP = "/.well-known/oauth-protected-resource/mcp"
    public static let authorizationServer = "/.well-known/oauth-authorization-server"
    public static let authorizationServerMCP = "/.well-known/oauth-authorization-server/mcp"
    public static let register = "/register"
    public static let authorize = "/authorize"
    public static let authorizeWait = "/authorize/wait"
    public static let token = "/token"
    public static let revoke = "/revoke"
    /// Everything reachable without a bearer token. `/mcp` is deliberately absent.
    public static let unauthenticated: Set<String> = [
      protectedResource, protectedResourceMCP, authorizationServer, authorizationServerMCP,
      register, authorize, authorizeWait, token, revoke,
    ]
  }

  /// Always the configured Public Base URL, never a request header: the issuer is
  /// what the Host pins its client registration to, so an attacker who could steer
  /// it could point a valid flow at their own server.
  private let issuer: URL
  private let transport: TransportProviderID
  private let store: OAuthStore
  private var stopped = false
  private var registrations: [String: PendingRegistration] = [:]
  private var pending: [UUID: PendingAuthorization] = [:]
  private var codes: [String: IssuedCode] = [:]
  private var credits = 30.0
  private var creditTime = ContinuousClock.now
  private var registrationCredits = 8.0
  private var registrationCreditTime = ContinuousClock.now

  public init(issuer: URL, store: OAuthStore = .shared, transport: TransportProviderID = .cloudflare) {
    self.issuer = issuer
    self.store = store
    self.transport = transport
  }

  public nonisolated var resourceIdentifier: String {
    issuer.absoluteString.hasSuffix("/")
      ? String(issuer.absoluteString.dropLast()) + "/mcp" : issuer.absoluteString + "/mcp"
  }
  private var origin: String {
    issuer.absoluteString.hasSuffix("/")
      ? String(issuer.absoluteString.dropLast()) : issuer.absoluteString
  }
  public nonisolated var protectedResourceURL: String {
    let base =
      issuer.absoluteString.hasSuffix("/")
      ? String(issuer.absoluteString.dropLast()) : issuer.absoluteString
    // RFC 9728 discovery is resource-path aware. Keep the root metadata route for
    // older Hosts, but advertise the /mcp-specific document in the 401 challenge.
    return base + Paths.protectedResourceMCP
  }

  // MARK: - Discovery

  /// RFC 9728. The resource points at the authorization server; the two are the
  /// same origin here, which is allowed and keeps the Host's discovery to one hop.
  public var protectedResourceMetadata: JSONValue {
    [
      "resource": .string(resourceIdentifier),
      "authorization_servers": .array([.string(origin)]),
      "scopes_supported": .array(OAuthScope.catalog.map(JSONValue.string)),
      "bearer_methods_supported": .array([.string("header")]),
    ]
  }

  /// RFC 8414 plus RFC 7591 registration metadata. DCR is kept for compatibility
  /// with MCP clients that still use it; the registered client remains untrusted
  /// until the Mac's owner approves the first authorization request.
  public var authorizationServerMetadata: JSONValue {
    [
      "issuer": .string(origin),
      "authorization_endpoint": .string(origin + Paths.authorize),
      "token_endpoint": .string(origin + Paths.token),
      "registration_endpoint": .string(origin + Paths.register),
      "revocation_endpoint": .string(origin + Paths.revoke),
      "response_types_supported": .array([.string("code")]),
      "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
      "code_challenge_methods_supported": .array([.string("S256")]),
      "token_endpoint_auth_methods_supported": .array(
        TokenEndpointAuthMethod.allCases.map { .string($0.rawValue) }),
      "revocation_endpoint_auth_methods_supported": .array(
        TokenEndpointAuthMethod.allCases.map { .string($0.rawValue) }),
      "scopes_supported": .array(OAuthScope.catalog.map(JSONValue.string)),
      // RFC 9207: the authorization response carries `iss`, so say so and let the
      // Host reject a response that came back from somewhere else.
      "authorization_response_iss_parameter_supported": .bool(true),
    ]
  }

  // MARK: - Request entry point

  /// Retire this connection's transient state before releasing its listener.
  /// Queued native decisions cannot approve a registration after shutdown returns.
  public func shutdown() {
    stopped = true
    registrations.removeAll()
    pending.removeAll()
    codes.removeAll()
  }

  public func handle(_ request: HTTPRequest) -> HTTPReply {
    guard !stopped else {
      return oauthError(503, "temporarily_unavailable", "This remote connection has closed.")
    }
    let path = String(request.path.prefix(while: { $0 != "?" }))
    switch path {
    case Paths.protectedResource, Paths.protectedResourceMCP:
      return get(request) ?? json(200, protectedResourceMetadata)
    case Paths.authorizationServer, Paths.authorizationServerMCP:
      return get(request) ?? json(200, authorizationServerMetadata)
    case Paths.register:
      return postJSON(request) ?? register(request)
    case Paths.authorize:
      return get(request) ?? authorize(request)
    case Paths.authorizeWait:
      return get(request) ?? wait(request)
    case Paths.token:
      return post(request) ?? token(request)
    case Paths.revoke:
      return post(request) ?? revoke(request)
    default:
      return HTTPReply(status: 404)
    }
  }

  private func get(_ request: HTTPRequest) -> HTTPReply? {
    request.method == "GET" ? nil : HTTPReply(status: 405, headers: ["Allow": "GET"])
  }
  private func post(_ request: HTTPRequest) -> HTTPReply? {
    guard request.method == "POST" else {
      return HTTPReply(status: 405, headers: ["Allow": "POST"])
    }
    guard request.body.count <= 8192 else { return HTTPReply(status: 413) }
    guard
      request.headers["content-type"]?.first?.split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased() == "application/x-www-form-urlencoded"
    else { return HTTPReply(status: 415) }
    return nil
  }

  private func postJSON(_ request: HTTPRequest) -> HTTPReply? {
    guard request.method == "POST" else {
      return HTTPReply(status: 405, headers: ["Allow": "POST"])
    }
    guard request.body.count <= 16_384 else { return HTTPReply(status: 413) }
    guard
      request.headers["content-type"]?.first?.split(separator: ";").first?
        .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    else { return HTTPReply(status: 415) }
    return nil
  }

  /// Shared with `/authorize`, `/token` and `/revoke`. Approval spam and secret
  /// guessing are the two things a stranger can still attempt once they somehow
  /// hold a client id, and both are slow enough here to be useless.
  private func spend() -> Bool {
    let now = ContinuousClock.now
    let elapsed = creditTime.duration(to: now).components
    credits = min(30, credits + (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 2)
    creditTime = now
    guard credits >= 1 else { return false }
    credits -= 1
    return true
  }

  /// Registration has its own much slower bucket so anonymous DCR traffic cannot
  /// consume the budget used by legitimate authorization and token exchanges.
  private func spendRegistration() -> Bool {
    let now = ContinuousClock.now
    let elapsed = registrationCreditTime.duration(to: now).components
    registrationCredits = min(
      8,
      registrationCredits
        + (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) * 0.1)
    registrationCreditTime = now
    guard registrationCredits >= 1 else { return false }
    registrationCredits -= 1
    return true
  }

  // MARK: - /register

  private func register(_ request: HTTPRequest) -> HTTPReply {
    guard spendRegistration() else {
      return oauthError(429, "slow_down", "Too many client registration requests.")
    }
    prunePending()
    guard registrations.count < 32 else {
      return oauthError(429, "slow_down", "Too many unapproved client registrations.")
    }

    let metadata: [String: JSONValue]
    do {
      guard let object = try JSONValue.decode(request.body).object else {
        return refuse(
          400, "invalid_client_metadata", "Registration metadata must be a JSON object.",
          "Client registration rejected")
      }
      metadata = object
    } catch {
      return refuse(
        400, "invalid_client_metadata", "Registration metadata is invalid JSON.",
        "Client registration rejected")
    }

    let rawName = metadata["client_name"]?.string ?? "MCP Client"
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...64).contains(name.utf8.count),
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      return refuse(
        400, "invalid_client_metadata",
        "client_name must be 1 to 64 bytes and contain no control characters.",
        "Client registration rejected")
    }

    // A Host registers every callback it might use, and how many that is, is its
    // own business: Gemini Spark's array is undocumented and well past two. The
    // cap only has to stop an unauthenticated caller filling the store.
    guard let rawRedirects = metadata["redirect_uris"]?.array, (1...32).contains(rawRedirects.count)
    else {
      return refuse(
        400, "invalid_redirect_uri", "One to 32 redirect_uris are required.",
        "Client registration rejected")
    }
    var redirectURIs: [String] = []
    for value in rawRedirects {
      guard let uri = value.string else {
        return refuse(
          400, "invalid_redirect_uri", "Every redirect URI must be a string.",
          "Client registration rejected")
      }
      do { redirectURIs.append(try OAuthContract.validateRedirectURI(uri)) }
      catch {
        // Registration is all-or-nothing, so the whole array is logged next to the
        // one that failed: otherwise the Mac's owner cannot tell which callback a
        // Host wanted, and a Host reports only its own generic failure.
        LocalLogStore.runtime(
          "error",
          "Client registration rejected: \(uri) is not an acceptable redirect URI. The request asked for \(rawRedirects.compactMap(\.string).joined(separator: " ")).")
        return oauthError(400, "invalid_redirect_uri", Failure.safe(error).message)
      }
    }
    redirectURIs = Array(Set(redirectURIs)).sorted()

    func strings(_ key: String) -> [String]? {
      guard let value = metadata[key] else { return nil }
      guard let array = value.array else { return [] }
      let result = array.compactMap(\.string)
      return result.count == array.count ? result : []
    }
    let grantTypes = strings("grant_types") ?? ["authorization_code", "refresh_token"]
    guard grantTypes.contains("authorization_code"),
      grantTypes.allSatisfy({ ["authorization_code", "refresh_token"].contains($0) })
    else {
      return refuse(
        400, "invalid_client_metadata", "Only authorization_code and refresh_token are supported.",
        "Client registration rejected")
    }
    let responseTypes = strings("response_types") ?? ["code"]
    guard responseTypes == ["code"] else {
      return refuse(
        400, "invalid_client_metadata", "Only the code response type is supported.",
        "Client registration rejected")
    }

    // RFC 7591 §2: when omitted, token_endpoint_auth_method defaults to
    // client_secret_basic. Some Hosts rely on that default instead of spelling
    // the method out in dynamic client registration.
    let authName =
      metadata["token_endpoint_auth_method"]?.string
      ?? TokenEndpointAuthMethod.clientSecretBasic.rawValue
    guard let authMethod = TokenEndpointAuthMethod(rawValue: authName) else {
      return refuse(
        400, "invalid_client_metadata", "Unsupported token_endpoint_auth_method.",
        "Client registration rejected")
    }
    let inferredNative = redirectURIs.allSatisfy {
      guard let url = URL(string: $0), url.scheme?.lowercased() == "http",
        let host = url.host?.lowercased()
      else { return false }
      return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    let applicationType = metadata["application_type"]?.string ?? (inferredNative ? "native" : "web")
    guard ["native", "web"].contains(applicationType) else {
      return refuse(
        400, "invalid_client_metadata", "application_type must be native or web.",
        "Client registration rejected")
    }

    let clientID = OAuthContract.newClientID()
    let secret = authMethod == .none ? nil : OAuthContract.newClientSecret()
    let registration = PendingRegistration(
      id: clientID, name: name, redirectURIs: redirectURIs, authMethod: authMethod,
      platform: RemoteMCPHost.detected(redirectURIs: redirectURIs),
      clientSecret: secret, applicationType: applicationType, createdAt: Date())
    registrations[clientID] = registration

    var response: JSONValue = [
      "client_id": .string(clientID),
      "client_id_issued_at": .int(Int(registration.createdAt.timeIntervalSince1970)),
      "client_name": .string(name),
      "redirect_uris": .array(redirectURIs.map(JSONValue.string)),
      "grant_types": .array(grantTypes.map(JSONValue.string)),
      "response_types": .array([.string("code")]),
      "token_endpoint_auth_method": .string(authMethod.rawValue),
      "application_type": .string(applicationType),
    ]
    if let secret {
      response = response.adding("client_secret", .string(secret))
      response = response.adding("client_secret_expires_at", .int(0))
    }
    LocalLogStore.runtime(
      "info",
      "Received a temporary DCR client registration for \(registration.platform.displayName) using \(authMethod.rawValue), callbacks: \(redirectURIs.joined(separator: " ")).")
    return json(201, response)
  }

  // MARK: - /authorize

  private func authorize(_ request: HTTPRequest) -> HTTPReply {
    guard spend() else { return page(429, "Too many authorization requests. Try again in a moment.") }
    let rawQuery = String(request.path.drop(while: { $0 != "?" }).dropFirst())
    let query = FormBody.parse(rawQuery)

    // Client and callback are settled before anything else. If either is wrong the
    // answer stays on this page: redirecting an unverified callback would turn the
    // server into an open redirector.
    prunePending()
    guard let clientID = query["client_id"], OAuthContract.isWellFormedClientID(clientID) else {
      return page(400, "This OAuth client id is invalid.")
    }
    let durable = store.client(clientID)
    let dynamic = durable == nil ? registrations[clientID] : nil
    guard let record = durable ?? dynamic?.record, record.isEnabled else {
      return page(400, "This OAuth client is unknown, expired, or disabled on the Mac.")
    }
    guard let redirectURI = query["redirect_uri"] else {
      return page(400, "The authorization request is missing redirect_uri.")
    }
    guard OAuthContract.isRegistered(redirectURI, in: record) else {
      return page(
        400,
        "This callback URL does not match the client's dynamic registration. Start the connection again from the AI app."
      )
    }

    // RFC 6749 §4.1.2: `state` comes back to the client byte for byte. It is read
    // and echoed in its wire form because decoding and re-encoding is not an
    // identity here: `+` decodes to a space, and `%2D` and `-` both decode to `-`.
    // Google Account Linking, which Gemini Spark uses, sends a base64 blob that
    // contains `+`, so a re-encoded state is a state the Host no longer accepts.
    let state = FormBody.rawValue("state", in: rawQuery)
    if let state, state.utf8.count > 512 || !FormBody.isWireSafe(state) {
      // Echoing an unusable state reads as a CSRF failure to the client, and
      // dropping it reads the same. Neither belongs on the callback.
      LocalLogStore.runtime("error", "Authorization rejected for \(record.name): malformed state.")
      return page(400, "The state parameter is malformed or too long.")
    }
    func reject(_ code: String, _ description: String) -> HTTPReply {
      LocalLogStore.runtime("error", "Authorization rejected for \(record.name): \(code).")
      return redirect(to: redirectURI, parameters: [
        "error": code, "error_description": description, "state": state, "iss": origin,
      ])
    }

    guard query["response_type"] == "code" else {
      return reject("unsupported_response_type", "Only the authorization code flow is supported.")
    }
    guard query["code_challenge_method"] == "S256" else {
      return reject("invalid_request", "PKCE with S256 is required.")
    }
    guard let challenge = query["code_challenge"], OAuthContract.isCodeChallenge(challenge) else {
      return reject("invalid_request", "A valid S256 code_challenge is required.")
    }
    // RFC 8707. A token minted here is only ever good for this one resource, so a
    // client cannot carry it to another MCP server that trusts the same issuer.
    let resource = query["resource"] ?? resourceIdentifier
    guard resource == resourceIdentifier else {
      return reject("invalid_target", "This authorization server only issues tokens for \(resourceIdentifier).")
    }
    // An absent scope means "everything this server issues". That is safe only
    // because the approval dialog names each one and the Mac's owner has to agree.
    guard let scopes = OAuthScope.parse(query["scope"] ?? OAuthScope.spaceSeparated) else {
      return reject("invalid_scope", "Requested scope is not one this server issues.")
    }
    guard !scopes.isEmpty else {
      return reject("invalid_scope", "At least one scope is required.")
    }

    guard pending.values.filter({ $0.decidedAt == nil }).count < 8 else {
      return page(429, "Several connection requests are already waiting. Answer them in Luti first.")
    }
    guard !pending.values.contains(where: { $0.clientID == clientID && $0.decidedAt == nil }) else {
      return page(429, "This client already has an authorization request waiting on the Mac.")
    }
    let item = PendingAuthorization(
      id: UUID(), clientID: clientID, clientName: record.name,
      clientPlatform: record.host ?? .custom, isDynamicallyRegistered: dynamic != nil,
      redirectURI: redirectURI, state: state, codeChallenge: challenge, scopes: scopes,
      resource: resource, createdAt: Date())
    pending[item.id] = item
    LocalLogStore.runtime("info", "Authorization requested by client \(record.name).")
    return waiting(
      item.id,
      client: record.name,
      language: OAuthPageLanguage.preferred(from: request.headers["accept-language"] ?? []))
  }

  /// The browser only ever sees a status. The Allow button is a native window on
  /// the Mac, because a stranger who started this flow would be looking at their
  /// own browser and would happily click Allow in it.
  private func wait(_ request: HTTPRequest) -> HTTPReply {
    let query = FormBody.parse(String(request.path.drop(while: { $0 != "?" }).dropFirst()))
    prunePending()
    guard let raw = query["id"], let id = UUID(uuidString: raw), let item = pending[id] else {
      return page(400, "This authorization request has expired or already finished. Start the connection again.")
    }
    guard let approved = item.approved else {
      return waiting(
        id,
        client: item.clientName,
        language: OAuthPageLanguage.preferred(from: request.headers["accept-language"] ?? []))
    }
    guard !item.delivered else {
      return page(400, "This authorization request has already been answered. Check the AI app for the result.")
    }
    pending[id]?.delivered = true
    guard approved else {
      return redirect(to: item.redirectURI, parameters: [
        "error": "access_denied", "error_description": "The Mac's owner denied this connection.",
        "state": item.state, "iss": origin,
      ])
    }
    let code = "ot_code_" + Budget.token()
    codes[OAuthStore.hash(code)] = IssuedCode(
      clientID: item.clientID, authorizationID: item.id, redirectURI: item.redirectURI,
      codeChallenge: item.codeChallenge, scopes: item.scopes, resource: item.resource,
      issuedAt: Date())
    return redirect(to: item.redirectURI, parameters: [
      "code": code, "state": item.state, "iss": origin,
    ])
  }

  // MARK: - Native approval

  public func pendingApprovals() -> [PendingAuthorization] {
    guard !stopped else { return [] }
    prunePending()
    return pending.values.filter { $0.decidedAt == nil }.sorted { $0.createdAt < $1.createdAt }
  }

  public func resolve(_ id: UUID, approved: Bool) {
    guard !stopped, var item = pending[id], item.decidedAt == nil, !item.isExpired else { return }
    var decision = approved
    if approved, store.client(item.clientID) == nil {
      guard let registration = registrations[item.clientID], !registration.isExpired else {
        decision = false
        item.decidedAt = Date()
        item.approved = false
        pending[id] = item
        LocalLogStore.runtime("error", "DCR registration expired before native approval.")
        return
      }
      do {
        try store.persistRegisteredClient(registration.record, secret: registration.clientSecret)
        registrations.removeValue(forKey: item.clientID)
      } catch {
        decision = false
        LocalLogStore.runtime(
          "error", "Could not persist approved DCR client: \(Failure.safe(error).code).")
      }
    }
    item.decidedAt = Date()
    item.approved = decision
    pending[id] = item
    LocalLogStore.runtime(
      "info", "Authorization \(decision ? "approved" : "denied") for client \(item.clientName).")
  }

  private func prunePending() {
    let now = Date()
    registrations = registrations.filter { _, registration in !registration.isExpired }
    pending = pending.filter { _, item in
      if item.isExpired { return false }
      let client = store.client(item.clientID) ?? registrations[item.clientID]?.record
      guard let client, client.isEnabled else { return false }
      if let disabledAt = client.disabledAt, disabledAt >= item.createdAt { return false }
      guard let decided = item.decidedAt else { return true }
      // A decided request is kept just long enough for the browser to collect the
      // redirect it is polling for.
      return now.timeIntervalSince(decided) < OAuthContract.pendingSeconds
    }
    codes = codes.filter { _, code in
      guard now.timeIntervalSince(code.issuedAt) < OAuthContract.codeSeconds,
        let client = store.client(code.clientID), client.isEnabled
      else { return false }
      if let disabledAt = client.disabledAt, disabledAt >= code.issuedAt { return false }
      return true
    }
  }

  // MARK: - /token

  private func token(_ request: HTTPRequest) -> HTTPReply {
    guard spend() else { return oauthError(429, "slow_down", "Too many token requests.") }
    let form = FormBody.parse(String(decoding: request.body, as: UTF8.self))
    guard let record = authenticate(request, form: form) else {
      return refuse(
        401, "invalid_client", "Unknown client, or the wrong client authentication method.",
        "Token request rejected", headers: ["WWW-Authenticate": "Basic realm=\"Luti\""])
    }
    switch form["grant_type"] {
    case "authorization_code": return exchangeCode(form, record: record)
    case "refresh_token": return refresh(form, record: record)
    default:
      return refuse(
        400, "unsupported_grant_type", "Only authorization_code and refresh_token are supported.",
        "Token request from \(record.name) rejected")
    }
  }

  /// The client never picks its own authentication method per request. Metadata
  /// advertises the supported methods, the record fixes one, and a confidential
  /// client that stops sending its secret is rejected rather than downgraded to `none`.
  private func authenticate(_ request: HTTPRequest, form: [String: String]) -> OAuthClientRecord? {
    let authorization = request.headers["authorization"] ?? []
    guard authorization.count <= 1 else { return nil }

    var basic: (clientID: String, secret: String)?
    if let header = authorization.first {
      guard header.count > 6, header.prefix(6).lowercased() == "basic ",
        let data = Data(base64Encoded: String(header.dropFirst(6))),
        let decoded = String(data: data, encoding: .utf8),
        let separator = decoded.firstIndex(of: ":")
      else { return nil }
      basic = (
        String(decoded[..<separator]),
        String(decoded[decoded.index(after: separator)...])
      )
    }

    let formClientID = form["client_id"]
    if let basic, let formClientID, basic.clientID != formClientID { return nil }
    guard let clientID = basic?.clientID ?? formClientID,
      OAuthContract.isWellFormedClientID(clientID),
      let record = store.client(clientID), record.isEnabled
    else { return nil }

    let presented = form["client_secret"].flatMap { $0.isEmpty ? nil : $0 }
    switch record.authMethod {
    case .clientSecretBasic:
      guard let basic, presented == nil,
        let expected = try? store.clientSecret(clientID),
        Budget.constantTimeEqual(basic.secret, expected)
      else { return nil }
    case .clientSecretPost:
      guard basic == nil, formClientID == clientID, let presented,
        let expected = try? store.clientSecret(clientID),
        Budget.constantTimeEqual(presented, expected)
      else { return nil }
    case .none:
      // A public client must not send one. Accepting a stray secret would make the
      // two methods interchangeable, which is exactly the downgrade being avoided.
      guard basic == nil, formClientID == clientID, presented == nil else { return nil }
    }
    return record
  }

  private func exchangeCode(_ form: [String: String], record: OAuthClientRecord) -> HTTPReply {
    prunePending()
    guard let code = form["code"], let issued = codes.removeValue(forKey: OAuthStore.hash(code))
    else {
      return refuse(
        400, "invalid_grant", "The authorization code is unknown, used or expired.",
        "Token request from \(record.name) rejected")
    }
    guard issued.clientID == record.id else {
      return refuse(
        400, "invalid_grant", "The authorization code belongs to another client.",
        "Token request from \(record.name) rejected")
    }
    guard Date().timeIntervalSince(issued.issuedAt) <= OAuthContract.codeSeconds else {
      return refuse(
        400, "invalid_grant", "The authorization code has expired.",
        "Token request from \(record.name) rejected")
    }
    guard form["redirect_uri"] == issued.redirectURI else {
      return refuse(
        400, "invalid_grant", "redirect_uri does not match the authorization.",
        "Token request from \(record.name) rejected")
    }
    guard let verifier = form["code_verifier"],
      OAuthContract.matchesChallenge(verifier: verifier, challenge: issued.codeChallenge)
    else {
      return refuse(
        400, "invalid_grant", "The PKCE code_verifier does not match.",
        "Token request from \(record.name) rejected")
    }
    if let resource = form["resource"], resource != issued.resource {
      return refuse(
        400, "invalid_target", "resource does not match the authorization.",
        "Token request from \(record.name) rejected")
    }
    return issue(
      authorization: issued.authorizationID, client: record, scopes: issued.scopes,
      resource: issued.resource)
  }

  private func refresh(_ form: [String: String], record: OAuthClientRecord) -> HTTPReply {
    guard let presented = form["refresh_token"] else {
      return refuse(
        400, "invalid_request", "refresh_token is required.",
        "Token request from \(record.name) rejected")
    }
    let hash = OAuthStore.hash(presented)
    guard let stored = store.token(hash: hash), stored.kind == .refresh,
      stored.clientID == record.id
    else {
      return refuse(
        400, "invalid_grant", "The refresh token is unknown.",
        "Token request from \(record.name) rejected")
    }
    if stored.rotatedAt != nil {
      // Replay of a token that was already exchanged. Whoever holds it and
      // whoever holds its successor cannot be told apart, so the whole
      // authorization goes.
      store.revokeAuthorization(stored.authorizationID)
      LocalLogStore.runtime(
        "error", "Refresh token replay from client \(record.name); authorization revoked.")
      return oauthError(400, "invalid_grant", "This refresh token was already used.")
    }
    guard stored.isUsable(at: Date()) else {
      return refuse(
        400, "invalid_grant", "The refresh token is revoked or expired.",
        "Token request from \(record.name) rejected")
    }
    if let resource = form["resource"], resource != stored.resource {
      return refuse(
        400, "invalid_target", "resource does not match the authorization.",
        "Token request from \(record.name) rejected")
    }
    if let scope = form["scope"] {
      // Narrowing on refresh is allowed; widening is not, and asking for more
      // than the Mac approved is a request error, not a silent clamp.
      guard let requested = OAuthScope.parse(scope),
        requested.isSubset(of: Set(stored.scopes))
      else {
        return refuse(
        400, "invalid_scope", "A refresh cannot widen the granted scope.",
        "Token request from \(record.name) rejected")
      }
      store.markRotated(hash: hash)
      return issue(
        authorization: stored.authorizationID, client: record, scopes: requested,
        resource: stored.resource)
    }
    store.markRotated(hash: hash)
    return issue(
      authorization: stored.authorizationID, client: record, scopes: Set(stored.scopes),
      resource: stored.resource)
  }

  private func issue(
    authorization: UUID, client: OAuthClientRecord, scopes: Set<OAuthScope>, resource: String
  ) -> HTTPReply {
    let now = Date()
    let access = OAuthContract.newAccessToken()
    let refreshToken = OAuthContract.newRefreshToken()
    let ordered = OAuthScope.allCases.filter { scopes.contains($0) }
    do {
      try store.insert([
        StoredToken(
          hash: OAuthStore.hash(access), kind: .access, clientID: client.id,
          authorizationID: authorization, resource: resource, scopes: ordered, createdAt: now,
          expiresAt: now.addingTimeInterval(OAuthContract.accessSeconds)),
        StoredToken(
          hash: OAuthStore.hash(refreshToken), kind: .refresh, clientID: client.id,
          authorizationID: authorization, resource: resource, scopes: ordered, createdAt: now,
          expiresAt: now.addingTimeInterval(OAuthContract.refreshSeconds)),
      ])
    } catch {
      return refuse(
        500, "server_error", "The authorization store is unavailable.",
        "Token request from \(client.name) rejected")
    }
    store.markClientUsed(client.id, at: now)
    return json(200, [
      "access_token": .string(access),
      "token_type": "Bearer",
      "expires_in": .int(Int(OAuthContract.accessSeconds)),
      "refresh_token": .string(refreshToken),
      "scope": .string(ordered.map(\.rawValue).joined(separator: " ")),
    ])
  }

  // MARK: - /revoke

  /// RFC 7009: an unknown token is a success. Saying "no such token" would turn
  /// this endpoint into an oracle for guessing them.
  private func revoke(_ request: HTTPRequest) -> HTTPReply {
    guard spend() else { return oauthError(429, "slow_down", "Too many revocation requests.") }
    let form = FormBody.parse(String(decoding: request.body, as: UTF8.self))
    guard let record = authenticate(request, form: form) else {
      return refuse(
        401, "invalid_client", "Unknown client, or the wrong client authentication method.",
        "Revocation rejected")
    }
    if let presented = form["token"], let stored = store.token(hash: OAuthStore.hash(presented)),
      stored.clientID == record.id
    {
      store.revokeAuthorization(stored.authorizationID)
      LocalLogStore.runtime("info", "Client \(record.name) revoked one of its authorizations.")
    }
    return json(200, [:])
  }

  // MARK: - Bearer verification

  /// Called for every `/mcp` request that did not present the local bearer. It is
  /// a hash lookup, so a stolen store still does not yield a usable token.
  public func verify(bearer: String) -> RequestContext? {
    guard !stopped, bearer.hasPrefix(OAuthContract.accessPrefix) else { return nil }
    let now = Date()
    guard let stored = store.token(hash: OAuthStore.hash(bearer)), stored.kind == .access,
      stored.isUsable(at: now), stored.resource == resourceIdentifier,
      let client = store.client(stored.clientID), client.isEnabled
    else { return nil }
    store.markUsed(hash: stored.hash, at: now)
    return RequestContext(
      transport: transport, clientID: client.id, clientName: client.name,
      authorizationID: stored.authorizationID, scopes: Set(stored.scopes),
      resource: stored.resource)
  }

  // MARK: - Replies

  private func json(_ status: Int, _ value: JSONValue, headers: [String: String] = [:]) -> HTTPReply
  {
    HTTPReply(
      status: status, body: (try? value.data()) ?? Data(),
      headers: ["Content-Type": "application/json", "Cache-Control": "no-store"].merging(
        headers, uniquingKeysWith: { _, b in b }))
  }

  private func oauthError(
    _ status: Int, _ code: String, _ description: String, headers: [String: String] = [:]
  ) -> HTTPReply {
    json(
      status, ["error": .string(code), "error_description": .string(description)], headers: headers)
  }

  /// An OAuth error the Mac's owner also needs to see. A Host reports only its own
  /// generic failure, so without this line a refused connection has no explanation
  /// anywhere. `description` is a fixed string and never carries a credential.
  private func refuse(
    _ status: Int, _ code: String, _ description: String, _ context: String,
    headers: [String: String] = [:]
  ) -> HTTPReply {
    LocalLogStore.runtime("error", "\(context): \(description)")
    return oauthError(status, code, description, headers: headers)
  }

  private func redirect(to target: String, parameters: [String: String?]) -> HTTPReply {
    var query: [String] = []
    for key in ["code", "error", "error_description", "state", "iss"] {
      guard let value = parameters[key] ?? nil else { continue }
      // `state` is already in wire form and must not be encoded a second time.
      query.append(key + "=" + (key == "state" ? value : FormBody.encode(value)))
    }
    let separator = target.contains("?") ? "&" : "?"
    return HTTPReply(
      status: 302,
      headers: [
        "Location": target + separator + query.joined(separator: "&"),
        "Cache-Control": "no-store",
      ])
  }

  private func waiting(
    _ id: UUID,
    client: String,
    language: OAuthPageLanguage
  ) -> HTTPReply {
    html(
      200,
      title: "Luti",
      heading: language.waitingHeading,
      body: language.waitingBody(client: client),
      refresh: "\(Paths.authorizeWait)?id=\(id.uuidString)",
      language: language)
  }

  private func page(_ status: Int, _ message: String) -> HTTPReply {
    html(
      status, title: "Luti", heading: "Luti", body: message, refresh: nil,
      language: .english)
  }

  /// Plain, self-contained HTML: no script, no external stylesheet, no font. This
  /// page is served to a browser that has not authenticated anything yet.
  private func html(
    _ status: Int,
    title: String,
    heading: String,
    body: String,
    refresh: String?,
    language: OAuthPageLanguage
  ) -> HTTPReply {
    let meta = refresh.map { "<meta http-equiv=\"refresh\" content=\"2;url=\(escape($0))\">" } ?? ""
    let document = """
      <!DOCTYPE html><html lang="\(language.rawValue)"><head><meta charset="utf-8">\
      <meta name="viewport" content="width=device-width,initial-scale=1">\
      <meta name="referrer" content="no-referrer">\(meta)<title>\(escape(title))</title>\
      <style>:root{color-scheme:light dark}\
      body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;\
      font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;\
      background:#faf8fd;color:#1c1b1f}\
      @media(prefers-color-scheme:dark){body{background:#131316;color:#e6e1e9}}\
      main{max-width:30rem;padding:2rem;text-align:center}\
      h1{font-size:1.25rem;font-weight:600;margin:0 0 .75rem}\
      p{margin:0;opacity:.75}</style></head>\
      <body><main><h1>\(escape(heading))</h1><p>\(escape(body))</p></main></body></html>
      """
    return HTTPReply(
      status: status, body: Data(document.utf8),
      headers: [
        "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
        "Content-Language": language.rawValue,
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
      ])
  }

  private func escape(_ value: String) -> String {
    var out = ""
    for character in value.unicodeScalars.prefix(512) {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&#39;"
      default: out.unicodeScalars.append(character)
      }
    }
    return out
  }
}

/// `application/x-www-form-urlencoded`, used for both query strings and POST
/// bodies. Foundation's URL parsing is not usable here: it leaves `+` alone, and
/// in this encoding `+` is a space.
public enum FormBody {
  public static func parse(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in raw.split(separator: "&", omittingEmptySubsequences: true).prefix(32) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let name = decode(String(parts[0])), !name.isEmpty else { continue }
      let value = parts.count == 2 ? decode(String(parts[1])) : ""
      guard let value, value.utf8.count <= 4096 else { continue }
      // First value wins: a repeated parameter is a smuggling attempt, not input.
      if result[name] == nil { result[name] = value }
    }
    return result
  }

  /// The value exactly as it appeared on the wire, still percent-encoded, or nil
  /// when the name is absent. Only `state` needs this: OAuth requires it to come
  /// back byte-identical, and a decode/encode round trip does not preserve bytes.
  public static func rawValue(_ name: String, in raw: String) -> String? {
    for pair in raw.split(separator: "&", omittingEmptySubsequences: true).prefix(32) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      // First value wins, matching `parse`.
      guard decode(String(parts[0])) == name else { continue }
      return parts.count == 2 ? String(parts[1]) : ""
    }
    return nil
  }

  /// The RFC 3986 query characters, minus `&` because it separates pairs here and
  /// `#` because it would turn the rest of a Location header into a fragment. A
  /// value that really arrived in a query string already satisfies this.
  public static func isWireSafe(_ value: String) -> Bool {
    value.utf8.allSatisfy(wireSafe.contains)
  }

  private static let wireSafe: Set<UInt8> = Set(
    ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
      + "-._~!$'()*+,;=:@/?%").utf8)

  public static func decode(_ value: String) -> String? {
    var bytes: [UInt8] = []
    var iterator = Array(value.utf8).makeIterator()
    while let byte = iterator.next() {
      switch byte {
      case UInt8(ascii: "+"): bytes.append(UInt8(ascii: " "))
      case UInt8(ascii: "%"):
        guard let high = iterator.next(), let low = iterator.next(),
          let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
        else { return nil }
        bytes.append(value)
      default: bytes.append(byte)
      }
    }
    return String(bytes: bytes, encoding: .utf8)
  }

  public static func encode(_ value: String) -> String {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    var out = ""
    for byte in value.utf8 {
      if unreserved.contains(byte) {
        out.unicodeScalars.append(UnicodeScalar(byte))
      } else {
        out += String(format: "%%%02X", byte)
      }
    }
    return out
  }
}
