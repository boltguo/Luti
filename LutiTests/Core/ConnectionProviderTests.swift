import AppKit
import Foundation
import XCTest

@testable import Luti

/// No cloud process, account or public network is used by this suite.
private actor FixtureProvider: ConnectionProvider {
  nonisolated let id: ConnectionProviderID
  nonisolated let privateCredential = "lt_" + Budget.token()
  private let stateAfterStart: ConnectionState
  private var state = ConnectionSnapshot.stopped
  private(set) var endpoint: URL?
  private(set) var starts = 0
  private(set) var stops = 0

  init(stateAfterStart: ConnectionState = .ready, id: ConnectionProviderID = .openAI) {
    self.id = id
    self.stateAfterStart = stateAfterStart
  }
  func start(endpoint: URL) async throws {
    starts += 1
    self.endpoint = endpoint
    state = ConnectionSnapshot(state: stateAfterStart)
  }
  func snapshot() -> ConnectionSnapshot { state }
  func stop() { stops += 1; state = .stopped }
}

@MainActor final class ConnectionProviderTests: XCTestCase {
  func testRemoteProjectSelectionUpdatesAppAndPersistenceWithoutReconnecting() async throws {
    let first = try Fixture(), second = try Fixture()
    let provider = FixtureProvider()
    let key = "sk-" + String(repeating: "a", count: 40)
    let store = FixtureKeychain(values: [KeychainService.openAIAPIKey: key])
    first.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    let model = AppModel(contextDataRoot: first.contextDataRoot, defaults: first.defaults,
      credentials: store.client, makeProvider: { _, _, _ in provider })
    addTeardownBlock { await model.stop(); first.remove(); second.remove() }
    model.addProject(first.root)
    let a = try XCTUnwrap(model.activeProject)
    model.addProject(second.root)
    let b = try XCTUnwrap(model.activeProject)
    model.selectProject(a.id)
    model.requestStart()
    for _ in 0..<300 {
      if model.connection.state == .ready { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(model.connection.state, .ready)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    let runID = model.currentRunID
    let (_, before) = try await rpc(endpoint, bearer: "Bearer " + provider.privateCredential,
      method: "tools/call", params: ["name": "project_info", "arguments": [:]])
    let info = before["result"]["structuredContent"]
    XCTAssertEqual(info["projects"].array?.count, 2)
    let (status, result) = try await rpc(endpoint, bearer: "Bearer " + provider.privateCredential,
      method: "tools/call", params: ["name": "project_select", "arguments": [
        "projectId": .string(b.id), "projectToken": info["projectToken"]]])
    XCTAssertEqual(status, 200)
    XCTAssertEqual(result["result"]["isError"], false, result.text())
    XCTAssertEqual(result["result"]["structuredContent"]["root"], .string(second.root.path))
    await model.refresh()
    XCTAssertEqual(model.activeProject, b)
    XCTAssertEqual(model.currentRunID, runID)
    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.connection.state, .ready)
    let starts = await provider.starts, stops = await provider.stops
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(stops, 0)
    let (_, after) = try await rpc(endpoint, bearer: "Bearer " + provider.privateCredential,
      method: "tools/call", params: ["name": "project_info", "arguments": [:]])
    XCTAssertEqual(after["result"]["structuredContent"]["projectId"], .string(b.id))
    await model.stop()
    let reopened = AppModel(contextDataRoot: first.contextDataRoot, defaults: first.defaults, credentials: store.client)
    XCTAssertEqual(reopened.activeProject, b)
    XCTAssertEqual(reopened.approvedProjects, [a, b])
  }

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

  func testProviderCatalogKeepsOnlySupportedTransports() {
    XCTAssertEqual(ConnectionProviderID.allCases, [.openAI, .cloudflare, .vps])
    for removed in ["ngrok", "quick", "custom"] {
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
    XCTAssertFalse(model.openAIEnabled, "Fresh install without saved tunnelID starts with OpenAI switch off.")
    model.apiKeySaved = false
    XCTAssertFalse(model.connectionConfigured)
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    model.tunnelID = "tunnel_0123456789abcdef0123456789abcdef"
    XCTAssertFalse(model.connectionConfigured)
    model.apiKeySaved = true
    XCTAssertTrue(model.connectionConfigured)
    model.phase = .running
    XCTAssertFalse(model.canConnect, "Disabled OpenAI switch must not connect even when configured.")
    model.openAIEnabled = true
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

  func testOpenAIEnabledMigratesSavedTunnelFromV120AndRespectsExplicitToggle() throws {
    let f = try Fixture(); defer { f.remove() }
    // 1. Fresh install: no saved tunnelID -> openAIEnabled is false.
    let fresh = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertFalse(fresh.openAIEnabled)

    // 2. Upgrade from v1.2.0: saved tunnelID exists, but connection.openai.enabled was never set -> openAIEnabled is true.
    f.defaults.removeObject(forKey: "connection.openai.enabled")
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.tunnelID")
    let upgraded = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertTrue(upgraded.openAIEnabled)

    // 3. Explicit user toggle off persists across launches even when tunnelID is saved.
    upgraded.openAIEnabled = false
    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertFalse(reopened.openAIEnabled)
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
  private func vpsPublicKey(_ f: Fixture) throws -> String {
    let key = try VPSIdentity.prepare(in: f.contextDataRoot)
    return try VPSConfiguration.publicKey(String(decoding: PrivateFiles.read(key.appendingPathExtension("pub"), max: 2048), as: UTF8.self))
  }

  func testVPSConfigurationRejectsOptionsURLsAndMalformedHostKeys() throws {
    let f = try Fixture(); defer { f.remove() }
    let key = try vpsPublicKey(f)
    for host in ["203.0.113.10", "vps.example.com", "2001:db8::1"] {
      XCTAssertNoThrow(try VPSConfiguration(host: host, port: "22", hostKey: key))
    }
    for host in ["-oProxyCommand=sh", "user@vps.example.com", "https://vps.example.com", "host\ncommand", "256.999.1.1", "host;touch /tmp/example"] {
      XCTAssertThrowsError(try VPSConfiguration(host: host, port: "22", hostKey: key), host)
    }
    for port in ["0", "65536", "22 -oOption=value"] {
      XCTAssertThrowsError(try VPSConfiguration(host: "203.0.113.10", port: port, hostKey: key))
    }
    for key in ["", "ssh-ed25519 AAAA", "ssh-rsa " + key.split(separator: " ")[1]] {
      XCTAssertThrowsError(try VPSConfiguration(host: "203.0.113.10", port: "22", hostKey: key))
    }
  }

  func testVPSIdentityIsPreservedAndSetupScriptParses() throws {
    let f = try Fixture(); defer { f.remove() }
    let identity = try VPSIdentity.prepare(in: f.contextDataRoot)
    let before = Budget.sha256(try PrivateFiles.read(identity, max: 8192))
    let script = try VPSIdentity.setupScript(origin: URL(string: "https://mcp.example.com")!, root: f.contextDataRoot)
    XCTAssertEqual(before, Budget.sha256(try PrivateFiles.read(identity, max: 8192)))
    let permissions = try FileManager.default.attributesOfItem(atPath: identity.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    XCTAssertFalse(script.contains("__LUTI_"))
    XCTAssertFalse(script.contains("BEGIN OPENSSH PRIVATE KEY"))
    try f.write("setup.sh", script)
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/bin/bash")
    check.arguments = ["-n", f.root.appendingPathComponent("setup.sh").path]
    try check.run(); check.waitUntilExit()
    XCTAssertEqual(check.terminationStatus, 0)
    XCTAssertThrowsError(try VPSIdentity.setupScript(origin: URL(string: "https://mcp.example.com/path")!, root: f.contextDataRoot))
  }

  func testVPSSSHConfigurationPinsHostKeyAndUsesRestrictedReverseForward() throws {
    let f = try Fixture(); defer { f.remove() }
    let configuration = try VPSConfiguration(host: "203.0.113.10", port: "2222", hostKey: vpsPublicKey(f))
    XCTAssertTrue(configuration.knownHost.hasPrefix("[203.0.113.10]:2222 ssh-ed25519 "))
    let args = VPSTunnelProvider.arguments(configuration: configuration,
      identity: VPSIdentity.key(in: f.contextDataRoot), knownHosts: f.root.appendingPathComponent("known_hosts"),
      control: f.root.appendingPathComponent("ssh.sock"), localPort: 39394)
    let check = Process(), output = Pipe()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    check.arguments = ["-G"] + args
    check.standardOutput = output
    check.standardError = FileHandle.nullDevice
    try check.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    check.waitUntilExit()
    XCTAssertEqual(check.terminationStatus, 0)
    let parsed = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(parsed.contains("user luti\n"))
    XCTAssertTrue(parsed.contains("batchmode yes\n"))
    XCTAssertTrue(parsed.contains("stricthostkeychecking true\n"))
    XCTAssertTrue(parsed.contains("exitonforwardfailure yes\n"))
    XCTAssertTrue(parsed.contains("identityagent none\n"))
    XCTAssertTrue(parsed.contains("remoteforward [127.0.0.1]:39393 [127.0.0.1]:39394"))
    XCTAssertTrue(parsed.contains("userknownhostsfile " + f.root.appendingPathComponent("known_hosts").path))
  }

  func testVPSSetupSSHDRestrictionsApplyOnlyToTunnelUser() throws {
    let f = try Fixture(); defer { f.remove() }
    let script = try VPSIdentity.setupScript(origin: URL(string: "https://mcp.example.com")!, root: f.contextDataRoot)
    let block = try XCTUnwrap(script.components(separatedBy: "<<LUTI_SSH\n").dropFirst().first)
      .components(separatedBy: "\nLUTI_SSH")[0]
      .replacingOccurrences(of: "$remote_port", with: String(VPSConfiguration.remotePort))
    try f.write("tunnel.conf", block)
    try f.write("sshd_config", "Include \(f.root.path)/tunnel.conf\nHostKey \(VPSIdentity.key(in: f.contextDataRoot).path)\nPidFile \(f.root.path)/sshd.pid\n")
    for user in ["luti", "other-user"] {
      let check = Process(), output = Pipe()
      check.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
      check.arguments = ["-T", "-f", f.root.appendingPathComponent("sshd_config").path,
        "-C", "user=\(user),addr=127.0.0.1,host=localhost"]
      check.standardOutput = output
      check.standardError = FileHandle.nullDevice
      try check.run()
      let parsed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
      check.waitUntilExit()
      XCTAssertEqual(check.terminationStatus, 0)
      if user == "luti" {
        XCTAssertTrue(parsed.contains("allowtcpforwarding remote\n"))
        XCTAssertTrue(parsed.contains("permitlisten 127.0.0.1:39393\n"))
        XCTAssertTrue(parsed.contains("maxsessions 0\n"))
        XCTAssertTrue(parsed.contains("passwordauthentication no\n"))
        XCTAssertTrue(parsed.contains("authenticationmethods publickey\n"))
      } else {
        XCTAssertTrue(parsed.contains("allowtcpforwarding yes\n"))
        XCTAssertTrue(parsed.contains("maxsessions 10\n"))
      }
    }
  }

  func testVPSPublicListenerRequiresOAuthAndSupportsDiscovery() async throws {
    let (_, runtime, manager) = try fixture()
    try await runtime.start()
    let origin = URL(string: "https://vps.example.com")!
    let oauth = try OAuthService(origin: origin, transport: .vps)
    let provider = FixtureProvider(id: .vps)
    do { try await manager.connect(provider); XCTFail("Public VPS ingress must require OAuth.") }
    catch { XCTAssertEqual((error as? Failure)?.code, "invalid_arguments") }
    try await manager.connect(provider, oauth: oauth)
    let captured = await provider.endpoint
    let endpoint = try XCTUnwrap(captured)
    let missing = try await rpc(endpoint)
    XCTAssertEqual(missing.0, 401)
    let metadata = try await ConnectionProbe.request(endpoint.deletingLastPathComponent()
      .appendingPathComponent(".well-known/oauth-protected-resource/mcp"))
    XCTAssertEqual(metadata.status, 200)
    XCTAssertEqual(metadata.json["resource"].string, origin.absoluteString + "/mcp")
    XCTAssertEqual(PublicConnectionContract.port(for: .vps), PublicConnectionContract.port(for: .cloudflare) + 1)
  }

  func testVPSSettingsAndRuntimeDoNotRequireCloudflareCredentials() async throws {
    let f = try Fixture()
    let store = FixtureKeychain()
    let provider = FixtureProvider(id: .vps)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client,
      makeVPSProvider: { _, _, _, _ in provider })
    addTeardownBlock { await model.stop(); f.remove() }
    model.addProject(f.root)
    model.vps.domain = "https://vps.example.com"
    model.vps.vpsHost = "203.0.113.10"
    model.vps.vpsHostKey = try vpsPublicKey(f)
    await model.vps.save()
    XCTAssertNil(model.vps.error)
    XCTAssertTrue(model.vps.configured)
    XCTAssertTrue(model.canLaunch)
    XCTAssertFalse(model.cloudflare.configured)
    model.requestStart()
    for _ in 0..<150 {
      if model.vps.connection.state == .ready { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.phase, .running)
    XCTAssertEqual(model.vps.connection.state, .ready)
    XCTAssertEqual(model.reachableConnection.providerID, .vps)
    XCTAssertTrue(store.readInteractions.isEmpty)
    await model.stop()
    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
    addTeardownBlock { await reopened.stop() }
    XCTAssertTrue(reopened.vps.configured)
    XCTAssertEqual(reopened.vps.vpsHost, "203.0.113.10")
    XCTAssertFalse(reopened.cloudflare.enabled)
  }

  func testInvalidVPSSettingsLeaveCloudflareConfigurationIntact() async throws {
    let f = try Fixture()
    let store = FixtureKeychain()
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
    addTeardownBlock { await model.stop(); f.remove() }
    model.cloudflare.domain = "https://cf.example.com"
    model.cloudflare.tokenDraft = String(repeating: "t", count: 80)
    await model.cloudflare.save()
    model.vps.domain = "https://vps.example.com"
    model.vps.vpsHost = "203.0.113.10"
    model.vps.vpsHostKey = "invalid"
    await model.vps.save()
    XCTAssertNotNil(model.vps.error)
    XCTAssertEqual(model.vps.savedDomain, "")
    XCTAssertEqual(model.cloudflare.savedDomain, "https://cf.example.com")
    XCTAssertTrue(model.cloudflare.configured)
    XCTAssertNotNil(store.value(CloudflareContract.tokenAccount))
  }

  func testCloudflareAndVPSRunIndependentlyAndStopTogether() async throws {
    let f = try Fixture()
    let cf = FixtureProvider(id: .cloudflare), vps = FixtureProvider(id: .vps)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: FixtureKeychain().client,
      makeCloudflareProvider: { _, _ in cf }, makeVPSProvider: { _, _, _, _ in vps })
    addTeardownBlock { await model.stop(); f.remove() }
    model.addProject(f.root)
    model.cloudflare.domain = "https://cf.example.com"
    model.cloudflare.tokenDraft = String(repeating: "t", count: 80)
    await model.cloudflare.save()
    model.vps.domain = "https://vps.example.com"
    model.vps.vpsHost = "203.0.113.10"
    model.vps.vpsHostKey = try vpsPublicKey(f)
    await model.vps.save()
    model.requestStart()
    for _ in 0..<150 {
      if model.publicConnections.allSatisfy({ $0.connection.state == .ready }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.cloudflare.connection.state, .ready)
    XCTAssertEqual(model.vps.connection.state, .ready)
    let cfEndpoint = await cf.endpoint, vpsEndpoint = await vps.endpoint
    XCTAssertNotEqual(cfEndpoint?.port, vpsEndpoint?.port)
    for endpoint in [try XCTUnwrap(cfEndpoint), try XCTUnwrap(vpsEndpoint)] {
      let response = try await rpc(endpoint)
      XCTAssertEqual(response.0, 401)
    }
    await model.stop()
    XCTAssertTrue(model.publicConnections.allSatisfy { $0.connection.state == .stopped })
    model.vps.enabled = false
    XCTAssertTrue(model.cloudflare.enabled)
  }

  /// Exercise the real child-process lifecycle without downloading a connector or using the network.
  private func cloudflareFixture(
    startupTimeout: Duration = .milliseconds(900), exits: Bool = false, metrics: Bool = true,
    probe: @escaping @Sendable (URL) async -> Bool
  ) throws -> (Fixture, CloudflareTunnelProvider) {
    let f = try Fixture()
    let binary = f.root.appendingPathComponent("cloudflared-fixture")
    try f.write("cloudflared-fixture", """
      #!/bin/sh
      transport=
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--protocol" ]; then
          shift
          transport="$1"
        fi
        shift
      done
      [ -n "$TUNNEL_TOKEN" ] || exit 42
      printf '%s\\n' "$transport" >> '\(f.root.path)/launches'
      \(exits ? "exit 1" : "")
      port=49151
      if [ "$transport" = "http2" ]; then port=49152; fi
      \(metrics ? "printf 'Starting metrics server on 127.0.0.1:%s/metrics\\n' \"$port\"" : "")
      exec /bin/sleep 60
      """)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    let provider = try CloudflareTunnelProvider(
      token: String(repeating: "t", count: 80), helper: Fixture.helper,
      startupTimeout: startupTimeout, prepareBinary: { binary }, probe: probe)
    addTeardownBlock { await provider.stop(); f.remove() }
    return (f, provider)
  }

  private func cloudflareLaunches(_ f: Fixture) -> [String] {
    let output = (try? String(contentsOf: f.root.appendingPathComponent("launches"), encoding: .utf8)) ?? ""
    return output.split(separator: "\n").map(String.init)
  }

  private var cloudflareEndpoint: URL {
    URL(string: "http://127.0.0.1:\(CloudflareContract.port)/mcp")!
  }

  func testCloudflareKeepsAutoWhenInitiallyReady() async throws {
    let (f, provider) = try cloudflareFixture { $0.port == 49151 }
    try await provider.start(endpoint: cloudflareEndpoint)
    let snapshot = await provider.snapshot()
    XCTAssertEqual(snapshot.state, .ready)
    XCTAssertEqual(cloudflareLaunches(f), ["auto"])
  }

  func testCloudflareStartupTimeoutFallsBackToHTTP2() async throws {
    let (f, provider) = try cloudflareFixture { $0.port == 49152 }
    try await provider.start(endpoint: cloudflareEndpoint)
    let snapshot = await provider.snapshot()
    XCTAssertEqual(snapshot.state, .ready)
    XCTAssertEqual(cloudflareLaunches(f), ["auto", "http2"])
  }

  func testCloudflareKeepsLiveHTTP2AfterBothStartupDeadlinesAndRecovers() async throws {
    let readiness = CloudflareFixtureReadiness()
    let (f, provider) = try cloudflareFixture { await readiness.probe($0) }
    try await provider.start(endpoint: cloudflareEndpoint)
    let pending = await provider.snapshot()
    XCTAssertEqual(pending.state, .reconnecting)
    XCTAssertEqual(cloudflareLaunches(f), ["auto", "http2"])

    await readiness.setReady()
    // Let the existing five-second probe cache expire, well past both fixture startup deadlines.
    try await Task.sleep(for: .milliseconds(5100))
    let recovered = await provider.snapshot()
    XCTAssertEqual(recovered.state, .ready)
    XCTAssertEqual(cloudflareLaunches(f), ["auto", "http2"], "Network recovery must reuse the HTTP/2 child.")
    await provider.stop()
    let stopped = await provider.snapshot()
    XCTAssertEqual(stopped.state, .stopped)
  }

  func testCloudflareStopAndCancellationCannotLaunchFallback() async throws {
    for cancel in [false, true] {
      let (f, provider) = try cloudflareFixture(startupTimeout: .seconds(5)) { _ in false }
      let endpoint = cloudflareEndpoint
      let start = Task { try await provider.start(endpoint: endpoint) }
      for _ in 0..<100 {
        if !cloudflareLaunches(f).isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(cloudflareLaunches(f), ["auto"])
      if cancel { start.cancel() } else { await provider.stop() }
      do { try await start.value; XCTFail("Stopped startup must not complete.") }
      catch { XCTAssertTrue(error is CancellationError) }
      let snapshot = await provider.snapshot()
      XCTAssertEqual(snapshot.state, .stopped)
      XCTAssertEqual(cloudflareLaunches(f), ["auto"])
    }
  }

  func testCloudflareExitedChildDoesNotTriggerProtocolFallback() async throws {
    let (f, provider) = try cloudflareFixture(exits: true) { _ in false }
    do { try await provider.start(endpoint: cloudflareEndpoint); XCTFail("Exited child must fail startup.") }
    catch { XCTAssertEqual((error as? Failure)?.code, "cloudflare_unavailable") }
    XCTAssertEqual(cloudflareLaunches(f), ["auto"])
  }

  func testCloudflareMissingMetricsDoesNotTriggerProtocolFallback() async throws {
    let (f, provider) = try cloudflareFixture(metrics: false) { _ in false }
    do { try await provider.start(endpoint: cloudflareEndpoint); XCTFail("Missing metrics must fail startup.") }
    catch { XCTAssertEqual((error as? Failure)?.code, "cloudflare_unavailable") }
    XCTAssertEqual(cloudflareLaunches(f), ["auto"])
  }

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

private actor CloudflareFixtureReadiness {
  private var ready = false
  func setReady() { ready = true }
  func probe(_ url: URL) -> Bool { ready && url.port == 49152 }
}
