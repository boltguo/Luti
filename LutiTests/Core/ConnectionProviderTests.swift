import AppKit
import Foundation
import XCTest

@testable import Luti

/// No cloud process, account or public network is used by this suite.
private actor FixtureProvider: ConnectionProvider {
  nonisolated let id: ConnectionProviderID
  nonisolated let ingressPort = 0
  nonisolated let privateCredential: String?
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
    privateCredential = id == .openAI ? OAuthContract.newClientSecret() : nil
    origin = id == .ngrok || id == .cloudflare ? URL(string: "https://mcp.example.com") : nil
  }
  var publicOrigin: URL? { origin }
  func start(endpoint: URL) async throws {
    self.endpoint = endpoint
    preAdmissionStatus = try await ConnectionProbe.request(endpoint, method: "POST").status
    if suspended { await withCheckedContinuation { waiter = $0 } }
    if fails { throw Failure.invalid("Synthetic provider startup failure.") }
    if id == .quick { origin = URL(string: "https://fixture.trycloudflare.com") }
    state = ConnectionSnapshot(state: initiallyReconnecting ? .reconnecting : .ready)
  }
  func becomeReady() { state = ConnectionSnapshot(state: .ready) }
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

  func testProviderCatalogSeparatesTemporaryQuickFromPersistentConnections() {
    XCTAssertEqual(ConnectionProviderID.allCases, [.cloudflare, .openAI, .ngrok, .quick])
    XCTAssertEqual(ConnectionProviderID.persistentProviders, [.cloudflare, .openAI, .ngrok])
    XCTAssertNil(ConnectionProviderID(rawValue: "custom"))
    XCTAssertFalse(ConnectionProviderID.openAI.usesOAuth)
    XCTAssertTrue(ConnectionProviderID.quick.usesOAuth)
    XCTAssertFalse(ConnectionProviderID.quick.isPersistent)
  }

  func testQuickTunnelAcceptsOnlyTryCloudflareOrigins() throws {
    XCTAssertEqual(
      try QuickTunnelProvider.validateQuickOrigin("https://fixture.trycloudflare.com").absoluteString,
      "https://fixture.trycloudflare.com")
    for raw in [
      "http://fixture.trycloudflare.com",
      "https://trycloudflare.com",
      "https://fixture.trycloudflare.com.evil.example",
      "https://evil.example",
      "https://user@fixture.trycloudflare.com",
      "https://fixture.trycloudflare.com/path",
      "https://fixture.trycloudflare.com?x=1",
    ] {
      XCTAssertThrowsError(try QuickTunnelProvider.validateQuickOrigin(raw), raw)
    }
  }

  func testQuickTunnelExtractsOnlyValidatedOriginFromCloudflaredOutput() {
    let json = #"{"level":"info","url":"https://first-example.trycloudflare.com"}"#
    XCTAssertEqual(
      QuickTunnelProvider.publicOrigin(from: json)?.absoluteString,
      "https://first-example.trycloudflare.com")
    XCTAssertEqual(
      QuickTunnelProvider.publicOrigin(
        from: "ignore https://evil.example then https://second-example.trycloudflare.com ready")?.absoluteString,
      "https://second-example.trycloudflare.com")
    XCTAssertNil(QuickTunnelProvider.publicOrigin(from: "https://trycloudflare.com"))
    XCTAssertNil(QuickTunnelProvider.publicOrigin(from: "https://fixture.trycloudflare.com.evil.example"))
  }

  func testQuickTunnelUsesOnlyItsLoopbackMetricsEndpoint() {
    let output = #"{"message":"Starting metrics server on 127.0.0.1:20242/metrics"}"#
    XCTAssertEqual(QuickTunnelProvider.readinessURL(from: output)?.absoluteString,
                   "http://127.0.0.1:20242/ready")
    XCTAssertNil(QuickTunnelProvider.readinessURL(
      from: "Starting metrics server on 198.18.0.1:20242/metrics"))
    XCTAssertNil(QuickTunnelProvider.readinessURL(
      from: "Starting metrics server on 127.0.0.1:65536/metrics"))
  }

  func testQuickTunnelKeepsItsAddressWhilePublicDNSWarmsUp() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let provider = FixtureProvider(.quick, initiallyReconnecting: true)

    try await manager.connect(provider)
    let waiting = await manager.snapshot()
    XCTAssertEqual(waiting.state, .reconnecting)
    XCTAssertEqual(waiting.publicOrigin?.absoluteString,
                   "https://fixture.trycloudflare.com")
    let preAdmissionStatus = await provider.preAdmissionStatus
    XCTAssertEqual(preAdmissionStatus, 503)

    await provider.becomeReady()
    let ready = await manager.snapshot()
    XCTAssertEqual(ready.state, .ready)
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

  func testProviderCredentialsAndTunnelIDsAreNotInterchangeable() throws {
    XCTAssertNoThrow(try ConnectionContract.validateTunnelID("tunnel_fixture123"))
    XCTAssertNoThrow(try ConnectionContract.validateCredential("sk-" + String(repeating: "x", count: 40), provider: .openAI))
    XCTAssertNoThrow(try ConnectionContract.validateCredential(String(repeating: "n", count: 30), provider: .ngrok))
    for id in ["https://example.com", "tunnel_", "tunnel_foo\nbar", "tunnel_foo/bar"] {
      XCTAssertThrowsError(try ConnectionContract.validateTunnelID(id))
    }
    XCTAssertThrowsError(try ConnectionContract.validateCredential(String(repeating: "n", count: 30), provider: .openAI))
    XCTAssertThrowsError(try ConnectionContract.validateCredential(String(repeating: "n", count: 30) + "\n", provider: .ngrok))
  }

  func testOpenAIRuntimeIsAnAppOwnedPinnedRelease() throws {
    for build in [ConnectionExecutables.arm64, ConnectionExecutables.intel] {
      XCTAssertEqual(build.openAIURL.scheme, "https")
      XCTAssertEqual(build.openAIURL.host, "github.com")
      XCTAssertTrue(build.openAIURL.path.contains("/openai/tunnel-client/releases/download/v0.0.14/"))
      XCTAssertEqual(build.openAIArchiveSHA.count, 64)
      XCTAssertEqual(build.openAIBinarySHA.count, 64)
    }
    XCTAssertNotEqual(ConnectionExecutables.arm64.openAIArchiveSHA,
                      ConnectionExecutables.intel.openAIArchiveSHA)
    XCTAssertNotEqual(ConnectionExecutables.arm64.openAIBinarySHA,
                      ConnectionExecutables.intel.openAIBinarySHA)

    let f = try Fixture(); defer { f.remove() }
    let bytes = Data("reviewed-openai-runtime-fixture".utf8)
    let file = f.contextDataRoot.appendingPathComponent("provider-runtime.bin")
    try PrivateFiles.atomicWrite(bytes, to: file)
    let digest = Budget.sha256(bytes)
    let synthetic = ConnectionExecutables.Build(
      architecture: "fixture", openAIArchiveSHA: digest, openAIBinarySHA: digest,
      ngrokURL: URL(string: "https://bin.ngrok.com/fixture.zip")!, ngrokArchiveSHA: digest)
    XCTAssertNoThrow(try ConnectionExecutables.verifyOpenAIArchive(file, build: synthetic))
    XCTAssertNoThrow(try ConnectionExecutables.verifyOpenAIBinary(file, build: synthetic))

    let changed = f.contextDataRoot.appendingPathComponent("provider-runtime-changed.bin")
    try PrivateFiles.atomicWrite(Data("changed".utf8), to: changed)
    XCTAssertThrowsError(try ConnectionExecutables.verifyOpenAIArchive(changed, build: synthetic))
    XCTAssertThrowsError(try ConnectionExecutables.verifyOpenAIBinary(changed, build: synthetic))
  }

  func testOpenAIHealthFileCanOnlySelectLoopbackHTTP() {
    XCTAssertEqual(OpenAITunnelProvider.healthBase("http://127.0.0.1:44123\n")?.port, 44123)
    for raw in ["https://127.0.0.1:44123", "http://remote.example:44123",
      "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:44123/path",
      "http://a:b@127.0.0.1:44123", "http://127.0.0.1:44123?x=1", "file:///etc/hosts"] {
      XCTAssertNil(OpenAITunnelProvider.healthBase(raw), raw)
    }
  }

  func testNgrokReadinessMustMatchDomainAndOwnedUpstreamPort() {
    let origin = URL(string: "https://fixture.ngrok-free.app")!
    let endpoint = URL(string: "http://127.0.0.1:45678/mcp")!
    func payload(_ domain: String, _ upstream: String) -> JSONValue {
      ["tunnels": [["public_url": .string(domain), "config": ["addr": .string(upstream)]]]]
    }
    XCTAssertTrue(NgrokProvider.matches(payload(origin.absoluteString, "http://127.0.0.1:45678"), origin: origin, endpoint: endpoint))
    for (domain, upstream) in [
      ("https://other.ngrok-free.app", "http://127.0.0.1:45678"),
      (origin.absoluteString, "http://127.0.0.1:45679"),
      (origin.absoluteString, "http://192.168.0.1:45678"),
      (origin.absoluteString, "http://u:p@127.0.0.1:45678"),
      (origin.absoluteString, "http://127.0.0.1:45678/other"),
    ] { XCTAssertFalse(NgrokProvider.matches(payload(domain, upstream), origin: origin, endpoint: endpoint)) }
    XCTAssertTrue(NgrokProvider.configuration.contains("remote_management: false"))
    XCTAssertFalse(NgrokProvider.configuration.contains("authtoken:"))
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

  func testOpenAIIngressUsesFreshRemoteCredentialNotLocalBearer() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let local = try JSONValue.decode(Data(try await runtime.localConnectionConfiguration().utf8))
    let provider = FixtureProvider(.openAI)
    try await manager.connect(provider)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    let missing = try await rpc(endpoint)
    let localBearer = try await rpc(endpoint, bearer: local["headers"]["Authorization"].string)
    let ownBearer = "Bearer " + (try XCTUnwrap(provider.privateCredential))
    let admitted = try await rpc(endpoint, bearer: ownBearer,
      method: "tools/call", params: ["name": "project_info", "arguments": [:]])
    XCTAssertEqual(missing.0, 401)
    XCTAssertEqual(localBearer.0, 401)
    XCTAssertEqual(admitted.0, 200)
    let snapshot = await manager.snapshot()
    XCTAssertEqual(snapshot.providerID, .openAI)
    XCTAssertNil(snapshot.publicOrigin)
    let runtimeSnapshot = await runtime.snapshot()
    XCTAssertEqual(runtimeSnapshot.activity.last?.source?.transport, .openAI)
    let report = await manager.doctor()
    XCTAssertTrue(report?.passed == true)
    let pending = await manager.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
    await manager.disconnect()
    let second = FixtureProvider(.openAI)
    XCTAssertNotEqual(provider.privateCredential, second.privateCredential)
    let stillLocal = try await rpc(URL(string: try XCTUnwrap(local["url"].string))!,
                                  bearer: local["headers"]["Authorization"].string)
    XCTAssertEqual(stillLocal.0, 200)
  }

  func testIndependentProvidersRunInParallelAgainstOneRuntime() async throws {
    let f = try Fixture()
    let runtime = try RuntimeCore(
      root: f.root, helper: Fixture.helper, contextDataRoot: f.contextDataRoot)
    let cloudflare = ConnectionManager(
      router: runtime.router, store: OAuthStore(url: nil))
    let openAI = ConnectionManager(
      router: runtime.router, store: OAuthStore(url: nil))
    addTeardownBlock {
      await cloudflare.shutdown()
      await openAI.shutdown()
      await runtime.stop()
      f.remove()
    }
    try await runtime.start()

    let cloudflareProvider = FixtureProvider(.cloudflare)
    let openAIProvider = FixtureProvider(.openAI)
    async let cloudflareStart: Void = cloudflare.connect(cloudflareProvider)
    async let openAIStart: Void = openAI.connect(openAIProvider)
    _ = try await (cloudflareStart, openAIStart)

    let cloudflareState = await cloudflare.snapshot()
    let openAIState = await openAI.snapshot()
    let cloudflareEndpoint = await cloudflareProvider.endpoint
    let openAIEndpoint = await openAIProvider.endpoint
    XCTAssertEqual(cloudflareState.state, .ready)
    XCTAssertEqual(openAIState.state, .ready)
    XCTAssertNotEqual(cloudflareEndpoint, openAIEndpoint)
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

  func testAuthorizationListsAreScopedToProviderAndNotGlobal() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let cloudflare = model.authorizationStore(for: .cloudflare)
    let ngrok = model.authorizationStore(for: .ngrok)
    try cloudflare.bindOrigin("https://mcp.example.com")
    try ngrok.bindOrigin("https://fixture.ngrok-free.app")
    let first = try approvedClient(cloudflare)
    let second = try approvedClient(ngrok)
    let list = OAuthClientModel(store: cloudflare)
    XCTAssertEqual(list.clients.map(\.id), [first.id])
    list.use(store: ngrok)
    XCTAssertEqual(list.clients.map(\.id), [second.id])
    list.delete(second.id)
    XCTAssertNotNil(cloudflare.client(first.id))
    XCTAssertTrue(ngrok.clients.isEmpty)
  }

  func testEveryOrdinaryProviderRequiresItsOwnConfigurationBeforeEnabling() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = false
    model.otherProviderCredentials = []
    for id in ConnectionProviderID.persistentProviders {
      XCTAssertFalse(model.setConnectionProviderEnabled(id, enabled: true))
    }
    XCTAssertTrue(model.isConnectionProviderConfigured(.quick))
    XCTAssertFalse(model.setConnectionProviderEnabled(.quick, enabled: true))
    XCTAssertTrue(model.authorizationStore(for: .quick).isEphemeral)
    f.defaults.set("tunnel_fixture123", forKey: "connection.openai.address")
    model.otherProviderCredentials.insert(.openAI)
    XCTAssertTrue(model.setConnectionProviderEnabled(.openAI, enabled: true))
    XCTAssertEqual(model.availableConnectionProviders, [.openAI])
    XCTAssertFalse(model.isConnectionProviderConfigured(.ngrok))
    let persisted = try XCTUnwrap(f.defaults.data(forKey: "enabledConnectionProviders"))
    XCTAssertEqual(try JSONDecoder().decode(Set<ConnectionProviderID>.self, from: persisted), [.openAI])
  }

  func testPersistedProviderSelectionDropsTemporaryQuickTunnel() throws {
    let f = try Fixture(); defer { f.remove() }
    let encoded = try JSONEncoder().encode(Set<ConnectionProviderID>([.openAI, .quick]))
    f.defaults.set(encoded, forKey: "enabledConnectionProviders")
    f.defaults.set("tunnel_fixture123", forKey: "connection.openai.address")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.otherProviderCredentials.insert(.openAI)
    XCTAssertEqual(model.enabledConnectionProviders, [.openAI])
    XCTAssertFalse(model.isProviderEnabled(.quick))
  }

  func testConfiguredPublicProvidersExposeCompleteMCPServerURL() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    f.defaults.set("https://fixture.ngrok-free.app", forKey: "connection.ngrok.address")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = true
    model.otherProviderCredentials = [.ngrok]

    XCTAssertEqual(
      model.configuredMCPServerURL(.cloudflare)?.absoluteString,
      "https://mcp.example.com/mcp")
    XCTAssertEqual(
      model.configuredMCPServerURL(.ngrok)?.absoluteString,
      "https://fixture.ngrok-free.app/mcp")
    XCTAssertNil(model.configuredMCPServerURL(.openAI))
  }

  func testEnablingMultipleProvidersPreservesIndependentAuthorizations() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    f.defaults.set("tunnel_fixture123", forKey: "connection.openai.address")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.tokenSaved = true
    model.otherProviderCredentials = [.openAI]
    model.enabledConnectionProviders = [.cloudflare]
    let store = model.authorizationStore(for: .cloudflare)
    try store.bindOrigin("https://mcp.example.com")
    _ = try approvedClient(store)
    model.doctorReports[.cloudflare] = .init(checkedAt: Date(), checks: [.init(id: "doctor.resource", passed: true)])
    XCTAssertTrue(model.setConnectionProviderEnabled(.openAI, enabled: true))
    XCTAssertEqual(Set(model.availableConnectionProviders), [.cloudflare, .openAI])
    XCTAssertFalse(store.clients.isEmpty)
    XCTAssertNotNil(model.doctorReports[.cloudflare])
    let persisted = try XCTUnwrap(f.defaults.data(forKey: "enabledConnectionProviders"))
    XCTAssertEqual(
      try JSONDecoder().decode(Set<ConnectionProviderID>.self, from: persisted),
      [.cloudflare, .openAI])
  }
}
