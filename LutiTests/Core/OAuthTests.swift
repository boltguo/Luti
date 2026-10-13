import Foundation
import XCTest
@testable import Luti

private final class OAuthClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date()
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

@MainActor final class OAuthTests: XCTestCase {
  private let origin = URL(string: "https://mcp.example.com")!
  private let redirect = "https://chatgpt.com/connector_platform_oauth_redirect"
  private let verifier = String(repeating: "v", count: 64)
  private var resource: String { origin.absoluteString + "/mcp" }

  private func form(_ values: [String: String]) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return values.sorted { $0.key < $1.key }.map {
      $0.key + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }.joined(separator: "&")
  }
  private func post(_ service: OAuthService, _ path: String, _ values: [String: String], headers: [String: [String]] = [:]) async -> HTTPReply {
    await service.handle(HTTPRequest(path: path,
      headers: ["content-type": ["application/x-www-form-urlencoded"]].merging(headers) { _, new in new },
      body: Data(form(values).utf8)))
  }
  private func register(_ service: OAuthService, method: String = "none") async throws -> JSONValue {
    let response = await service.handle(HTTPRequest(path: "/oauth/register", headers: ["content-type": ["application/json"]],
      body: try JSONValue.object(["client_name": "ChatGPT", "redirect_uris": [.string(redirect)],
        "token_endpoint_auth_method": .string(method)]).data()))
    XCTAssertEqual(response.status, 201)
    return response.json
  }
  private func authorize(_ service: OAuthService, client: JSONValue, state: String = "state+with/&=空格") async -> HTTPReply {
    let values = ["client_id": client["client_id"].string!, "redirect_uri": redirect, "response_type": "code",
      "state": state, "code_challenge": OAuthContract.challenge(verifier), "code_challenge_method": "S256",
      "resource": resource, "scope": "mcp"]
    return await service.handle(HTTPRequest(method: "GET", path: "/oauth/authorize?" + form(values), headers: [:], body: Data()))
  }
  private func approveCode(_ service: OAuthService, client: JSONValue) async throws -> String {
    let response = await authorize(service, client: client)
    XCTAssertEqual(response.status, 303)
    let requests = await service.snapshot().pending
    let pending = try XCTUnwrap(requests.last)
    try await service.decide(pending.id, allow: true)
    let finish = await service.handle(HTTPRequest(method: "GET", path: response.headers["Location"]!, headers: [:], body: Data()))
    let components = try XCTUnwrap(URLComponents(string: finish.headers["Location"]!))
    let returned = try OAuthContract.form(components.percentEncodedQuery!)
    XCTAssertEqual(returned["state"], "state+with/&=空格")
    XCTAssertEqual(returned["iss"], origin.absoluteString)
    return try XCTUnwrap(returned["code"])
  }
  private func exchange(_ service: OAuthService, client: JSONValue, code: String, verifier: String? = nil) async -> HTTPReply {
    await post(service, "/oauth/token", ["client_id": client["client_id"].string!, "grant_type": "authorization_code",
      "code": code, "redirect_uri": redirect, "code_verifier": verifier ?? self.verifier, "resource": resource])
  }

  func testNativeApprovalPKCEAttributionAndRevocation() async throws {
    let service = try OAuthService(origin: origin, project: "project-a")
    let client = try await register(service)
    let code = try await approveCode(service, client: client)
    let tokens = await exchange(service, client: client, code: code)
    XCTAssertEqual(tokens.status, 200)
    let token = try XCTUnwrap(tokens.json["access_token"].string)
    let grant = await service.grant(for: token)
    XCTAssertEqual(grant?.context?.transport, .cloudflare)
    XCTAssertEqual(grant?.context?.clientID, client["client_id"].string)
    try await service.revoke(try XCTUnwrap(grant?.context?.authorizationID))
    let revoked = await service.grant(for: token)
    XCTAssertNil(revoked)
    let refreshed = await post(service, "/oauth/token", ["client_id": client["client_id"].string!,
      "grant_type": "refresh_token", "refresh_token": tokens.json["refresh_token"].string!, "resource": resource])
    XCTAssertEqual(refreshed.json["error"], "invalid_grant")
    // A client can ask again after revocation, but still needs fresh native consent.
    let another = await authorize(service, client: client)
    XCTAssertEqual(another.status, 303)
  }

  func testRegistrationWithoutOptionalClientNameStillRequiresNativeConsent() async throws {
    let service = try OAuthService(origin: origin, project: "a")
    let response = await service.handle(HTTPRequest(path: "/oauth/register", headers: ["content-type": ["application/json"]],
      body: try JSONValue.object(["redirect_uris": [.string(redirect)], "token_endpoint_auth_method": "none"]).data()))
    XCTAssertEqual(response.status, 201)
    XCTAssertEqual(response.json["client_name"], "MCP client")
    let before = await service.snapshot()
    XCTAssertTrue(before.applications.isEmpty)
    let code = try await approveCode(service, client: response.json)
    let tokens = await exchange(service, client: response.json, code: code)
    XCTAssertEqual(tokens.status, 200)
  }

  func testCodeIsSingleUseAndRequiresCorrectPKCE() async throws {
    let service = try OAuthService(origin: origin, project: "a")
    let client = try await register(service)
    let code = try await approveCode(service, client: client)
    let wrong = await exchange(service, client: client, code: code, verifier: String(repeating: "x", count: 64))
    XCTAssertEqual(wrong.json["error"], "invalid_grant")
    let replay = await exchange(service, client: client, code: code)
    XCTAssertEqual(replay.json["error"], "invalid_grant")
    let next = try await approveCode(service, client: client)
    let accepted = await exchange(service, client: client, code: next)
    XCTAssertEqual(accepted.status, 200)
    let used = await exchange(service, client: client, code: next)
    XCTAssertEqual(used.json["error"], "invalid_grant")
  }

  func testRefreshRotationRejectsWrongResourceAndRevokesFamilyOnReplay() async throws {
    let service = try OAuthService(origin: origin, project: "a")
    let client = try await register(service)
    let code = try await approveCode(service, client: client)
    let tokens = await exchange(service, client: client, code: code)
    var values = ["client_id": client["client_id"].string!, "grant_type": "refresh_token",
      "refresh_token": tokens.json["refresh_token"].string!, "resource": "https://other.example.com/mcp"]
    let wrong = await post(service, "/oauth/token", values)
    XCTAssertEqual(wrong.json["error"], "invalid_target")
    values["resource"] = resource
    let fresh = await post(service, "/oauth/token", values)
    XCTAssertEqual(fresh.status, 200)
    let old = await service.grant(for: tokens.json["access_token"].string!)
    XCTAssertNil(old)
    let replay = await post(service, "/oauth/token", values)
    XCTAssertEqual(replay.json["error"], "invalid_grant")
    let revoked = await service.grant(for: fresh.json["access_token"].string!)
    XCTAssertNil(revoked)
  }

  func testNoApprovalRouteAndPendingRequestsAreBoundedAndExpire() async throws {
    let clock = OAuthClock()
    let service = try OAuthService(origin: origin, project: "a", now: { clock.now() })
    let client = try await register(service)
    for i in 0..<16 {
      let response = await authorize(service, client: client, state: String(i))
      XCTAssertEqual(response.status, 303)
    }
    let full = await authorize(service, client: client)
    XCTAssertEqual(full.status, 429)
    let snapshot = await service.snapshot()
    XCTAssertEqual(snapshot.pending.count, 16)
    XCTAssertTrue(snapshot.applications.isEmpty)
    clock.advance(301)
    let expired = await service.snapshot()
    XCTAssertTrue(expired.pending.isEmpty)
    do { try await service.decide(snapshot.pending[0].id, allow: true); XCTFail("Expired approval") } catch {}
  }

  func testDenialAndWaitTicketAreOneUse() async throws {
    let service = try OAuthService(origin: origin, project: "a")
    let client = try await register(service)
    let begin = await authorize(service, client: client)
    let request = await service.snapshot().pending[0]
    try await service.decide(request.id, allow: false)
    let poll = HTTPRequest(method: "GET", path: begin.headers["Location"]!, headers: [:], body: Data())
    let denied = await service.handle(poll)
    XCTAssertTrue(denied.headers["Location"]?.contains("error=access_denied") == true)
    let repeatPoll = await service.handle(poll)
    XCTAssertNil(repeatPoll.headers["Location"])
    let snapshot = await service.snapshot()
    XCTAssertTrue(snapshot.applications.isEmpty)
  }

  func testPersistentHashesAreProjectAndIssuerBoundAndFailClosed() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.contextDataRoot.appendingPathComponent("oauth.json")
    let service = try OAuthService(origin: origin, project: "a", file: file)
    let client = try await register(service)
    let code = try await approveCode(service, client: client)
    let tokens = await exchange(service, client: client, code: code)
    let token = tokens.json["access_token"].string!
    let disk = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(disk.contains(token))
    XCTAssertFalse(disk.contains(tokens.json["refresh_token"].string!))
    await service.shutdown()
    let stopped = await service.grant(for: token)
    XCTAssertNil(stopped)
    let reopened = try OAuthService(origin: origin, project: "a", file: file)
    let grant = await reopened.grant(for: token)
    XCTAssertNotNil(grant)
    XCTAssertThrowsError(try OAuthService(origin: origin, project: "b", file: file))
    XCTAssertThrowsError(try OAuthService(origin: URL(string: "https://other.example.com")!, project: "a", file: file))
    try await reopened.revoke(grant!.context!.authorizationID)
    let again = try OAuthService(origin: origin, project: "a", file: file)
    let missing = await again.grant(for: token)
    XCTAssertNil(missing)
    try PrivateFiles.atomicWrite(Data("not-json".utf8), to: file)
    XCTAssertThrowsError(try OAuthService(origin: origin, project: "a", file: file))
  }

  func testDispatcherRequiresOAuthAndChecksHostOriginAndDuplicateHeaders() async throws {
    let f = try Fixture(); defer { f.remove() }
    let service = try OAuthService(origin: origin, project: "a")
    let dispatcher = MCPDispatcher(authentication: .oauth(service), port: 39393, router: try f.router())
    let body = try JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]).data()
    var headers = ["host": ["mcp.example.com"], "content-type": ["application/json"], "accept": ["application/json, text/event-stream"]]
    let unauthenticated = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(unauthenticated.status, 401)
    XCTAssertTrue(unauthenticated.headers["WWW-Authenticate"]?.contains(service.metadataURL) == true)
    let metadata = await dispatcher.handle(HTTPRequest(method: "GET", path: "/.well-known/oauth-protected-resource/mcp", headers: headers, body: Data()))
    XCTAssertEqual(metadata.json["resource"], .string(resource))
    let approve = await dispatcher.handle(HTTPRequest(path: "/oauth/approve", headers: headers, body: Data()))
    XCTAssertEqual(approve.status, 404)
    let client = try await register(service)
    let code = try await approveCode(service, client: client)
    let token = await exchange(service, client: client, code: code)
    headers["authorization"] = ["Bearer " + token.json["access_token"].string!]
    let valid = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(valid.status, 200)
    headers["host"] = ["attacker.example.com"]
    let badHost = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(badHost.status, 403)
    headers["host"] = ["mcp.example.com"]
    headers["origin"] = ["https://attacker.example.com"]
    let badOrigin = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(badOrigin.status, 403)
    headers.removeValue(forKey: "origin")
    headers["authorization"]!.append("Bearer another")
    let duplicates = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(duplicates.status, 400)
    await dispatcher.shutdown()
    let stopped = await dispatcher.handle(HTTPRequest(headers: headers, body: body))
    XCTAssertEqual(stopped.status, 503)
  }

  func testConfidentialClientAuthenticationAndCodeExpiry() async throws {
    for method in ["client_secret_basic", "client_secret_post"] {
      let clock = OAuthClock()
      let service = try OAuthService(origin: origin, project: "a", now: { clock.now() })
      let client = try await register(service, method: method)
      let code = try await approveCode(service, client: client)
      var values = ["client_id": client["client_id"].string!, "grant_type": "authorization_code", "code": code,
        "redirect_uri": redirect, "code_verifier": verifier, "resource": resource]
      let absent = await post(service, "/oauth/token", values)
      XCTAssertEqual(absent.status, 401)
      var headers: [String: [String]] = [:]
      if method == "client_secret_post" { values["client_secret"] = client["client_secret"].string! }
      else {
        headers["authorization"] = ["Basic " + Data((values["client_id"]! + ":" + client["client_secret"].string!).utf8).base64EncodedString()]
      }
      let success = await post(service, "/oauth/token", values, headers: headers)
      XCTAssertEqual(success.status, 200)
      let expiredCode = try await approveCode(service, client: client)
      values["code"] = expiredCode
      clock.advance(61)
      let expired = await post(service, "/oauth/token", values, headers: headers)
      XCTAssertEqual(expired.json["error"], "invalid_grant")
    }
  }

  func testURLAndParameterValidation() throws {
    for value in ["http://mcp.example.com", "https://127.0.0.1", "https://localhost", "https://a.local",
                  "https://user:pass@mcp.example.com", "https://mcp.example.com/path", "https://mcp.example.com?x=1"] {
      XCTAssertThrowsError(try CloudflareContract.origin(value))
    }
    for value in ["https://chatgpt.com/callback#fragment", "http://chatgpt.com/callback", "https://localhost/callback",
                  "https://user@chatgpt.com/callback", "https://chatgpt.com/callback?code=inject"] {
      XCTAssertFalse(OAuthContract.validRedirect(value))
    }
    XCTAssertThrowsError(try OAuthContract.form("client_id=a&client_id=b"))
    XCTAssertThrowsError(try OAuthContract.form("code=%zz"))
    XCTAssertEqual(try OAuthContract.form("state=a%2Bb+c"), ["state": "a+b c"])
    XCTAssertEqual(CloudflareTunnelProvider.readinessURL(from: "Starting metrics server on 127.0.0.1:42123/metrics")?.port, 42123)
    XCTAssertNil(CloudflareTunnelProvider.readinessURL(from: "Starting metrics server on 0.0.0.0:42123/metrics"))
  }

  func testFailedPersistenceCannotIssueAnAuthorization() async throws {
    let f = try Fixture(); defer { f.remove() }
    let file = f.contextDataRoot.appendingPathComponent("grants.json")
    let service = try OAuthService(origin: origin, project: "a", file: file)
    let client = try await register(service)
    _ = await authorize(service, client: client)
    let pending = await service.snapshot().pending[0]
    // An unexpected directory at the file path must fail closed, not silently
    // fall back to ephemeral grants that disappear after a restart.
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    do { try await service.decide(pending.id, allow: true); XCTFail("Unsafe persistence target") } catch {}
    let snapshot = await service.snapshot()
    XCTAssertTrue(snapshot.applications.isEmpty)
    XCTAssertEqual(snapshot.pending.count, 1)
  }

  func testCloudflareSettingsAreAtomicAndCanStartWithoutOpenAI() async throws {
    let f = try Fixture(); defer { f.remove() }
    let keychain = FixtureKeychain(failedSaves: 1)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: keychain.client)
    model.addProject(f.root)
    let cf = model.cloudflare
    cf.domain = origin.absoluteString
    cf.tokenDraft = String(repeating: "a", count: 80)
    await cf.save(project: f.root)
    XCTAssertEqual(cf.savedDomain, "")
    XCTAssertFalse(cf.tokenSaved)
    XCTAssertFalse(model.canLaunch)
    await cf.save(project: f.root)
    XCTAssertEqual(cf.savedDomain, origin.absoluteString)
    XCTAssertTrue(cf.tokenSaved)
    XCTAssertTrue(cf.enabled)
    XCTAssertTrue(model.canLaunch)
    XCTAssertFalse(model.connectionConfigured)
    cf.domain = "https://changed.example.com"
    XCTAssertFalse(model.canLaunch)
    cf.domain = cf.savedDomain
    cf.enabled = false
    XCTAssertFalse(model.canLaunch)
    await model.stop()
  }

  func testStopRacingCloudflareStartRetiresOAuthAndJoinsOwnership() async throws {
    let f = try Fixture(); defer { f.remove() }
    let service = try OAuthService(origin: origin, project: "a")
    let manager = ConnectionManager(router: try f.router())
    let provider = SuspendedCloudflare()
    let start = Task { try await manager.connect(provider, oauth: service) }
    for _ in 0..<100 {
      if await provider.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let didStart = await provider.started
    XCTAssertTrue(didStart)
    await manager.shutdown()
    do { try await start.value; XCTFail("A stopped connection cannot publish readiness") } catch {}
    let snapshot = await manager.snapshot()
    XCTAssertEqual(snapshot.state, .stopped)
    let metadata = await service.handle(HTTPRequest(method: "GET", path: "/.well-known/oauth-authorization-server", headers: [:], body: Data()))
    XCTAssertEqual(metadata.status, 503)
    let stopCount = await provider.stops
    XCTAssertEqual(stopCount, 1)
  }
}

private actor SuspendedCloudflare: ConnectionProvider {
  nonisolated let id = ConnectionProviderID.cloudflare
  nonisolated let privateCredential = ""
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var started = false
  private(set) var stops = 0
  func start(endpoint: URL) async throws {
    started = true
    await withCheckedContinuation { waiter = $0 }
  }
  func snapshot() -> ConnectionSnapshot { ConnectionSnapshot(state: .ready) }
  func stop() {
    stops += 1
    waiter?.resume()
    waiter = nil
  }
}
