import AppKit
import Foundation
import XCTest

@testable import Luti

/// No cloud process, account or public network is used by this suite.
private actor FixtureProvider: ConnectionProvider {
  nonisolated let id = ConnectionProviderID.openAI
  nonisolated let privateCredential = "lt_" + Budget.token()
  private let initiallyReconnecting: Bool
  private var state = ConnectionSnapshot.stopped
  private(set) var endpoint: URL?

  init(initiallyReconnecting: Bool = false) {
    self.initiallyReconnecting = initiallyReconnecting
  }
  func start(endpoint: URL) async throws {
    self.endpoint = endpoint
    state = ConnectionSnapshot(state: initiallyReconnecting ? .reconnecting : .ready)
  }
  func snapshot() -> ConnectionSnapshot { state }
  func stop() { state = .stopped }
}

@MainActor final class ConnectionProviderTests: XCTestCase {
  private func fixture() throws -> (Fixture, RuntimeCore, ConnectionManager) {
    let f = try Fixture()
    let runtime = try RuntimeCore(root: f.root, helper: Fixture.helper, contextDataRoot: f.contextDataRoot)
    let manager = ConnectionManager(router: runtime.router)
    addTeardownBlock { await manager.shutdown(); await runtime.stop(); f.remove() }
    return (f, runtime, manager)
  }

  private func rpc(_ endpoint: URL, bearer: String? = nil,
                   method: String = "tools/list", params: JSONValue = [:]) async throws -> (Int, JSONValue) {
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 3
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let bearer { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
    request.httpBody = try JSONValue.object([
      "jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]).data()
    let (data, response) = try await URLSession.shared.data(for: request)
    return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, (try? JSONValue.decode(data)) ?? .null)
  }

  func testLiteProviderCatalogContainsOnlyOpenAITunnel() {
    XCTAssertEqual(ConnectionProviderID.allCases, [.openAI])
    for removed in ["cloudflare", "ngrok", "quick", "custom"] {
      XCTAssertNil(ConnectionProviderID(rawValue: removed))
    }
  }

  func testProviderMustConfirmReadinessBeforeConnectionStarts() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let provider = FixtureProvider(initiallyReconnecting: true)
    do {
      try await manager.connect(provider)
      XCTFail("A provider must confirm its connection before becoming available.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "connection_not_ready")
    }
    let failed = await manager.snapshot()
    XCTAssertEqual(failed.state, .failed)
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

  func testTunnelConfigurationShapes() {
    XCTAssertNoThrow(try ConnectionContract.validateTunnelID("tunnel_fixture123"))
    for invalid in ["", "fixture123", "tunnel_", "tunnel_bad id", "tunnel_x/y"] {
      XCTAssertThrowsError(try ConnectionContract.validateTunnelID(invalid))
    }
    XCTAssertNoThrow(try ConnectionContract.validateAPIKey("sk-" + String(repeating: "a", count: 40)))
    for invalid in ["", "sk-short", "pk-" + String(repeating: "a", count: 40),
      "sk-" + String(repeating: "a", count: 20) + " b"] {
      XCTAssertThrowsError(try ConnectionContract.validateAPIKey(invalid))
    }
    XCTAssertNotNil(OpenAITunnelProvider.healthBase("http://127.0.0.1:41234\n"))
    for invalid in ["https://127.0.0.1:41234", "http://localhost:41234", "http://127.0.0.1:41234/readyz",
      "http://127.0.0.1"] {
      XCTAssertNil(OpenAITunnelProvider.healthBase(invalid))
    }
  }

  func testPrivateIngressAcceptsOnlyItsDelegatedCredential() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let provider = FixtureProvider()
    try await manager.connect(provider)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    let missing = try await rpc(endpoint)
    let unknownBearer = try await rpc(endpoint, bearer: "Bearer " + Budget.token())
    let admitted = try await rpc(endpoint, bearer: "Bearer " + provider.privateCredential,
      method: "tools/call", params: ["name": "project_info", "arguments": [:]])
    XCTAssertEqual(missing.0, 401)
    XCTAssertEqual(unknownBearer.0, 401)
    XCTAssertEqual(admitted.0, 200)
    let snapshot = await manager.snapshot()
    XCTAssertEqual(snapshot.providerID, .openAI)
    XCTAssertEqual(snapshot.state, .ready)
    let runtimeSnapshot = await runtime.snapshot()
    XCTAssertEqual(runtimeSnapshot.activity.last?.source?.transport, .openAI)
    await manager.disconnect()
    let project = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(project.isError)
  }

  func testOAuthDiscoveryIsGone() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let provider = FixtureProvider()
    try await manager.connect(provider)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    for path in ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server",
      "/authorize", "/token", "/register"] {
      var request = URLRequest(url: URL(string: path, relativeTo: endpoint)!)
      request.timeoutInterval = 3
      let (_, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404, path)
    }
  }

  func testOpenAIConfigurationRequiresTunnelIDAndSavedKey() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.apiKeySaved = false
    XCTAssertFalse(model.connectionConfigured)
    f.defaults.set("tunnel_fixture123", forKey: "connection.openai.tunnelID")
    model.tunnelID = "tunnel_fixture123"
    XCTAssertFalse(model.connectionConfigured)
    model.apiKeySaved = true
    XCTAssertTrue(model.connectionConfigured)
    model.phase = .running
    XCTAssertTrue(model.canConnect)
    model.tunnelID = "tunnel_changed"
    XCTAssertFalse(model.canConnect, "Unsaved edits must be saved before connecting.")
    model.tunnelID = "tunnel_fixture123"
    model.apiKeySaved = false
    XCTAssertFalse(model.canConnect)
  }

  func testStaleRunDirectoriesAreRemovedAtLaunch() throws {
    let f = try Fixture(); defer { f.remove() }
    let stale = f.contextDataRoot.appendingPathComponent("runs/connection-stale", isDirectory: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    _ = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
  }

  func testStatusRepresentsConfigurationAndActualConnection() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.apiKeySaved = false
    XCTAssertEqual(model.connectionStatusKey, "connection.notConfigured")
    f.defaults.set("tunnel_fixture123", forKey: "connection.openai.tunnelID")
    model.apiKeySaved = true
    XCTAssertEqual(model.connectionStatusKey, "connection.state.stopped")
    for state in [ConnectionState.starting, .ready, .reconnecting, .failed, .stopping] {
      model.connection = ConnectionSnapshot(state: state, providerID: .openAI)
      XCTAssertEqual(model.connectionStatusKey, "connection.state." + state.rawValue)
    }
    model.connection = .stopped
    XCTAssertEqual(model.connectionStatusKey, "connection.state.stopped")
  }
}
