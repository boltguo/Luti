import Foundation
import XCTest

@testable import Luti

private struct OAuthSeedState: Codable {
  let schemaVersion: Int
  let clients: [OAuthClientRecord]
  let tokens: [StoredToken]
}

final class OAuthTests: XCTestCase {
  private let issuer = URL(string: "https://mcp.example.com")!
  private let redirectURI = "https://client.example/callback"

  private func temporaryStore(client: OAuthClientRecord? = nil) throws -> (OAuthStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "luti-oauth-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("oauth.json")
    if let client {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(
        OAuthSeedState(schemaVersion: 1, clients: [client], tokens: []))
      try data.write(to: url, options: .atomic)
    }
    return (OAuthStore(url: url), directory)
  }

  private func request(
    _ method: String, _ path: String, body: String = "", host: String = "mcp.example.com",
    contentType: String = "application/x-www-form-urlencoded", authorization: String? = nil,
    acceptLanguage: String? = nil
  ) -> HTTPRequest {
    var headers: [String: [String]] = ["Host": [host]]
    if method == "POST" {
      headers["Content-Type"] = [contentType]
    }
    if let authorization { headers["Authorization"] = [authorization] }
    if let acceptLanguage { headers["Accept-Language"] = [acceptLanguage] }
    return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
  }

  private func form(_ values: [(String, String)]) -> String {
    values.map { FormBody.encode($0.0) + "=" + FormBody.encode($0.1) }.joined(separator: "&")
  }

  private func queryValue(_ name: String, in location: String) throws -> String {
    let components = try XCTUnwrap(URLComponents(string: location))
    return try XCTUnwrap(components.queryItems?.first { $0.name == name }?.value)
  }

  private func pendingFlow(_ oauth: LutiOAuthService) async throws -> (PendingAuthorization, String) {
    let registration: JSONValue = [
      "client_name": "Lifecycle test", "redirect_uris": [.string(redirectURI)],
      "token_endpoint_auth_method": "none",
    ]
    let registered = await oauth.handle(request("POST", LutiOAuthService.Paths.register,
      body: String(decoding: try registration.data(), as: UTF8.self), contentType: "application/json"))
    XCTAssertEqual(registered.status, 201)
    let clientID = try XCTUnwrap(registered.json["client_id"].string)
    let verifier = String(repeating: "l", count: 43)
    let query = form([
      ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI),
      ("code_challenge", OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))),
      ("code_challenge_method", "S256"), ("scope", "project:read"),
      ("resource", oauth.resourceIdentifier),
    ])
    let response = await oauth.handle(request("GET", LutiOAuthService.Paths.authorize + "?" + query))
    XCTAssertEqual(response.status, 200)
    let approvals = await oauth.pendingApprovals()
    return (try XCTUnwrap(approvals.first), verifier)
  }

  private func codeRequest(_ oauth: LutiOAuthService, pending: PendingAuthorization,
                           verifier: String) async throws -> HTTPRequest {
    await oauth.resolve(pending.id, approved: true)
    let redirect = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
    XCTAssertEqual(redirect.status, 302)
    let code = try queryValue("code", in: XCTUnwrap(redirect.headers["Location"]))
    return request("POST", LutiOAuthService.Paths.token, body: form([
      ("grant_type", "authorization_code"), ("client_id", pending.clientID), ("code", code),
      ("redirect_uri", redirectURI), ("code_verifier", verifier), ("resource", oauth.resourceIdentifier),
    ]))
  }

  func testShutdownRejectsLateApprovalAndRetiresPendingRegistration() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let (pending, _) = try await pendingFlow(oauth)
    await oauth.shutdown()
    await oauth.shutdown()
    await oauth.resolve(pending.id, approved: true)
    XCTAssertNil(store.client(pending.clientID))
    let approvals = await oauth.pendingApprovals()
    XCTAssertTrue(approvals.isEmpty)
    let response = await oauth.handle(request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
    XCTAssertEqual(response.status, 503)
    XCTAssertEqual(response.headers["Cache-Control"], "no-store")
  }

  func testWaitingPageUsesBrowserPreferredLanguage() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let (pending, _) = try await pendingFlow(oauth)
    let path = LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString

    let cases = [
      (
        "en-US;q=0.2, zh-CN;q=0.9",
        "zh-Hans",
        "正在等待你在 Mac 上批准\u{2026}",
        "Lifecycle test 正在请求访问。请打开 Luti 并选择“允许”。"
      ),
      (
        "ja-JP, en;q=0.8",
        "ja",
        "Macでの承認を待っています\u{2026}",
        "Lifecycle testがアクセスを求めています。Lutiを開いて「許可」を選択してください。"
      ),
      (
        "fr-FR",
        "en",
        "Waiting for approval on your Mac\u{2026}",
        "Lifecycle test is requesting access. Open Luti and choose Allow."
      ),
    ]

    for (acceptLanguage, language, heading, body) in cases {
      let response = await oauth.handle(
        request("GET", path, acceptLanguage: acceptLanguage))
      let document = String(decoding: response.body, as: UTF8.self)
      XCTAssertEqual(response.status, 200)
      XCTAssertEqual(response.headers["Content-Language"], language)
      XCTAssertTrue(document.contains("<html lang=\"\(language)\">"))
      XCTAssertTrue(document.contains(heading))
      XCTAssertTrue(document.contains(body))
    }
  }

  func testReconnectCannotRedeemAnUnfinishedAuthorizationCode() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let (pending, verifier) = try await pendingFlow(oauth)
    let exchange = try await codeRequest(oauth, pending: pending, verifier: verifier)
    await oauth.shutdown()
    let closed = await oauth.handle(exchange)
    XCTAssertEqual(closed.status, 503)
    let next = LutiOAuthService(issuer: issuer, store: store)
    let replay = await next.handle(exchange)
    XCTAssertEqual(replay.status, 400)
    XCTAssertEqual(replay.json["error"], "invalid_grant")
    XCTAssertNotNil(store.client(pending.clientID))
  }

  func testReconnectPreservesApprovedClientsAndUsableGrants() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let (pending, verifier) = try await pendingFlow(oauth)
    let exchange = try await codeRequest(oauth, pending: pending, verifier: verifier)
    let issued = await oauth.handle(exchange)
    XCTAssertEqual(issued.status, 200)
    let access = try XCTUnwrap(issued.json["access_token"].string)
    let refresh = try XCTUnwrap(issued.json["refresh_token"].string)
    await oauth.shutdown()
    let retired = await oauth.verify(bearer: access)
    XCTAssertNil(retired)
    let next = LutiOAuthService(issuer: issuer, store: store)
    let restored = await next.verify(bearer: access)
    XCTAssertEqual(restored?.clientID, pending.clientID)
    let renewed = await next.handle(request("POST", LutiOAuthService.Paths.token, body: form([
      ("grant_type", "refresh_token"), ("client_id", pending.clientID),
      ("refresh_token", refresh), ("resource", next.resourceIdentifier),
    ])))
    XCTAssertEqual(renewed.status, 200)
    XCTAssertNotNil(store.client(pending.clientID))
  }

  func testDiscoveryChallengeAndDynamicRegistrationMetadata() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let router = try f.router()
    let dispatcher = MCPDispatcher(
      authentication: .remote(publicHost: issuer.host!, oauth: oauth),
      port: TunnelContract.defaultPort, router: router)

    let resource = await dispatcher.handle(
      request("GET", LutiOAuthService.Paths.protectedResource))
    XCTAssertEqual(resource.status, 200)
    XCTAssertEqual(resource.headers["Cache-Control"], "no-store")
    XCTAssertEqual(resource.json["resource"], "https://mcp.example.com/mcp")
    XCTAssertEqual(
      resource.json["authorization_servers"].array?.first, "https://mcp.example.com")

    for path in [
      LutiOAuthService.Paths.authorizationServer,
      LutiOAuthService.Paths.authorizationServerMCP,
    ] {
      let metadata = await dispatcher.handle(request("GET", path))
      XCTAssertEqual(metadata.status, 200)
      XCTAssertEqual(metadata.json["issuer"], "https://mcp.example.com")
      XCTAssertEqual(
        metadata.json["authorization_endpoint"], "https://mcp.example.com/authorize")
      XCTAssertEqual(
        metadata.json["registration_endpoint"], "https://mcp.example.com/register")
      XCTAssertEqual(
        metadata.json["token_endpoint_auth_methods_supported"].array,
        [.string("client_secret_basic"), .string("client_secret_post"), .string("none")])
    }

    let challenge = await dispatcher.handle(request("POST", "/mcp"))
    XCTAssertEqual(challenge.status, 401)
    XCTAssertTrue(
      challenge.headers["WWW-Authenticate"]?.contains(
        "resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource/mcp\"")
        == true)

    await router.stop()
  }

  func testDynamicRegistrationStaysTransientUntilNativeApproval() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    let callback = "https://chatgpt.com/connector/oauth/callback"
    let invalidRegistration: JSONValue = [
      "client_name": "Fake\nChatGPT",
      "redirect_uris": .array([.string(callback)]),
      "token_endpoint_auth_method": "none",
    ]
    let invalidBody = String(decoding: try invalidRegistration.data(), as: UTF8.self)
    let invalid = await oauth.handle(
      request(
        "POST", LutiOAuthService.Paths.register, body: invalidBody,
        contentType: "application/json"))
    XCTAssertEqual(invalid.status, 400)
    XCTAssertTrue(store.clients.isEmpty)

    let registration: JSONValue = [
      "client_name": "ChatGPT",
      "redirect_uris": .array([.string(callback)]),
      "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
      "response_types": .array([.string("code")]),
      "token_endpoint_auth_method": "none",
      "application_type": "web",
    ]
    let registrationBody = String(decoding: try registration.data(), as: UTF8.self)
    let registered = await oauth.handle(
      request(
        "POST", LutiOAuthService.Paths.register, body: registrationBody,
        contentType: "application/json"))
    XCTAssertEqual(registered.status, 201)
    let clientID = try XCTUnwrap(registered.json["client_id"].string)
    XCTAssertTrue(OAuthContract.isWellFormedClientID(clientID))
    XCTAssertNotNil(registered.json["client_id_issued_at"].int)
    XCTAssertEqual(registered.json["token_endpoint_auth_method"], "none")
    XCTAssertTrue(store.clients.isEmpty)

    let verifier = String(repeating: "r", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let authorizeQuery = form([
      ("response_type", "code"),
      ("client_id", clientID),
      ("redirect_uri", callback),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
      ("resource", "https://mcp.example.com/mcp"),
    ])

    let authorize = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + authorizeQuery))
    XCTAssertEqual(authorize.status, 200)
    XCTAssertTrue(store.clients.isEmpty)

    let approvals = await oauth.pendingApprovals()
    let pending = try XCTUnwrap(approvals.first)
    XCTAssertEqual(pending.clientID, clientID)
    XCTAssertEqual(pending.clientPlatform, .chatGPT)
    XCTAssertTrue(pending.isDynamicallyRegistered)

    await oauth.resolve(pending.id, approved: true)
    let durable = try XCTUnwrap(store.client(clientID))
    XCTAssertEqual(durable.host, .chatGPT)
    XCTAssertEqual(durable.redirectURIs, [callback])
    XCTAssertTrue(durable.isEnabled)
    XCTAssertNotNil(durable.approvedAt)
    XCTAssertEqual(store.approvedClients.map(\.id), [clientID])

    let callbackReply = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
    XCTAssertEqual(callbackReply.status, 302)
    XCTAssertNotNil(callbackReply.headers["Location"])
  }

  func testDynamicRegistrationDefaultsToClientSecretBasicAndExchangesCode() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    // RFC 7591 defaults an omitted token_endpoint_auth_method to client_secret_basic.
    let callback = "https://accounts.google.com/o/oauth2/mcp/callback"
    let registration: JSONValue = [
      "client_name": "Gemini",
      "redirect_uris": .array([.string(callback)]),
      "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
      "response_types": .array([.string("code")]),
      "application_type": "web",
    ]
    let body = String(decoding: try registration.data(), as: UTF8.self)
    let registered = await oauth.handle(
      request(
        "POST", LutiOAuthService.Paths.register, body: body,
        contentType: "application/json"))
    XCTAssertEqual(registered.status, 201)
    XCTAssertEqual(registered.json["token_endpoint_auth_method"], "client_secret_basic")
    let clientID = try XCTUnwrap(registered.json["client_id"].string)
    let secret = try XCTUnwrap(registered.json["client_secret"].string)
    XCTAssertTrue(store.clients.isEmpty)

    let verifier = String(repeating: "g", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let resource = "https://mcp.example.com/mcp"
    let authorizeQuery = form([
      ("response_type", "code"),
      ("client_id", clientID),
      ("redirect_uri", callback),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
      ("resource", resource),
    ])
    let authorize = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + authorizeQuery))
    XCTAssertEqual(authorize.status, 200)
    let approvals = await oauth.pendingApprovals()
    let pending = try XCTUnwrap(approvals.first)
    await oauth.resolve(pending.id, approved: true)

    let callbackReply = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
    XCTAssertEqual(callbackReply.status, 302)
    let location = try XCTUnwrap(callbackReply.headers["Location"])
    let code = try queryValue("code", in: location)

    let tokenBody = form([
      ("grant_type", "authorization_code"),
      ("code", code),
      ("redirect_uri", callback),
      ("code_verifier", verifier),
      ("resource", resource),
    ])
    let credentials = Data((clientID + ":" + secret).utf8).base64EncodedString()
    let token = await oauth.handle(
      request(
        "POST", LutiOAuthService.Paths.token, body: tokenBody,
        authorization: "Basic " + credentials))
    XCTAssertEqual(token.status, 200)
    XCTAssertNotNil(token.json["access_token"].string)
    XCTAssertNotNil(token.json["refresh_token"].string)
  }

  func testGeminiSparkStylePublicDCRUsesGoogleRedirectProxy() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    let callbacks = (1...6).map {
      "https://oauth-redirect.googleusercontent.com/r/user_bound_custom-mcp-test-\($0)"
    }
    let registration: JSONValue = [
      "client_name": "Google",
      "redirect_uris": .array(callbacks.map(JSONValue.string)),
      "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
      "response_types": .array([.string("code")]),
      "token_endpoint_auth_method": "none",
      "application_type": "web",
    ]
    let body = String(decoding: try registration.data(), as: UTF8.self)
    let registered = await oauth.handle(
      request(
        "POST", LutiOAuthService.Paths.register, body: body,
        contentType: "application/json"))

    XCTAssertEqual(registered.status, 201)
    XCTAssertNil(registered.json["client_secret"].string)
    XCTAssertNotNil(registered.json["client_id_issued_at"].int)
    let clientID = try XCTUnwrap(registered.json["client_id"].string)

    let verifier = String(repeating: "s", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let authorizeQuery = form([
      ("response_type", "code"),
      ("client_id", clientID),
      ("redirect_uri", callbacks[0]),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
      ("resource", "https://mcp.example.com/mcp"),
    ])
    let authorize = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + authorizeQuery))
    XCTAssertEqual(authorize.status, 200)

    let approvals = await oauth.pendingApprovals()
    let pending = try XCTUnwrap(approvals.first)
    XCTAssertEqual(pending.clientName, "Google")
    XCTAssertEqual(pending.clientPlatform, .gemini)
    XCTAssertTrue(pending.isDynamicallyRegistered)
  }

  /// RFC 6749 §4.1.2: `state` returns to the client byte for byte. Google Account
  /// Linking, which Gemini Spark uses, sends a base64 blob containing `+`, `/` and
  /// `=` unencoded, and decoding the query would turn each `+` into a space.
  func testGoogleAccountLinkingStateReturnsByteIdentical() async throws {
    let callback = "https://oauth-redirect.googleusercontent.com/r/user_bound_custom-mcp-test"
    let client = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "Google", redirectURIs: [callback],
      authMethod: .none, host: .gemini)
    let (store, directory) = try temporaryStore(client: client)
    defer { try? FileManager.default.removeItem(at: directory) }

    let verifier = String(repeating: "g", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let state = "AQ+bR/9xZm4=.Wy7t+Lk/0Q=="

    func location(approved: Bool) async throws -> String {
      let oauth = LutiOAuthService(issuer: issuer, store: store)
      let query = form([
        ("response_type", "code"),
        ("client_id", client.id),
        ("redirect_uri", callback),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
        ("scope", "project:read"),
      ]) + "&state=" + state  // On the wire exactly as Google sends it.
      let authorize = await oauth.handle(
        request("GET", LutiOAuthService.Paths.authorize + "?" + query))
      XCTAssertEqual(authorize.status, 200)
      let approvals = await oauth.pendingApprovals()
      let pending = try XCTUnwrap(approvals.first)
      await oauth.resolve(pending.id, approved: approved)
      let reply = await oauth.handle(
        request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
      XCTAssertEqual(reply.status, 302)
      return try XCTUnwrap(reply.headers["Location"])
    }

    for approved in [true, false] {
      let location = try await location(approved: approved)
      XCTAssertTrue(
        location.contains("&state=" + state + "&"),
        "state was rewritten on the way back: \(location)")
    }
  }

  func testMalformedStateIsRefusedRatherThanEchoed() async throws {
    let (store, directory) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)
    let (pending, _) = try await pendingFlow(oauth)
    await oauth.resolve(pending.id, approved: true)

    let query = form([
      ("response_type", "code"),
      ("client_id", pending.clientID),
      ("redirect_uri", redirectURI),
      ("code_challenge", OAuthContract.base64URL(Budget.digest(Data(repeating: 0x76, count: 43)))),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
    ])
    // A fragment marker would truncate the Location header; a long state is a
    // client defect either way. Neither may be echoed to the callback.
    for bad in ["a#b", String(repeating: "s", count: 513)] {
      let reply = await oauth.handle(
        request("GET", LutiOAuthService.Paths.authorize + "?" + query + "&state=" + bad))
      XCTAssertEqual(reply.status, 400)
      XCTAssertNil(reply.headers["Location"])
    }
  }

  func testApprovedClientListHidesUnusedLegacyHostPresets() throws {
    let legacy = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "Claude",
      redirectURIs: ["https://claude.ai/api/mcp/auth_callback"],
      authMethod: .none, host: .claude, enabled: false)
    let (store, directory) = try temporaryStore(client: legacy)
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertEqual(store.clients.map(\.id), [legacy.id])
    XCTAssertTrue(store.approvedClients.isEmpty)

    store.markClientUsed(legacy.id)
    XCTAssertEqual(store.approvedClients.map(\.id), [legacy.id])
  }

  func testAuthorizationCodeRefreshRotationAndReplayRevocation() async throws {
    let client = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "Test Host", redirectURIs: [redirectURI],
      authMethod: .none, host: .custom)
    let (store, directory) = try temporaryStore(client: client)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    let verifier = String(repeating: "v", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let resource = "https://mcp.example.com/mcp"
    let state = "state-123"
    let scope = "project:read project:write"
    let authorizeQuery = form([
      ("response_type", "code"),
      ("client_id", client.id),
      ("redirect_uri", redirectURI),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("state", state),
      ("scope", scope),
      ("resource", resource),
    ])

    let authorize = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + authorizeQuery))
    XCTAssertEqual(authorize.status, 200)
    let approvals = await oauth.pendingApprovals()
    XCTAssertEqual(approvals.count, 1)

    let pending = try XCTUnwrap(approvals.first)
    XCTAssertEqual(pending.clientID, client.id)
    XCTAssertEqual(pending.resource, resource)
    XCTAssertEqual(pending.scopes, [.projectRead, .projectWrite])

    await oauth.resolve(pending.id, approved: true)
    let callback = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorizeWait + "?id=" + pending.id.uuidString))
    XCTAssertEqual(callback.status, 302)
    let location = try XCTUnwrap(callback.headers["Location"])
    XCTAssertEqual(try queryValue("state", in: location), state)
    XCTAssertEqual(try queryValue("iss", in: location), "https://mcp.example.com")
    let code = try queryValue("code", in: location)

    let tokenBody = form([
      ("grant_type", "authorization_code"),
      ("client_id", client.id),
      ("code", code),
      ("redirect_uri", redirectURI),
      ("code_verifier", verifier),
      ("resource", resource),
    ])
    let tokenReply = await oauth.handle(request("POST", LutiOAuthService.Paths.token, body: tokenBody))
    XCTAssertEqual(tokenReply.status, 200)
    XCTAssertEqual(tokenReply.json["token_type"], "Bearer")
    XCTAssertEqual(tokenReply.json["scope"], .string(scope))
    let access = try XCTUnwrap(tokenReply.json["access_token"].string)
    let refresh = try XCTUnwrap(tokenReply.json["refresh_token"].string)

    let verified = await oauth.verify(bearer: access)
    let context = try XCTUnwrap(verified)
    XCTAssertEqual(context.clientID, client.id)
    XCTAssertEqual(context.scopes, [.projectRead, .projectWrite])
    XCTAssertEqual(context.resource, resource)

    let wrongResourceBody = form([
      ("grant_type", "refresh_token"),
      ("client_id", client.id),
      ("refresh_token", refresh),
      ("resource", "https://other.example/mcp"),
    ])
    let wrongResource = await oauth.handle(
      request("POST", LutiOAuthService.Paths.token, body: wrongResourceBody))
    XCTAssertEqual(wrongResource.status, 400)
    XCTAssertEqual(wrongResource.json["error"], "invalid_target")

    let refreshBody = form([
      ("grant_type", "refresh_token"),
      ("client_id", client.id),
      ("refresh_token", refresh),
      ("scope", "project:read"),
      ("resource", resource),
    ])
    let rotated = await oauth.handle(
      request("POST", LutiOAuthService.Paths.token, body: refreshBody))
    XCTAssertEqual(rotated.status, 200)
    XCTAssertEqual(rotated.json["scope"], .string("project:read"))
    let rotatedAccess = try XCTUnwrap(rotated.json["access_token"].string)

    let replay = await oauth.handle(
      request("POST", LutiOAuthService.Paths.token, body: refreshBody))
    XCTAssertEqual(replay.status, 400)
    XCTAssertEqual(replay.json["error"], "invalid_grant")
    let revokedSuccessor = await oauth.verify(bearer: rotatedAccess)
    XCTAssertNil(revokedSuccessor)
  }

  func testAuthorizeRejectsUnregisteredCallbackAndScopeGrantFailsClosed() async throws {
    let client = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "Test Host", redirectURIs: [redirectURI],
      authMethod: .none, host: .chatGPT)
    let (store, directory) = try temporaryStore(client: client)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    let verifier = String(repeating: "p", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let badQuery = form([
      ("response_type", "code"),
      ("client_id", client.id),
      ("redirect_uri", "https://evil.example/callback"),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
    ])
    let bad = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + badQuery))
    XCTAssertEqual(bad.status, 400)
    let pendingAfterBadRedirect = await oauth.pendingApprovals()
    XCTAssertTrue(pendingAfterBadRedirect.isEmpty)

    let context = RequestContext(
      transport: .cloudflare, clientID: client.id, clientName: client.name,
      authorizationID: UUID(), scopes: [.projectRead], resource: "https://mcp.example.com/mcp")
    let grant = ToolGrant.remote(context)
    XCTAssertNoThrow(try grant.authorize(tool: "read_files", arguments: ["paths": ["a.txt"]]))
    XCTAssertThrowsError(
      try grant.authorize(
        tool: "edit_files",
        arguments: ["action": "create", "path": "a.txt", "content": "x"]))
    { error in
      XCTAssertEqual(Failure.safe(error).code, "insufficient_scope")
    }
    XCTAssertThrowsError(try grant.authorize(tool: "future_tool", arguments: [:])) { error in
      XCTAssertEqual(Failure.safe(error).code, "scope_unmapped")
    }
  }

  func testDisabledClientPausesAndRestoresExistingAuthorization() async throws {
    let client = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "ChatGPT", redirectURIs: [redirectURI],
      authMethod: .none, host: .chatGPT)
    let (store, directory) = try temporaryStore(client: client)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oauth = LutiOAuthService(issuer: issuer, store: store)

    let authorizationID = UUID()
    let access = OAuthContract.newAccessToken()
    let refresh = OAuthContract.newRefreshToken()
    let now = Date()
    try store.insert([
      StoredToken(
        hash: OAuthStore.hash(access), kind: .access, clientID: client.id,
        authorizationID: authorizationID, resource: "https://mcp.example.com/mcp",
        scopes: [.projectRead], createdAt: now,
        expiresAt: now.addingTimeInterval(OAuthContract.accessSeconds)),
      StoredToken(
        hash: OAuthStore.hash(refresh), kind: .refresh, clientID: client.id,
        authorizationID: authorizationID, resource: "https://mcp.example.com/mcp",
        scopes: [.projectRead], createdAt: now,
        expiresAt: now.addingTimeInterval(OAuthContract.refreshSeconds)),
    ])

    let beforeDisable = await oauth.verify(bearer: access)
    XCTAssertNotNil(beforeDisable)
    XCTAssertEqual(store.activeGrants().count, 1)

    let verifier = String(repeating: "d", count: 43)
    let challenge = OAuthContract.base64URL(Budget.digest(Data(verifier.utf8)))
    let authorizeQuery = form([
      ("response_type", "code"),
      ("client_id", client.id),
      ("redirect_uri", redirectURI),
      ("code_challenge", challenge),
      ("code_challenge_method", "S256"),
      ("scope", "project:read"),
    ])
    let pendingReply = await oauth.handle(
      request("GET", LutiOAuthService.Paths.authorize + "?" + authorizeQuery))
    XCTAssertEqual(pendingReply.status, 200)
    let pendingBeforeDisable = await oauth.pendingApprovals()
    XCTAssertEqual(pendingBeforeDisable.count, 1)

    try store.setEnabled(false, for: client.id)
    let disabled = try XCTUnwrap(store.client(client.id))
    XCTAssertFalse(disabled.isEnabled)
    XCTAssertEqual(disabled.redirectURIs, [redirectURI])
    XCTAssertTrue(store.activeGrants().isEmpty)
    let afterDisable = await oauth.verify(bearer: access)
    XCTAssertNil(afterDisable)
    XCTAssertNil(store.token(hash: OAuthStore.hash(access))?.revokedAt)
    XCTAssertNil(store.token(hash: OAuthStore.hash(refresh))?.revokedAt)
    let refreshWhilePaused = await oauth.handle(
      request("POST", LutiOAuthService.Paths.token, body: form([
        ("grant_type", "refresh_token"), ("client_id", client.id),
        ("refresh_token", refresh),
      ])))
    XCTAssertEqual(refreshWhilePaused.status, 401)

    try store.setEnabled(true, for: client.id)
    let reenabled = try XCTUnwrap(store.client(client.id))
    XCTAssertTrue(reenabled.isEnabled)
    XCTAssertEqual(reenabled.redirectURIs, [redirectURI])
    XCTAssertEqual(store.activeGrants().count, 1)
    let afterResume = await oauth.verify(bearer: access)
    XCTAssertNotNil(afterResume)
    let refreshAfterResume = await oauth.handle(
      request("POST", LutiOAuthService.Paths.token, body: form([
        ("grant_type", "refresh_token"), ("client_id", client.id),
        ("refresh_token", refresh),
      ])))
    XCTAssertEqual(refreshAfterResume.status, 200)
    let pendingAfterReenable = await oauth.pendingApprovals()
    XCTAssertTrue(pendingAfterReenable.isEmpty)
  }

  func testPlatformDetectionUsesCallbackDomainBoundaries() throws {
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: ["https://chatgpt.com/connector/oauth/callback"]), .chatGPT)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: ["https://subdomain.claude.ai/api/mcp/auth_callback"]), .claude)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: ["https://evil-chatgpt.com/connector/oauth/callback"]), .custom)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: [
          "https://oauth-redirect.googleusercontent.com/r/user_bound_custom-mcp-example"
        ]), .gemini)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: [
          "https://oauth-redirect-sandbox.googleusercontent.com/r/custom-mcp-example"
        ]), .gemini)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: ["https://oauth-redirect.evil-googleusercontent.com/r/example"]), .custom)
    XCTAssertEqual(
      RemoteMCPHost.detected(
        redirectURIs: ["https://client.example/callback"]), .custom)

    let record = OAuthClientRecord(
      id: OAuthContract.newClientID(), name: "Gemini", redirectURIs: [],
      authMethod: .clientSecretPost, host: .gemini)
    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(OAuthClientRecord.self, from: encoded)
    XCTAssertEqual(decoded.host, .gemini)
    XCTAssertEqual(decoded.authMethod, .clientSecretPost)
    XCTAssertTrue(decoded.isEnabled)
  }
}
