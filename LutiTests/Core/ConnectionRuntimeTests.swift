import AppKit
import XCTest

@testable import Luti

private actor TestConnectionProvider: ConnectionProvider {
  enum Behavior { case ready, fail, suspended }
  nonisolated let id = ConnectionProviderID.openAI
  nonisolated let privateCredential = "lt_" + Budget.token()
  private let behavior: Behavior
  private var state = ConnectionSnapshot.stopped
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var endpoint: URL?

  init(_ behavior: Behavior = .ready) { self.behavior = behavior }
  func start(endpoint: URL) async throws {
    starts += 1
    self.endpoint = endpoint
    if behavior == .fail {
      throw Failure("test_transport_failure", "Transport failed.", "Reconnect explicitly.")
    }
    if behavior == .suspended { await withCheckedContinuation { waiter = $0 } }
    // Deliberately permits late success to exercise the manager's generation guard.
    state = ConnectionSnapshot(state: .ready)
  }
  func fail() { state = ConnectionSnapshot(state: .failed, message: "Transport lost.") }
  func snapshot() -> ConnectionSnapshot { state }
  func stop() {
    stops += 1
    state = .stopped
    waiter?.resume()
    waiter = nil
  }
}

@MainActor final class ConnectionRuntimeTests: XCTestCase {
  private func makeRuntime(execution: Bool = false) throws -> (Fixture, RuntimeCore) {
    let f = try Fixture()
    let policy = execution ? ProjectExecutionPolicy.fullLocal(localApproval: true) : .readOnly
    let runtime = try RuntimeCore(root: f.root, helper: Fixture.helper, executionPolicy: policy,
                                  contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await runtime.stop(); f.remove() }
    return (f, runtime)
  }
  private func manager(_ f: Fixture, _ runtime: RuntimeCore) -> ConnectionManager {
    let result = ConnectionManager(router: runtime.router)
    addTeardownBlock { await result.shutdown() }
    return result
  }
  private func response(_ url: URL, authorization: String? = nil, origin: String? = nil)
    async throws -> HTTPURLResponse {
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    request.httpBody = try JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]).data()
    let (_, response) = try await URLSession.shared.data(for: request)
    return try XCTUnwrap(response as? HTTPURLResponse)
  }
  func testProjectRuntimeStartsWithoutRemoteConfiguration() async throws {
    let (_, runtime) = try makeRuntime()
    try await runtime.start()
    let status = await runtime.router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertFalse(status.isError)
    XCTAssertEqual(status.data["running"], true)
  }

  func testPrivateIngressDoesNotAcceptUnknownCredentialOrBrowserOrigin() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider()
    try await connections.connect(provider)
    let captured = await provider.endpoint
    let remoteURL = try XCTUnwrap(captured)
    let unknown = try await response(remoteURL, authorization: "Bearer " + Budget.token())
    XCTAssertEqual(unknown.statusCode, 401)
    let fromBrowser = try await response(remoteURL, authorization: "Bearer " + provider.privateCredential,
      origin: "https://untrusted.invalid")
    XCTAssertEqual(fromBrowser.statusCode, 403)
    let admitted = try await response(remoteURL, authorization: "Bearer " + provider.privateCredential)
    XCTAssertEqual(admitted.statusCode, 200)
  }

  func testProviderStartupFailureLeavesProjectRuntimeUsable() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    do { try await connections.connect(TestConnectionProvider(.fail)); XCTFail("Expected transport failure") }
    catch { XCTAssertEqual((error as? Failure)?.code, "test_transport_failure") }
    let snapshot = await connections.snapshot()
    XCTAssertEqual(snapshot.state, .failed)
    let project = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(project.isError)
    // Retry is an explicit new connection, not a duplicate runtime or job.
    try await connections.connect(TestConnectionProvider())
    let retried = await connections.snapshot()
    XCTAssertEqual(retried.state, .ready)
  }

  func testRemoteFailureAndDisconnectPreserveRunningProjectJob() async throws {
    let (f, runtime) = try makeRuntime(execution: true)
    try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider()
    try await connections.connect(provider)
    let job = await runtime.router.callInCurrentProject("run_process", arguments: [
      "program": "/bin/sleep", "args": ["20"], "syncWait": 0, "timeout": 30])
    XCTAssertFalse(job.isError)
    let id = try XCTUnwrap(job.data["jobId"].string)
    await provider.fail()
    let failed = await connections.snapshot()
    XCTAssertEqual(failed.state, .failed)
    await connections.disconnect()
    let existing = await runtime.router.callInCurrentProject("job_query", arguments: ["action": "status", "jobId": .string(id)])
    XCTAssertEqual(existing.data["status"], "running")
    let project = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(project.isError)
  }

  func testCancelConnectCannotResurrectIngressAndShutdownRetiresManager() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider(.suspended)
    let start = Task { try await connections.connect(provider) }
    for _ in 0..<200 {
      if await provider.starts > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let starts = await provider.starts
    XCTAssertEqual(starts, 1)
    await connections.shutdown()
    do { try await start.value; XCTFail("Late completion must be rejected") } catch {}
    let stopped = await connections.snapshot()
    XCTAssertEqual(stopped.state, .stopped)
    do { try await connections.connect(TestConnectionProvider()); XCTFail("Retired manager cannot restart") }
    catch { XCTAssertEqual((error as? Failure)?.code, Failure.stopped.code) }
  }

  func testDuplicateConnectDoesNotLaunchAnotherProvider() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    try await connections.connect(TestConnectionProvider())
    let duplicate = TestConnectionProvider()
    do { try await connections.connect(duplicate); XCTFail("Duplicate Connect must fail") } catch {}
    let starts = await duplicate.starts
    XCTAssertEqual(starts, 0)
  }

  func testStoppedRuntimeCannotRestartOrAcceptProjectCalls() async throws {
    let (_, runtime) = try makeRuntime()
    try await runtime.start()
    await runtime.stop()
    do { try await runtime.start(); XCTFail("Runtime has one lifetime") } catch {}
    let stopped = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertEqual(stopped.data["error"], "runtime_stopped")
  }

  func testUnfinishedRemoteSettingsDoNotDisableProjectPreparation() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.activeProject = ApprovedProject(url: f.root)
    model.tunnelID = "unfinished remote configuration"
    model.apiKeyDraft = "unsaved"
    model.apiKeySaved = false
    XCTAssertTrue(model.canStart)
    XCTAssertFalse(model.canConnect)
  }

  func testInvalidConnectionSettingsAreRejectedWithoutTouchingSavedState() async throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.activeProject = ApprovedProject(url: f.root)
    model.tunnelID = "not-a-tunnel"
    let saved = await model.saveConnection()
    XCTAssertFalse(saved)
    XCTAssertNotNil(model.connectionSettingsError)
    XCTAssertEqual(model.savedTunnelID, "tunnel_0123456789abcdef0123456789abcdef")
    model.tunnelID = "tunnel_fedcba9876543210fedcba9876543210"
    model.apiKeyDraft = "not-an-api-key"
    let resaved = await model.saveConnection()
    XCTAssertFalse(resaved)
    XCTAssertEqual(model.savedTunnelID, "tunnel_0123456789abcdef0123456789abcdef")
    XCTAssertTrue(model.canStart)
  }

  func testSelectedFolderSurvivesDirectRuntimeStartStopAndReopen() async throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    let project = try XCTUnwrap(model.activeProject)
    addTeardownBlock { await model.stop() }
    model.requestStart()
    for _ in 0..<200 {
      if model.phase == .running || model.phase == .failed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.phase, .running)
    await model.stop()
    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertEqual(reopened.activeProject, project)
  }

  func testStartIsResumedAfterQuitButNotAfterExplicitStop() async throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    model.requestStart()
    XCTAssertTrue(f.defaults.bool(forKey: "runtime.resumeOnLaunch"))
    await model.stop(keepResume: true)
    XCTAssertTrue(f.defaults.bool(forKey: "runtime.resumeOnLaunch"), "Quit keeps the runtime for the next launch.")
    model.requestStart()
    await model.stop()
    XCTAssertFalse(f.defaults.bool(forKey: "runtime.resumeOnLaunch"))
  }

  func testImmediateStopDoesNotResurrectQueuedNativeStartup() async throws {
    let f = try Fixture()
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    addTeardownBlock { await model.stop(); f.remove() }
    let project = ApprovedProject(url: f.root)
    model.activeProject = project

    model.requestStart()
    await model.stop()
    await model.refresh()
    XCTAssertEqual(model.phase, .stopped)
    XCTAssertEqual(model.connection, .stopped)
    XCTAssertTrue(model.canStart)
  }

  func testNativeStartWithoutAPIKeyKeepsRemoteUnavailable() async throws {
    let f = try Fixture()
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    addTeardownBlock { await model.stop(); f.remove() }
    let project = ApprovedProject(url: f.root)
    model.activeProject = project

    model.apiKeySaved = false
    model.requestStart()
    for _ in 0..<200 {
      if model.phase == .running || model.phase == .failed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.connection, .stopped)
    XCTAssertFalse(model.connectionBusy)
  }

  func testDisconnectClosesOnlyIngressAndAllowsExplicitReconnect() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider()
    try await connections.connect(provider)
    let endpoint = await provider.endpoint
    let ingress = try XCTUnwrap(endpoint)
    let before = try await response(ingress)
    XCTAssertEqual(before.statusCode, 401)
    await connections.disconnect()
    do {
      _ = try await response(ingress)
      XCTFail("Disconnected ingress must not accept requests")
    } catch is URLError {}
    let available = await runtime.router.callInCurrentProject("project_info", arguments: [:])
    XCTAssertFalse(available.isError)
    try await connections.connect(TestConnectionProvider())
    let reconnected = await connections.snapshot()
    XCTAssertEqual(reconnected.state, .ready)
  }

}
