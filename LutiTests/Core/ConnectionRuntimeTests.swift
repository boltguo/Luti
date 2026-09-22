import AppKit
import XCTest

@testable import Luti

private actor TestConnectionProvider: ConnectionProvider {
  enum Behavior { case ready, fail, suspended }
  nonisolated let publicOrigin = URL(string: "https://mcp.example.com")
  nonisolated let ingressPort: Int
  private let behavior: Behavior
  private var state = ConnectionSnapshot.stopped
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var endpoint: URL?

  init(_ behavior: Behavior = .ready, port: Int = 0) { self.behavior = behavior; ingressPort = port }
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
    let result = ConnectionManager(router: runtime.router,
      store: OAuthStore(url: f.contextDataRoot.appendingPathComponent("oauth-test.json")))
    addTeardownBlock { await result.shutdown() }
    return result
  }
  private func response(_ url: URL, authorization: String? = nil, origin: String? = nil,
                        host: String? = nil) async throws -> HTTPURLResponse {
    var request = URLRequest(url: url)
    request.timeoutInterval = 3
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    if let host { request.setValue(host, forHTTPHeaderField: "Host") }
    request.httpBody = try JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]).data()
    let (_, response) = try await URLSession.shared.data(for: request)
    return try XCTUnwrap(response as? HTTPURLResponse)
  }
  private func setup(_ runtime: RuntimeCore) async throws -> (URL, String) {
    let raw = try await runtime.localConnectionConfiguration()
    let json = try JSONValue.decode(Data(raw.utf8))
    let url = try XCTUnwrap(URL(string: try XCTUnwrap(json["url"].string)))
    return (url, try XCTUnwrap(json["headers"]["Authorization"].string))
  }

  func testLocalRuntimeNeedsNoRemoteConfigurationAndKeepsAuthentication() async throws {
    let (_, runtime) = try makeRuntime()
    let endpoint = try await runtime.start()
    let (url, authorization) = try await setup(runtime)
    XCTAssertEqual(endpoint, url)
    XCTAssertEqual(url.host, "127.0.0.1")
    let allowed = try await response(url, authorization: authorization)
    let missing = try await response(url)
    let wrong = try await response(url, authorization: "Bearer wrong")
    let evil = try await response(url, authorization: authorization, origin: "https://evil.example")
    let publicHost = try await response(url, authorization: authorization, host: "mcp.example.com")
    XCTAssertEqual(allowed.statusCode, 200)
    XCTAssertEqual(missing.statusCode, 401)
    XCTAssertEqual(wrong.statusCode, 401)
    XCTAssertEqual(evil.statusCode, 403)
    XCTAssertEqual(publicHost.statusCode, 403)
    let snapshot = await runtime.snapshot()
    XCTAssertFalse(String(reflecting: snapshot).contains(authorization))
  }

  func testPublicIngressDoesNotAcceptLocalCredential() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let (_, authorization) = try await setup(runtime)
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider()
    try await connections.connect(provider)
    let remoteURL = await provider.endpoint
    let response = try await response(XCTUnwrap(remoteURL), authorization: authorization, host: "mcp.example.com")
    XCTAssertEqual(response.statusCode, 401)
    XCTAssertTrue(response.value(forHTTPHeaderField: "WWW-Authenticate")?.contains("resource_metadata") == true)
  }

  func testProviderStartupFailureLeavesLocalRuntimeUsable() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let (url, auth) = try await setup(runtime)
    let connections = manager(f, runtime)
    do { try await connections.connect(TestConnectionProvider(.fail)); XCTFail("Expected transport failure") }
    catch { XCTAssertEqual((error as? Failure)?.code, "test_transport_failure") }
    let snapshot = await connections.snapshot()
    XCTAssertEqual(snapshot.state, .failed)
    let local = try await response(url, authorization: auth)
    XCTAssertEqual(local.statusCode, 200)
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
    let job = await runtime.router.call("run_process", arguments: [
      "program": "/bin/sleep", "args": ["20"], "syncWait": 0, "timeout": 30])
    XCTAssertFalse(job.isError)
    let id = try XCTUnwrap(job.data["jobId"].string)
    await provider.fail()
    let failed = await connections.snapshot()
    XCTAssertEqual(failed.state, .failed)
    await connections.disconnect()
    let existing = await runtime.router.call("job_query", arguments: ["action": "status", "jobId": .string(id)])
    XCTAssertEqual(existing.data["status"], "running")
    let (url, auth) = try await setup(runtime)
    let local = try await response(url, authorization: auth)
    XCTAssertEqual(local.statusCode, 200)
  }

  func testOccupiedIngressPortDoesNotStopLocalRuntime() async throws {
    let (f, runtime) = try makeRuntime()
    let endpoint = try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider(port: try XCTUnwrap(endpoint.port))
    do { try await connections.connect(provider); XCTFail("Port must not silently move") }
    catch { XCTAssertEqual((error as? Failure)?.code, "port_unavailable") }
    let starts = await provider.starts
    XCTAssertEqual(starts, 0)
    let (url, auth) = try await setup(runtime)
    let local = try await response(url, authorization: auth)
    XCTAssertEqual(local.statusCode, 200)
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

  func testStoppedRuntimeCannotExportOrReuseLocalCredentials() async throws {
    let (_, runtime) = try makeRuntime()
    try await runtime.start()
    await runtime.stop()
    do { _ = try await runtime.localConnectionConfiguration(); XCTFail("Stopped credentials must not be exported") } catch {}
    do { try await runtime.start(); XCTFail("Runtime has one lifetime") } catch {}
    let snapshot = await runtime.snapshot()
    XCTAssertNil(snapshot.localEndpoint)
  }

  func testUnfinishedRemoteSettingsNeverDisableLocalStart() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let project = ApprovedProject(url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.publicBaseURL = "unfinished remote configuration"
    model.tokenDraft = "unsaved"
    model.tokenSaved = false
    XCTAssertTrue(model.canStart)
    XCTAssertFalse(model.canConnectProvider(.cloudflare))
  }

  func testConnectionProviderRequiresConfigurationAndPersistsEnabledSelection() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let project = ApprovedProject(url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id

    XCTAssertFalse(model.setConnectionProviderEnabled(.cloudflare, enabled: true))
    XCTAssertTrue(model.enabledConnectionProviders.isEmpty)

    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    model.publicBaseURL = "https://mcp.example.com"
    model.tokenSaved = true
    XCTAssertTrue(model.setConnectionProviderEnabled(.cloudflare, enabled: true))
    XCTAssertEqual(model.availableConnectionProviders, [.cloudflare])
    XCTAssertEqual(model.approvedProjects, [project],
                   "Connection Enabled must never rewrite project state.")

    let persisted = try XCTUnwrap(f.defaults.data(forKey: "enabledConnectionProviders"))
    XCTAssertEqual(
      try JSONDecoder().decode(Set<ConnectionProviderID>.self, from: persisted),
      [.cloudflare])

    XCTAssertTrue(model.setConnectionProviderEnabled(.cloudflare, enabled: false))
    XCTAssertTrue(model.enabledConnectionProviders.isEmpty)
    XCTAssertTrue(model.availableConnectionProviders.isEmpty)
    XCTAssertEqual(model.approvedProjects, [project])
  }

  func testProjectPermissionDefaultsPersistPerProjectAndStopDoesNotReset() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let firstURL = f.root.appendingPathComponent("first", isDirectory: true)
    let secondURL = f.root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertFalse(model.defaultFullProjectAccess)
    model.addApprovedProjects([firstURL])
    let firstID = try XCTUnwrap(model.approvedProjects.first?.id)
    XCTAssertEqual(model.approvedProjects.first?.permissionMode, .ask)

    model.setDefaultFullProjectAccess(true)
    XCTAssertTrue(model.defaultFullProjectAccess)
    XCTAssertEqual(model.approvedProjects.first?.permissionMode, .ask,
                   "Changing the default must not rewrite existing projects.")

    model.addApprovedProjects([secondURL])
    let second = try XCTUnwrap(model.approvedProjects.first(where: { $0.path == secondURL.path }))
    XCTAssertEqual(second.permissionMode, .fullProjectAccess)

    model.setProjectPermissionMode(firstID, mode: .fullProjectAccess)
    XCTAssertEqual(
      model.approvedProjects.first(where: { $0.id == firstID })?.permissionMode,
      .fullProjectAccess)

    model.setActiveProject(firstID)
    model.startWithLocalConsent()
    for _ in 0..<200 {
      if model.phase == .running || model.phase == .failed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.phase, .running)
    model.setProjectPermissionMode(second.id, mode: .ask)
    XCTAssertEqual(
      model.approvedProjects.first(where: { $0.id == second.id })?.permissionMode,
      .fullProjectAccess,
      "Permission changes are frozen while the Runtime is active.")

    await model.stop()
    XCTAssertEqual(
      model.approvedProjects.first(where: { $0.id == firstID })?.permissionMode,
      .fullProjectAccess,
      "Stop must never reset the project's configured permission mode.")

    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertTrue(reopened.defaultFullProjectAccess)
    XCTAssertEqual(
      reopened.approvedProjects.first(where: { $0.id == firstID })?.permissionMode,
      .fullProjectAccess)
    XCTAssertEqual(
      reopened.approvedProjects.first(where: { $0.id == second.id })?.permissionMode,
      .fullProjectAccess)
  }

  func testLegacyApprovedProjectWithoutPermissionModeMigratesToAsk() throws {
    let f = try Fixture(); defer { f.remove() }
    let path = f.root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    let legacy = "[{\"id\":\"legacy\",\"name\":\"Legacy\",\"path\":\"" + path.path + "\"}]"
    f.defaults.set(Data(legacy.utf8), forKey: "approvedProjects")
    f.defaults.set("legacy", forKey: "activeProjectID")

    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertEqual(model.approvedProjects.first?.permissionMode, .ask)
  }

  func testImmediateStopDoesNotResurrectQueuedNativeStartup() async throws {
    let f = try Fixture()
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    addTeardownBlock { await model.stop(); f.remove() }
    let project = ApprovedProject(url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.startWithLocalConsent()
    await model.stop()
    await model.refresh()
    XCTAssertEqual(model.phase, .stopped)
    XCTAssertNil(model.localEndpoint)
    XCTAssertTrue(model.connectionSnapshots.isEmpty)
    XCTAssertTrue(model.canStart)
  }

  func testNativeStartDoesNotAutomaticallyEnableSavedRemoteAccess() async throws {
    let f = try Fixture()
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    f.defaults.set(
      try JSONEncoder().encode(Set<ConnectionProviderID>()),
      forKey: "enabledConnectionProviders")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    addTeardownBlock { await model.stop(); f.remove() }
    let project = ApprovedProject(url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.tokenSaved = true
    model.startWithLocalConsent()
    for _ in 0..<200 {
      if model.phase == .running || model.phase == .failed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.phase, .running)
    XCTAssertNotNil(model.localEndpoint)
    XCTAssertTrue(model.connectionSnapshots.isEmpty)
    XCTAssertTrue(model.connectionBusyProviders.isEmpty)
  }

  func testStopDismissesUnansweredExecutionConsent() async throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let project = ApprovedProject(url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.requestStart()
    XCTAssertTrue(model.showConsent)
    await model.stop()
    XCTAssertFalse(model.showConsent)
    XCTAssertEqual(model.phase, .stopped)
    let copied = await model.copyLocalConfiguration()
    XCTAssertFalse(copied)
  }

  func testDisconnectClosesOnlyIngressAndAllowsExplicitReconnect() async throws {
    let (f, runtime) = try makeRuntime()
    try await runtime.start()
    let connections = manager(f, runtime)
    let provider = TestConnectionProvider()
    try await connections.connect(provider)
    let endpoint = await provider.endpoint
    let ingress = try XCTUnwrap(endpoint)
    let before = try await response(ingress, host: "mcp.example.com")
    XCTAssertEqual(before.statusCode, 401)
    await connections.disconnect()
    do {
      _ = try await response(ingress, host: "mcp.example.com")
      XCTFail("Disconnected ingress must not accept requests")
    } catch is URLError {}
    let (local, auth) = try await setup(runtime)
    let available = try await response(local, authorization: auth)
    XCTAssertEqual(available.statusCode, 200)
    try await connections.connect(TestConnectionProvider())
    let reconnected = await connections.snapshot()
    XCTAssertEqual(reconnected.state, .ready)
  }

  func testNewRuntimeRotatesLocalCredential() async throws {
    let (_, first) = try makeRuntime()
    try await first.start()
    let (_, firstAuthorization) = try await setup(first)
    await first.stop()
    let (_, second) = try makeRuntime()
    try await second.start()
    let (_, secondAuthorization) = try await setup(second)
    XCTAssertFalse(firstAuthorization == secondAuthorization)
  }

  func testClipboardCleanupNeverDeletesAnotherApplicationsCopy() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("LutiTests." + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    let clipboard = ConnectionClipboard(pasteboard: pasteboard)
    XCTAssertTrue(clipboard.copy("test-only-configuration"))
    clipboard.clearIfOwned()
    XCTAssertNil(pasteboard.string(forType: .string))
    XCTAssertTrue(clipboard.copy("test-only-configuration"))
    pasteboard.clearContents()
    pasteboard.setString("user-copy", forType: .string)
    clipboard.clearIfOwned()
    XCTAssertEqual(pasteboard.string(forType: .string), "user-copy")
  }
}
