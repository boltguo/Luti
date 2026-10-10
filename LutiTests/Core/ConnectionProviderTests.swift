import AppKit
import Foundation
import XCTest

@testable import Luti

/// No cloud process, account or public network is used by this suite.
private actor FixtureProvider: ConnectionProvider {
  nonisolated let id: ConnectionProviderID
  nonisolated let ingressPort = 0
  private let suspended: Bool
  private let fails: Bool
  private let initiallyReconnecting: Bool
  private var waiter: CheckedContinuation<Void, Never>?
  private var origin: URL?
  private var state = ConnectionSnapshot.stopped
  private(set) var endpoint: URL?
  private(set) var preAdmissionStatus: Int?

  init(_ id: ConnectionProviderID, suspended: Bool = false, fails: Bool = false,
       initiallyReconnecting: Bool = false) {
    self.id = id
    self.suspended = suspended
    self.fails = fails
    self.initiallyReconnecting = initiallyReconnecting
    origin = URL(string: "https://mcp.example.com")
  }
  var publicOrigin: URL? { origin }
  func start(endpoint: URL) async throws {
    self.endpoint = endpoint
    preAdmissionStatus = try await ConnectionProbe.request(endpoint, method: "POST").status
    if suspended { await withCheckedContinuation { waiter = $0 } }
    if fails { throw Failure.invalid("Synthetic provider startup failure.") }
    state = ConnectionSnapshot(state: initiallyReconnecting ? .reconnecting : .ready)
  }
  func fail() { state = ConnectionSnapshot(state: .failed, message: "Synthetic child exit.") }
  func release() { waiter?.resume(); waiter = nil }
  func snapshot() -> ConnectionSnapshot { state }
  func stop() {
    state = .stopped
    origin = nil
    release() // Deliberate late success after Stop must not resurrect a listener.
  }
}

@MainActor final class ConnectionProviderTests: XCTestCase {
  private func fixture() throws -> (Fixture, RuntimeCore, ConnectionManager) {
    let f = try Fixture()
    let runtime = try RuntimeCore(root: f.root, helper: Fixture.helper, contextDataRoot: f.contextDataRoot)
    let manager = ConnectionManager(router: runtime.router, store: OAuthStore(url: nil))
    addTeardownBlock { await manager.shutdown(); await runtime.stop(); f.remove() }
    return (f, runtime, manager)
  }

  private func approvedClient(_ store: OAuthStore, confidential: Bool = false) throws -> OAuthClientRecord {
    let client = OAuthClientRecord(id: OAuthContract.newClientID(), name: "Fixture AI",
      redirectURIs: ["https://client.example/callback"],
      authMethod: confidential ? .clientSecretPost : .none)
    try store.persistRegisteredClient(client, secret: confidential ? "synthetic-test-secret" : nil)
    return client
  }

  private func insertToken(_ store: OAuthStore, client: OAuthClientRecord, resource: String) throws -> String {
    let token = OAuthContract.newAccessToken()
    try store.insert([StoredToken(hash: OAuthStore.hash(token), kind: .access,
      clientID: client.id, authorizationID: UUID(), resource: resource, scopes: [.projectRead],
      createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))])
    return token
  }

  private func rpc(_ endpoint: URL, bearer: String? = nil, host: String? = nil,
                   method: String = "tools/list", params: JSONValue = [:]) async throws -> (Int, JSONValue) {
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 3
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let bearer { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
    if let host { request.setValue(host, forHTTPHeaderField: "Host") }
    request.httpBody = try JSONValue.object([
      "jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]).data()
    let (data, response) = try await URLSession.shared.data(for: request)
    return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, (try? JSONValue.decode(data)) ?? .null)
  }

  func testLiteProviderCatalogContainsOnlySupportedConnections() {
    XCTAssertEqual(ConnectionProviderID.allCases, [.cloudflare])
    for removed in ["openai", "ngrok", "quick", "custom"] {
      XCTAssertNil(ConnectionProviderID(rawValue: removed))
    }
  }

  func testProviderMustConfirmReadinessBeforeConnectionStarts() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let provider = FixtureProvider(.cloudflare, initiallyReconnecting: true)
    do {
      try await manager.connect(provider)
      XCTFail("A provider must confirm its connection before becoming available.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "connection_not_ready")
    }
    let failed = await manager.snapshot()
    XCTAssertEqual(failed.state, .failed)
    XCTAssertNil(failed.publicOrigin)
    let project = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(project.isError)

  }

  func testProviderIngressCannotPointAtAnotherServiceOrPublicHost() throws {
    let valid = URL(string: "http://127.0.0.1:43219/mcp")!
    XCTAssertNoThrow(try ConnectionContract.validateIngressEndpoint(valid))
    for raw in ["https://127.0.0.1:43219/mcp", "http://localhost:43219/mcp",
      "http://192.168.0.1:43219/mcp", "http://127.0.0.1/mcp", "http://127.0.0.1:0/mcp",
      "http://127.0.0.1:43219/", "http://u:p@127.0.0.1:43219/mcp",
      "http://127.0.0.1:43219/mcp?x=1"] {
      XCTAssertThrowsError(try ConnectionContract.validateIngressEndpoint(URL(string: raw)!))
    }
  }

  func testEphemeralStoreKeepsConfidentialSecretOutOfKeychainAndClearsIt() throws {
    let store = OAuthStore(url: nil)
    try store.bindOrigin("https://ephemeral.example")
    let client = try approvedClient(store, confidential: true)
    let token = try insertToken(store, client: client, resource: "https://ephemeral.example/mcp")
    XCTAssertTrue(store.isEphemeral)
    XCTAssertEqual(try store.clientSecret(client.id), "synthetic-test-secret")
    XCTAssertFalse(KeychainService.exists(account: KeychainService.clientSecret(client.id)))
    XCTAssertEqual(store.activeGrants().count, 1)
    try store.reset()
    XCTAssertNil(store.boundOrigin)
    XCTAssertTrue(store.clients.isEmpty)
    XCTAssertTrue(store.activeGrants().isEmpty)
    XCTAssertNil(store.token(hash: OAuthStore.hash(token)))
    XCTAssertNil(try store.clientSecret(client.id))
  }

  func testOriginPinRetainsSameOriginButInvalidatesReplacement() throws {
    let f = try Fixture(); defer { f.remove() }
    let path = f.contextDataRoot.appendingPathComponent("provider-auth.json")
    let store = OAuthStore(url: path)
    try store.bindOrigin("https://mcp.example.com")
    let client = try approvedClient(store)
    let token = try insertToken(store, client: client, resource: "https://mcp.example.com/mcp")
    let reopened = OAuthStore(url: path)
    try reopened.bindOrigin("https://mcp.example.com/")
    XCTAssertNotNil(reopened.client(client.id))
    XCTAssertNotNil(reopened.token(hash: OAuthStore.hash(token)))
    try reopened.bindOrigin("https://different.example.com")
    XCTAssertTrue(reopened.clients.isEmpty)
    XCTAssertNil(reopened.token(hash: OAuthStore.hash(token)))
    XCTAssertEqual(OAuthStore(url: path).boundOrigin, "https://different.example.com")
  }

  func testLegacyOriginMigrationPreservesOnlyProvenMatchingAuthorizations() throws {
    let store = OAuthStore(url: nil)
    let matching = try approvedClient(store)
    let unrelated = try approvedClient(store)
    let matchingToken = try insertToken(store, client: matching, resource: "https://mcp.example.com/mcp")
    _ = try insertToken(store, client: unrelated, resource: "https://other.example.com/mcp")
    try store.bindOrigin("https://mcp.example.com")
    XCTAssertEqual(store.clients.map(\.id), [matching.id])
    XCTAssertNotNil(store.token(hash: OAuthStore.hash(matchingToken)))
  }

  func testPublicDoctorDetectsWrongIssuerAndUnexpectedSuccess() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    let oauth = LutiOAuthService(issuer: URL(string: "https://mcp.example.com")!, store: OAuthStore(url: nil))
    let dispatcher = MCPDispatcher(authentication: .remote(publicHost: "mcp.example.com", oauth: oauth), port: 40001, router: router)
    func probe(_ path: String, method: String = "GET", evil: Bool = false) async -> ConnectionProbe.Response {
      var headers = ["Host": ["mcp.example.com"]]
      if evil { headers["Origin"] = ["https://untrusted.invalid"] }
      let response = await dispatcher.handle(HTTPRequest(method: method, path: path, headers: headers, body: Data()))
      return .init(status: response.status, json: response.json, challenge: response.headers["WWW-Authenticate"])
    }
    let resource = await probe(LutiOAuthService.Paths.protectedResourceMCP)
    let metadata = await probe(LutiOAuthService.Paths.authorizationServer)
    let challenge = await probe("/mcp", method: "POST")
    let denied = await probe("/mcp", method: "POST", evil: true)
    let good = ConnectionDoctor.evaluate(origin: "https://mcp.example.com", resource: resource,
      metadata: metadata, challenge: challenge, originGuard: denied)
    XCTAssertTrue(good.passed)
    let wrongOrigin = ConnectionDoctor.evaluate(origin: "https://other.example.com", resource: resource,
      metadata: metadata, challenge: challenge, originGuard: denied)
    XCTAssertFalse(wrongOrigin.passed)
    let exposed = ConnectionDoctor.evaluate(origin: "https://mcp.example.com", resource: resource,
      metadata: metadata, challenge: .init(status: 200, json: .null, challenge: nil), originGuard: denied)
    XCTAssertFalse(exposed.passed)
    await router.stop()
    await oauth.shutdown()
  }

  func testCloudflareAutomaticallyBecomesAvailableWithOriginAndToken() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = false
    XCTAssertTrue(model.availableConnectionProviders.isEmpty)
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    model.publicBaseURL = "https://mcp.example.com"
    XCTAssertTrue(model.availableConnectionProviders.isEmpty)
    model.tokenSaved = true
    XCTAssertEqual(model.availableConnectionProviders, [.cloudflare])
    XCTAssertNil(f.defaults.object(forKey: "enabledConnectionProviders"))
    model.phase = .running
    XCTAssertTrue(model.canConnectProvider(.cloudflare))
    model.tokenSaved = false
    XCTAssertFalse(model.canConnectProvider(.cloudflare))
  }

  func testCloudflareIngressRejectsUnknownBearerAndAcceptsOAuth() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let store = OAuthStore(url: nil)
    try store.bindOrigin("https://mcp.example.com")
    let client = try approvedClient(store)
    let token = try insertToken(store, client: client, resource: "https://mcp.example.com/mcp")
    let provider = FixtureProvider(.cloudflare)
    try await manager.connect(provider, authorizationStore: store)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    let missing = try await rpc(endpoint)
    let unknownBearer = try await rpc(endpoint, bearer: "Bearer " + Budget.token())
    let admitted = try await rpc(endpoint, bearer: "Bearer " + token,
      method: "tools/call", params: ["name": "project_info", "arguments": [:]])
    XCTAssertEqual(missing.0, 401)
    XCTAssertEqual(unknownBearer.0, 401)
    XCTAssertEqual(admitted.0, 200)
    let snapshot = await manager.snapshot()
    XCTAssertEqual(snapshot.providerID, .cloudflare)
    XCTAssertEqual(snapshot.publicOrigin?.absoluteString, "https://mcp.example.com")
    let runtimeSnapshot = await runtime.snapshot()
    XCTAssertEqual(runtimeSnapshot.activity.last?.source?.transport, .cloudflare)
    await manager.disconnect()
    let project = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(project.isError)
  }

  func testRetiredSelectionDoesNotGateConfiguredCloudflareOrResetAuthorizations() throws {
    for stored in [["openai", "ngrok", "quick", "unknown"], ["cloudflare"],
      ["cloudflare", "openai", "ngrok", "quick"], [], ["ngrok", "quick"]] {
      let f = try Fixture(); defer { f.remove() }
      f.defaults.set(try JSONEncoder().encode(stored), forKey: "enabledConnectionProviders")
      f.defaults.set("openai", forKey: "activeConnectionProvider")
      f.defaults.set("tunnel_fixture123", forKey: "connection.openai.address")
      f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
      let store = OAuthStore(url: f.contextDataRoot.appendingPathComponent("auth/oauth.json"))
      try store.bindOrigin("https://mcp.example.com")
      let client = try approvedClient(store)
      let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
      model.tokenSaved = true
      XCTAssertEqual(model.availableConnectionProviders, [.cloudflare])
      XCTAssertEqual(model.savedPublicBaseURL, "https://mcp.example.com")
      XCTAssertNotNil(model.authorizationStore(for: .cloudflare).client(client.id))
      XCTAssertNil(f.defaults.object(forKey: "enabledConnectionProviders"))
      XCTAssertNil(f.defaults.object(forKey: "activeConnectionProvider"))
    }
  }

  func testRetiredTransportTagsStillDecodeHistoricalActivity() throws {
    for tag in ["openai", "ngrok", "quick"] {
      let transport = try JSONDecoder().decode(TransportProviderID.self, from: Data("\"\(tag)\"".utf8))
      XCTAssertEqual(transport.rawValue, tag)
      XCTAssertNil(ConnectionProviderID(rawValue: tag))
    }
  }

  func testConfiguredPublicProvidersExposeCompleteMCPServerURL() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = true

    XCTAssertEqual(
      model.configuredMCPServerURL(.cloudflare)?.absoluteString,
      "https://mcp.example.com/mcp")
  }

  func testCloudflareStatusRepresentsConfigurationAndActualConnection() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = false
    XCTAssertEqual(model.cloudflareStatusKey, "connection.notConfigured")
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    model.tokenSaved = true
    XCTAssertEqual(model.cloudflareStatusKey, "connection.state.stopped")
    for state in [ConnectionState.starting, .ready, .reconnecting, .failed, .stopping] {
      model.connectionSnapshots[.cloudflare] = ConnectionSnapshot(state: state, providerID: .cloudflare)
      XCTAssertEqual(model.cloudflareStatusKey, "connection.state." + state.rawValue)
    }
    model.connectionSnapshots = [:]
    XCTAssertEqual(model.cloudflareStatusKey, "connection.state.stopped")
  }

}
