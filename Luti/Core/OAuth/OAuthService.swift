import Foundation

/// One issuer for this Mac's Luti instance. No global singleton, background
/// timer, network metadata fetch, or per-request Keychain lookup. Only hashes of
/// high-entropy credentials are persisted; native consent is the sole grant path.
public actor OAuthService {
  private struct State: Codable {
    var version = 1
    let resource: String
    var clients: [OAuthClient] = []
    var grants: [OAuthGrant] = []
  }
  private struct Code {
    let grantID: UUID
    let clientID: String
    let redirect: String
    let challenge: String
    let expiresAt: Date
  }
  public nonisolated let origin: URL
  public nonisolated var resource: String { origin.absoluteString + "/mcp" }
  public nonisolated var metadataURL: String { origin.absoluteString + "/.well-known/oauth-protected-resource/mcp" }
  private let file: URL?
  private let now: @Sendable () -> Date
  private var state: State
  private var registrations: [String: OAuthClient] = [:]
  private var pending: [UUID: OAuthPending] = [:]
  private var codes: [String: Code] = [:]
  private var enabled = true
  private var credits = 60.0
  private var tokenCredits = 60.0
  private var registrationCredits = 8.0
  private var creditTime: Date

  init(origin: URL, file: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
    self.origin = try CloudflareContract.origin(origin.absoluteString)
    self.file = file
    self.now = now
    creditTime = now()
    let resource = self.origin.absoluteString + "/mcp"
    if let file {
      try PrivateFiles.directory(file.deletingLastPathComponent())
      if try PrivateFiles.exists(file) {
        let loaded = try JSONCoding.decode(State.self, PrivateFiles.read(file, max: 4_194_304))
        guard loaded.version == 1, loaded.resource == resource,
          loaded.clients.count <= 64, loaded.grants.count <= 32,
          loaded.grants.allSatisfy({ $0.spentRefreshHashes.count <= 1024 })
        else { throw Failure.invalid("The saved Cloudflare authorizations do not match this domain.") }
        state = loaded
        return
      }
    }
    state = State(resource: resource)
  }

  func snapshot() -> OAuthSnapshot {
    prune()
    let applications = state.grants.filter { $0.expiresAt > now() }.compactMap { grant -> OAuthApplication? in
      guard let client = state.clients.first(where: { $0.id == grant.clientID }) else { return nil }
      return OAuthApplication(id: grant.id, name: client.name,
        callbackHost: URL(string: client.redirects.first ?? "")?.host ?? "",
        createdAt: grant.createdAt)
    }.sorted { $0.createdAt > $1.createdAt }
    return OAuthSnapshot(pending: pending.values.filter { $0.outcome == nil }.sorted { $0.createdAt < $1.createdAt },
                         applications: applications)
  }

  public func shutdown() {
    enabled = false
    registrations.removeAll()
    pending.removeAll()
    codes.removeAll()
  }

  /// Called only from the native UI. There is deliberately no HTTP approval route.
  func decide(_ id: UUID, allow: Bool) throws {
    prune()
    guard enabled else { throw Failure.stopped }
    guard var request = pending[id], request.outcome == nil else {
      throw Failure.invalid("This authorization request has expired or was replaced by a newer request.")
    }
    if allow {
      var draft = state
      draft.grants.removeAll { $0.expiresAt <= now() || $0.clientID == request.client.id }
      if !draft.clients.contains(where: { $0.id == request.client.id }) {
        if draft.clients.count >= 64 {
          draft.clients.removeAll { client in !draft.grants.contains { $0.clientID == client.id } }
        }
        guard draft.clients.count < 64 else { throw Failure.invalid("Remove an authorized app before adding another.") }
        draft.clients.append(request.client)
      }
      guard draft.grants.count < 32, codes.count < 32 else { throw Failure.invalid("Too many authorizations. Try again later.") }
      let grant = OAuthGrant(id: UUID(), clientID: request.client.id, createdAt: now(),
        expiresAt: now().addingTimeInterval(OAuthContract.grantSeconds))
      draft.grants.append(grant)
      try commit(draft)
      let code = Budget.token()
      codes[OAuthContract.hash(code)] = Code(grantID: grant.id, clientID: request.client.id,
        redirect: request.redirect, challenge: request.challenge, expiresAt: now().addingTimeInterval(60))
      request.outcome = code
      registrations.removeValue(forKey: request.client.id)
    } else {
      request.outcome = "denied"
    }
    pending[id] = request
  }

  func revoke(_ id: UUID) throws {
    var draft = state
    draft.grants.removeAll { $0.id == id }
    try commit(draft)
    codes = codes.filter { $0.value.grantID != id }
  }

  func grant(for bearer: String) -> ToolGrant? {
    authenticate(bearer).grant
  }

  func authenticate(_ bearer: String) -> (grant: ToolGrant?, reason: String) {
    guard enabled else { return (nil, "oauth_stopped") }
    let count = bearer.utf8.count
    let hash = OAuthContract.hash(bearer)
    let prefix = String(hash.prefix(12))
    guard (32...256).contains(count) else {
      return (nil, "bearer_length_invalid(bytes=\(count),presented_sha256=\(prefix))")
    }
    let active = state.grants.filter { $0.expiresAt > now() && $0.accessExpiresAt > now() }
    if let grant = active.first(where: { Budget.constantTimeEqual($0.accessHash, hash) }),
      let client = state.clients.first(where: { $0.id == grant.clientID })
    {
      return (.remote(RequestContext(transport: .cloudflare, clientID: client.id,
        clientName: client.name, authorizationID: grant.id)), "")
    }
    // Never echo active grants' hashes: this reason reaches unauthenticated callers.
    return (nil, "bearer_hash_mismatch(bytes=\(count),presented_sha256=\(prefix))")
  }

  private func validResource(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return true }
    let trimmed = value.hasSuffix("/") ? String(value.dropLast()) : value
    return trimmed == resource || trimmed == origin.absoluteString
  }

  private func commit(_ draft: State) throws {
    if let file {
      let data = try JSONCoding.encode(draft)
      guard data.count <= 4_194_304 else { throw Failure.invalid("Authorization storage is full.") }
      try PrivateFiles.atomicWrite(data, to: file)
    }
    state = draft
  }

  private func prune() {
    let date = now()
    pending = pending.filter { date.timeIntervalSince($0.value.createdAt) < OAuthContract.pendingSeconds }
    registrations = registrations.filter { date.timeIntervalSince($0.value.createdAt) < 3600 }
    codes = codes.filter { $0.value.expiresAt > date }
  }

  func handle(_ request: HTTPRequest) -> HTTPReply {
    guard enabled else { return failure(503, "temporarily_unavailable") }
    guard request.body.count <= 16_384, request.path.utf8.count <= 16_384 else { return HTTPReply(status: 413) }
    prune()
    let path = String(request.path.prefix(while: { $0 != "?" }))
    let readOnly = path.hasPrefix("/.well-known/") || ["/oauth/authorize", "/oauth/wait"].contains(path)
    guard request.method == (readOnly ? "GET" : "POST") else {
      return HTTPReply(status: 405, headers: ["Allow": readOnly ? "GET" : "POST"])
    }
    let elapsed = max(0, now().timeIntervalSince(creditTime))
    creditTime = now()
    credits = min(60, credits + elapsed * 10)
    tokenCredits = min(60, tokenCredits + elapsed * 10)
    registrationCredits = min(8, registrationCredits + elapsed / 10)
    if path == "/oauth/register" {
      guard registrationCredits >= 1, registrations.count < 64 else {
        return failure(429, "temporarily_unavailable", extra: ["Retry-After": "10"])
      }
      registrationCredits -= 1
    } else if path == "/oauth/token" || path == "/oauth/revoke" {
      guard tokenCredits >= 1 else {
        return failure(429, "temporarily_unavailable", extra: ["Retry-After": "5"])
      }
      tokenCredits -= 1
    } else {
      guard credits >= 1 else {
        return failure(429, "temporarily_unavailable", extra: ["Retry-After": "5"])
      }
      credits -= 1
    }
    if path.hasPrefix("/.well-known/oauth-protected-resource") {
      return json(200, ["resource": .string(resource), "authorization_servers": [.string(origin.absoluteString)],
        "scopes_supported": ["mcp"], "bearer_methods_supported": ["header"]])
    }
    if path.hasPrefix("/.well-known/oauth-authorization-server") {
      let base = origin.absoluteString
      return json(200, ["issuer": .string(base), "authorization_endpoint": .string(base + "/oauth/authorize"),
        "token_endpoint": .string(base + "/oauth/token"), "registration_endpoint": .string(base + "/oauth/register"),
        "revocation_endpoint": .string(base + "/oauth/revoke"), "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"], "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none", "client_secret_post", "client_secret_basic"],
        "scopes_supported": ["mcp"], "authorization_response_iss_parameter_supported": true])
    }
    do {
      if path == "/oauth/register" { return try register(request) }
      let raw: String
      if readOnly { raw = String(request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first ?? "") }
      else {
        guard request.headers["content-type"]?.first?.split(separator: ";").first?.lowercased() == "application/x-www-form-urlencoded",
          let text = String(data: request.body, encoding: .utf8)
        else { return failure(415, "invalid_request") }
        raw = text
      }
      let form = try OAuthContract.form(raw)
      switch path {
      case "/oauth/authorize": return try authorize(form)
      case "/oauth/wait": return wait(form)
      case "/oauth/token", "/oauth/revoke": return try exchange(form, headers: request.headers, revoke: path == "/oauth/revoke")
      default: return HTTPReply(status: 404)
      }
    } catch { return failure(400, "invalid_request") }
  }

  private func register(_ request: HTTPRequest) throws -> HTTPReply {
    guard request.headers["content-type"]?.first?.split(separator: ";").first?.lowercased() == "application/json" else {
      return failure(415, "invalid_request")
    }
    let body = try JSONValue.decode(request.body)
    let displayName = body["client_name"] == .null ? "MCP client" : body["client_name"].string
    guard let name = displayName, (1...80).contains(name.utf8.count),
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let values = body["redirect_uris"].array, (1...8).contains(values.count),
      values.allSatisfy({ $0.string.map(OAuthContract.validRedirect) == true })
    else { return failure(400, "invalid_client_metadata") }
    let method = body["token_endpoint_auth_method"].string ?? "client_secret_basic"
    guard ["none", "client_secret_post", "client_secret_basic"].contains(method),
      body["scope"] == .null || body["scope"] == "mcp",
      body["response_types"] == .null || body["response_types"] == ["code"],
      body["grant_types"] == .null || (body["grant_types"].array?.allSatisfy({
        $0 == "authorization_code" || $0 == "refresh_token"
      }) == true)
    else { return failure(400, "invalid_client_metadata") }
    let secret = method == "none" ? nil : Budget.token()
    let client = OAuthClient(id: "luti_" + Budget.token(), name: name,
      redirects: values.compactMap(\.string), authMethod: method,
      secretHash: secret.map(OAuthContract.hash), createdAt: now())
    registrations[client.id] = client
    var response: JSONValue = ["client_id": .string(client.id), "client_name": .string(name),
      "redirect_uris": .array(values), "token_endpoint_auth_method": .string(method),
      "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "scope": "mcp"]
    if let secret { response = response.adding("client_secret", .string(secret)).adding("client_secret_expires_at", 0) }
    return json(201, response)
  }

  private func authorize(_ form: [String: String]) throws -> HTTPReply {
    guard let id = form["client_id"], let client = client(id),
      let redirect = form["redirect_uri"], client.redirects.contains(redirect)
    else { return failure(400, "invalid_client") }
    guard form["response_type"] == "code", form["code_challenge_method"] == "S256",
      let challenge = form["code_challenge"], challenge.utf8.count == 43,
      challenge.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
      validResource(form["resource"]), form["scope"] == nil || form["scope"] == "mcp"
    else { return redirectReply(redirect, state: form["state"], result: "error", value: "invalid_request") }
    // A re-attempt from the same client replaces its previous undecided request so
    // a user who closed the browser tab can reconnect immediately while still holding at most 1 slot.
    pending = pending.filter { !($0.value.client.id == client.id && $0.value.outcome == nil) }
    guard pending.count < 16 else { return failure(429, "temporarily_unavailable", extra: ["Retry-After": "5"]) }
    let ticket = Budget.token()
    let request = OAuthPending(id: UUID(), client: client, redirect: redirect, state: form["state"],
      challenge: challenge, createdAt: now(), verification: String(Int.random(in: 100_000...999_999)),
      ticketHash: OAuthContract.hash(ticket))
    pending[request.id] = request
    return HTTPReply(status: 303, headers: ["Location": "/oauth/wait?ticket=" + ticket,
      "Cache-Control": "no-store", "Referrer-Policy": "no-referrer"])
  }

  private func wait(_ form: [String: String]) -> HTTPReply {
    guard let ticket = form["ticket"], ticket.utf8.count == 64,
      let entry = pending.first(where: { Budget.constantTimeEqual($0.value.ticketHash, OAuthContract.hash(ticket)) })
    else { return page("Request expired", detail: "Return to your AI client and connect again.") }
    let request = entry.value
    if let outcome = request.outcome {
      pending.removeValue(forKey: entry.key)
      return redirectReply(request.redirect, state: request.state,
        result: outcome == "denied" ? "error" : "code", value: outcome == "denied" ? "access_denied" : outcome)
    }
    return page("Approve in Luti on your Mac", detail: "\(request.client.name) is requesting access. Match code \(request.verification) in Luti before choosing Allow.",
                refresh: "/oauth/wait?ticket=" + ticket)
  }

  private func client(_ id: String) -> OAuthClient? {
    state.clients.first { $0.id == id } ?? registrations[id]
  }

  private func exchange(_ form: [String: String], headers: [String: [String]], revoke: Bool) throws -> HTTPReply {
    var id = form["client_id"], secret = form["client_secret"]
    let basic = headers["authorization"]?.first
    if let basic {
      guard secret == nil, basic.hasPrefix("Basic "),
        let data = Data(base64Encoded: String(basic.dropFirst(6))), let decoded = String(data: data, encoding: .utf8),
        let colon = decoded.firstIndex(of: ":") else { return failure(401, "invalid_client") }
      let basicID = String(decoded[..<colon]).removingPercentEncoding
      guard id == nil || id == basicID else { return failure(401, "invalid_client") }
      id = basicID
      secret = String(decoded[decoded.index(after: colon)...]).removingPercentEncoding
    }
    guard let id, let client = client(id) else { return failure(401, "invalid_client") }
    switch client.authMethod {
    case "none": guard basic == nil, secret == nil else { return failure(401, "invalid_client") }
    case "client_secret_basic", "client_secret_post":
      guard (basic != nil) == (client.authMethod == "client_secret_basic"), let secret, let expected = client.secretHash,
        Budget.constantTimeEqual(OAuthContract.hash(secret), expected) else { return failure(401, "invalid_client") }
    default: return failure(401, "invalid_client")
    }
    if revoke {
      if let token = form["token"] {
        let hash = OAuthContract.hash(token)
        if let grant = state.grants.first(where: { $0.clientID == id && ($0.accessHash == hash || $0.refreshHash == hash) }) {
          try self.revoke(grant.id)
        }
      }
      return json(200, [:])
    }
    guard validResource(form["resource"]) else { return failure(400, "invalid_target") }
    if form["grant_type"] == "authorization_code" {
      guard let raw = form["code"], let code = codes.removeValue(forKey: OAuthContract.hash(raw)),
        code.clientID == id, code.redirect == form["redirect_uri"], code.expiresAt > now(),
        let verifier = form["code_verifier"], OAuthContract.validVerifier(verifier),
        Budget.constantTimeEqual(OAuthContract.challenge(verifier), code.challenge),
        let index = state.grants.firstIndex(where: { $0.id == code.grantID && $0.expiresAt > now() })
      else { return failure(400, "invalid_grant") }
      return try issue(index)
    }
    guard form["grant_type"] == "refresh_token", let refresh = form["refresh_token"],
      form["scope"] == nil || form["scope"] == "mcp" else { return failure(400, "invalid_request") }
    let hash = OAuthContract.hash(refresh)
    // Keep spent hashes for this family's fixed 30-day lifetime. A replay revokes
    // the whole family, including its latest access token. Never evict a live hash.
    if let reused = state.grants.first(where: { $0.clientID == id && $0.spentRefreshHashes.contains(hash) }) {
      try self.revoke(reused.id)
      return failure(400, "invalid_grant")
    }
    guard let index = state.grants.firstIndex(where: {
      $0.clientID == id && $0.expiresAt > now() && Budget.constantTimeEqual($0.refreshHash, hash)
    }) else { return failure(400, "invalid_grant") }
    if state.grants[index].spentRefreshHashes.count >= 1024 {
      try self.revoke(state.grants[index].id)
      return failure(400, "invalid_grant")
    }
    return try issue(index)
  }

  private func issue(_ index: Int) throws -> HTTPReply {
    let access = Budget.token(), refresh = Budget.token()
    let accessHash = OAuthContract.hash(access)
    var draft = state
    if !draft.grants[index].refreshHash.isEmpty { draft.grants[index].spentRefreshHashes.append(draft.grants[index].refreshHash) }
    draft.grants[index].accessHash = accessHash
    draft.grants[index].accessExpiresAt = now().addingTimeInterval(OAuthContract.accessSeconds)
    draft.grants[index].refreshHash = OAuthContract.hash(refresh)
    try commit(draft)
    LocalLogStore.runtime("info", "OAuth issued access_sha256=\(accessHash.prefix(12)) client=\(draft.grants[index].clientID.prefix(17))")
    return json(200, ["access_token": .string(access), "token_type": "Bearer", "expires_in": 3600,
      "refresh_token": .string(refresh), "scope": "mcp"])
  }

  private func redirectReply(_ uri: String, state: String?, result: String, value: String) -> HTTPReply {
    var components = URLComponents(string: uri)!
    var items = [(result, value), ("iss", origin.absoluteString)]
    if let state { items.append(("state", state)) }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let encoded = items.map { key, value in key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
    components.percentEncodedQuery = [components.percentEncodedQuery, encoded].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
    return HTTPReply(status: 303, headers: ["Location": components.url!.absoluteString,
      "Cache-Control": "no-store", "Referrer-Policy": "no-referrer"])
  }

  private func json(_ status: Int, _ body: JSONValue, extra: [String: String] = [:]) -> HTTPReply {
    HTTPReply(status: status, body: (try? body.data()) ?? Data(),
      headers: ["Content-Type": "application/json", "Cache-Control": "no-store"].merging(extra) { _, b in b })
  }
  private func failure(_ status: Int, _ error: String, extra: [String: String] = [:]) -> HTTPReply {
    json(status, ["error": .string(error)], extra: extra)
  }
  private func page(_ title: String, detail: String, refresh: String? = nil) -> HTTPReply {
    func escape(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    let meta = refresh.map { "<meta http-equiv=\"refresh\" content=\"2;url=\(escape($0))\">" } ?? ""
    let html = """
      <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
      <title>Luti — Local approval</title>\(meta)<style>body{font:17px/1.6 system-ui;margin:12vh auto;padding:24px;max-width:520px;color:#27332f;background:#fff}h1{font-size:28px}p{overflow-wrap:anywhere}</style>
      <h1>\(escape(title))</h1><p>\(escape(detail))</p><p>Requests expire after five minutes.</p></html>
      """
    return HTTPReply(status: 200, body: Data(html.utf8), headers: ["Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"])
  }
}
