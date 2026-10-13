import AppKit
import Foundation
import XCTest

@testable import Luti

/// No cloud process, account or public network is used by this suite.
private actor FixtureProvider: ConnectionProvider {
  nonisolated let id = ConnectionProviderID.openAI
  nonisolated let privateCredential = "lt_" + Budget.token()
  private let stateAfterStart: ConnectionState
  private var state = ConnectionSnapshot.stopped
  private(set) var endpoint: URL?

  init(stateAfterStart: ConnectionState = .ready) {
    self.stateAfterStart = stateAfterStart
  }
  func start(endpoint: URL) async throws {
    self.endpoint = endpoint
    state = ConnectionSnapshot(state: stateAfterStart)
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
    let provider = FixtureProvider(stateAfterStart: .starting)
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

  /// A verified transport that is retrying its network stays up and reports why.
  func testVerifiedProviderMayStartReconnecting() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    try await manager.connect(FixtureProvider(stateAfterStart: .reconnecting))
    let snapshot = await manager.snapshot()
    XCTAssertEqual(snapshot.state, .reconnecting)
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
    XCTAssertNoThrow(try ConnectionContract.validateTunnelID("tunnel_0123456789abcdef0123456789abcdef"))
    for invalid in ["", "fixture123", "tunnel_", "tunnel_bad id", "tunnel_x/y", "tunnel_fixture123",
      "tunnel_" + String(repeating: "A", count: 32), "tunnel_" + String(repeating: "a", count: 31),
      "tunnel_" + String(repeating: "a", count: 33)] {
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
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    model.tunnelID = "tunnel_0123456789abcdef0123456789abcdef"
    XCTAssertFalse(model.connectionConfigured)
    model.apiKeySaved = true
    XCTAssertTrue(model.connectionConfigured)
    model.phase = .running
    XCTAssertTrue(model.canConnect)
    model.savingConnection = true
    XCTAssertFalse(model.canConnect, "Save/clear in flight must not connect with old settings.")
    XCTAssertFalse(model.canEditConnection)
    model.savingConnection = false
    model.tunnelID = "tunnel_changed"
    XCTAssertFalse(model.canConnect, "Unsaved edits must be saved before connecting.")
    model.phase = .stopped
    model.activeProject = ApprovedProject(url: f.root)
    XCTAssertFalse(model.canLaunch, "Start must not run a runtime whose tunnel cannot connect.")
    model.tunnelID = "tunnel_0123456789abcdef0123456789abcdef"
    model.apiKeyDraft = "sk-" + String(repeating: "b", count: 40)
    XCTAssertFalse(model.canLaunch)
    model.apiKeyDraft = ""
    XCTAssertTrue(model.canLaunch)
    model.phase = .running
    model.tunnelID = "tunnel_0123456789abcdef0123456789abcdef"
    model.apiKeySaved = false
    XCTAssertFalse(model.canConnect)
  }

  func testPollReasonKeepsOnlyTheBoundedCause() {
    XCTAssertEqual(
      OpenAITunnelProvider.pollReason(#"Get "https://api.openai.com/v1/tunnels/t/poll?limit=20": unexpected EOF"#),
      "unexpected EOF")
    XCTAssertEqual(OpenAITunnelProvider.pollReason(""), "unknown error")
    XCTAssertLessThanOrEqual(OpenAITunnelProvider.pollReason(String(repeating: "x", count: 500)).utf8.count, 200)
  }

  func testLastSuccessfulPollReadsTunnelClientMetrics() {
    let metrics = """
      # HELP commands_poll_last_successful_timestamp_seconds Unix timestamp in seconds of the last successful poll.
      commands_poll_last_successful_timestamp_seconds{otel_scope_name="controlplane"} 1.791769889e+09
      """
    XCTAssertEqual(OpenAITunnelProvider.lastSuccessfulPoll(metrics), 1_791_769_889)
    XCTAssertNil(OpenAITunnelProvider.lastSuccessfulPoll(
      #"commands_poll_last_successful_timestamp_seconds{otel_scope_name="controlplane"} 0"#))
  }

  func testLogGapCannotLetOlderSuccessEraseNewPollFailure() {
    var state = OpenAITunnelProvider.PollState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertFalse(state.read([["seq": 100, "message": "tunnel metadata fetched"]], now: now))
    let missed = state.read([[
      "seq": 202, "message": "poll failed; backing off",
      "time": "2023-11-14T22:13:19.500Z", "attrs": ["error": "connection refused"],
    ]], now: now)
    XCTAssertTrue(missed)
    state.recordSuccess(now.timeIntervalSince1970 - 20, missedEvents: missed, now: now)
    XCTAssertTrue(state.controlPlaneReached)
    XCTAssertEqual(state.pollError, "connection refused")
    // Re-reading the same batch must not reset the failure's timestamp or state.
    XCTAssertFalse(state.read([["seq": 202, "message": "poller recovered; polling operational"]], now: now))
    XCTAssertEqual(state.pollError, "connection refused")
  }

  func testOnlyNewerRecentMetricsRecoverAMissedPollRecovery() {
    var state = OpenAITunnelProvider.PollState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = state.read([["seq": 100, "message": "tunnel metadata fetched"]], now: now)
    _ = state.read([[
      "seq": 101, "message": "poll timed out; backing off",
      "time": "2023-11-14T22:13:00Z",
    ]], now: now)
    let missed = state.read([["seq": 202, "message": "unrelated event"]], now: now)
    XCTAssertTrue(missed)
    for timestamp in [now.timeIntervalSince1970 - 50, now.timeIntervalSince1970 - 20,
                      now.timeIntervalSince1970 + 1] {
      state.recordSuccess(timestamp, missedEvents: missed, now: now)
      XCTAssertNotNil(state.pollError, "Stale, equal or future metrics cannot prove recovery.")
    }
    state.recordSuccess(now.timeIntervalSince1970 - 1, missedEvents: missed, now: now)
    XCTAssertNil(state.pollError)
  }

  func testUntimedFailureWaitsForNewEvidenceAndOrderedRecoveryStillWorks() {
    var state = OpenAITunnelProvider.PollState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    _ = state.read([["seq": 100, "message": "tunnel metadata fetched"]], now: now)
    let missed = state.read([["seq": 202, "message": "poll failed; backing off"]], now: now)
    state.recordSuccess(now.timeIntervalSince1970, missedEvents: missed, now: now)
    XCTAssertNotNil(state.pollError)
    _ = state.read([["seq": 203, "message": "poller recovered; polling operational"]], now: now)
    XCTAssertNil(state.pollError)
    _ = state.read([["seq": 204, "message": "poll failed; backing off"]], now: now)
    XCTAssertNotNil(state.pollError, "A subsequent failure must replace the recovery.")
  }

  func testSuccessfulMetricsCanStillConfirmInitialAuthentication() {
    var state = OpenAITunnelProvider.PollState()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    state.recordSuccess(now.timeIntervalSince1970 - 1, missedEvents: false, now: now)
    XCTAssertTrue(state.controlPlaneReached)
    XCTAssertNil(state.pollError)
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
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
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

extension ConnectionProviderTests {
  func testSavedRuntimeResumesAfterUnavailableKeychainProbeAndRead() async throws {
    let f = try Fixture()
    let key = "sk-" + String(repeating: "a", count: 40)
    let store = FixtureKeychain(values: [KeychainService.openAIAPIKey: key],
      failedReads: [KeychainService.openAIAPIKey: 1], failedProbes: 1)
    let provider = FixtureProvider()
    let selected = ApprovedProject(url: f.root)
    let tunnel = "tunnel_0123456789abcdef0123456789abcdef"
    f.defaults.set(try JSONEncoder().encode(selected), forKey: "selectedFolder")
    f.defaults.set(tunnel, forKey: "connection.openai.tunnelID")
    f.defaults.set(true, forKey: "runtime.resumeOnLaunch")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults,
      credentials: store.client, makeProvider: { id, credential, _ in
        guard id == tunnel, credential == key else { throw Failure.invalid("Saved configuration changed.") }
        return provider
      })
    addTeardownBlock { await model.stop(); f.remove() }
    for _ in 0..<200 {
      if model.connection.state == .failed && !model.connectionBusy { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.connection.state, .failed)
    let run = try XCTUnwrap(model.currentRunID)
    for _ in 0..<240 {
      if model.connection.state == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.connection.state, .ready)
    XCTAssertEqual(model.currentRunID, run)
    XCTAssertEqual(model.activeProject, selected)
    XCTAssertEqual(model.savedTunnelID, tunnel)
    XCTAssertEqual(store.value(KeychainService.openAIAPIKey), key)
    XCTAssertEqual(store.readInteractions, [true, false])
    await model.stop()

    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
    addTeardownBlock { await reopened.stop() }
    await Task.yield()
    XCTAssertEqual(reopened.phase, .stopped, "Explicit Stop prevents launch recovery.")
    XCTAssertFalse(f.defaults.bool(forKey: "runtime.resumeOnLaunch"))
    XCTAssertEqual(reopened.activeProject, selected)
    XCTAssertEqual(reopened.savedTunnelID, tunnel)
  }

  func testSavedRuntimeDoesNotResumeWhenCredentialIsConfirmedMissing() async throws {
    let f = try Fixture()
    f.defaults.set(try JSONEncoder().encode(ApprovedProject(url: f.root)), forKey: "selectedFolder")
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    f.defaults.set(true, forKey: "runtime.resumeOnLaunch")
    let store = FixtureKeychain()
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
    addTeardownBlock { await model.stop(); f.remove() }
    await Task.yield()
    XCTAssertEqual(model.phase, .stopped)
    XCTAssertFalse(model.apiKeySaved)
    XCTAssertFalse(model.canLaunch)
    XCTAssertTrue(store.readInteractions.isEmpty)
  }

  func testPreparationFailureRetriesWithoutRestartingRuntimeOrPromptingAgain() async throws {
    let f = try Fixture(); defer { f.remove() }
    let store = FixtureKeychain(values: [KeychainService.openAIAPIKey: "synthetic-key"],
      failedReads: [KeychainService.openAIAPIKey: 1])
    let provider = FixtureProvider()
    let tunnel = "tunnel_0123456789abcdef0123456789abcdef"
    f.defaults.set(tunnel, forKey: "connection.openai.tunnelID")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults,
      credentials: store.client, makeProvider: { _, _, _ in provider })
    model.addProject(f.root); model.requestStart()
    for _ in 0..<200 {
      if model.connection.state == .failed && !model.connectionBusy { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(model.connection.state, .failed)
    let run = model.currentRunID
    await model.refresh()
    XCTAssertEqual(model.connection.state, .failed)
    for _ in 0..<200 {
      await model.refresh()
      if model.connection.state == .ready { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.connection.state, .ready)
    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.currentRunID, run)
    XCTAssertEqual(store.readInteractions, [true, false])
    await model.stop()
  }

  func testMissingCredentialStaysFailedWithoutAutomaticReadLoop() async throws {
    let f = try Fixture(); defer { f.remove() }
    let store = FixtureKeychain()
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
    model.apiKeySaved = true // A credential removed after launch.
    model.addProject(f.root); model.requestStart()
    for _ in 0..<200 {
      if model.connection.state == .failed && !model.connectionBusy { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    for _ in 0..<25 { await model.refresh(); try await Task.sleep(for: .milliseconds(250)) }
    XCTAssertEqual(model.connection.state, .failed)
    XCTAssertFalse(model.apiKeySaved)
    XCTAssertEqual(store.readInteractions, [true])
    await model.stop()
  }
}
