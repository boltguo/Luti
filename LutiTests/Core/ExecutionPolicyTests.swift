import XCTest
import Darwin

@testable import Luti

@MainActor final class ExecutionPolicyTests: XCTestCase {

  func testDeveloperPATHPrefersLoginShellAndKeepsFixedDirectories() {
    let fixed = ProcessPolicy.fixedPATH
    XCTAssertEqual(ProcessPolicy.mergePATH(nil, fixed: fixed), fixed)
    XCTAssertEqual(
      ProcessPolicy.mergePATH("/Users/u/.nvm/versions/node/v22/bin:relative:/usr/bin:/Users/u/.cargo/bin:/Users/u/.cargo/bin", fixed: fixed),
      "/Users/u/.nvm/versions/node/v22/bin:/Users/u/.cargo/bin:" + fixed)
    XCTAssertTrue(ProcessPolicy.baseEnvironment["PATH"]!.hasSuffix(fixed))
  }

  func testReadOnlyPolicyAllowsProjectReadsButBlocksMutationAndExecution() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "hello")
    let router = try f.router()
    addTeardownBlock { await router.stop() }

    let read = await router.callInCurrentProject("read_files", arguments: ["paths": ["source.txt"]])
    XCTAssertFalse(read.isError)
    XCTAssertEqual(read.data["files"].array?.first?["content"], "hello")

    let create = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "new.txt", "content": "blocked"])
    XCTAssertTrue(create.isError)
    XCTAssertEqual(create.data["error"], "execution_policy_denied")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))

    let directory = await router.callInCurrentProject(
      "path_action", arguments: ["action": "createDirectory", "path": "blocked"])
    XCTAssertTrue(directory.isError)
    XCTAssertEqual(directory.data["error"], "execution_policy_denied")

    let process = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertTrue(process.isError)
    XCTAssertEqual(process.data["error"], "execution_policy_denied")

    let code = await router.callInCurrentProject(
      "code_query", arguments: ["action": "documentSymbols", "path": "source.txt"])
    XCTAssertTrue(code.isError)
    XCTAssertEqual(code.data["error"], "execution_policy_denied")

    let browser = await router.callInCurrentProject(
      "browser_session", arguments: ["action": "open", "url": "https://example.com"])
    XCTAssertTrue(browser.isError)
    XCTAssertEqual(browser.data["error"], "execution_policy_denied")


  }

  func testExecutionCannotBeEnabledByToolArguments() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try ToolRouter(
      workspace: f.files, jobs: JobManager(helper: Fixture.helper),
      activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: false), contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let process = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertEqual(process.data["error"], "local_consent_required")

    let write = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "new.txt", "content": "blocked"])
    XCTAssertEqual(write.data["error"], "local_consent_required")
  }

  func testApprovedFullLocalPreservesCurrentRuntimeBehavior() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let create = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "created.txt", "content": "ok"])
    XCTAssertFalse(create.isError)

    let process = await router.callInCurrentProject(
      "run_process",
      arguments: ["program": "/usr/bin/true", "syncWait": 3, "timeout": 10])
    XCTAssertFalse(process.isError)
    XCTAssertEqual(process.data["exitCode"], 0)

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["profile"], "fullLocal")
    XCTAssertEqual(status.data["executionPolicy"]["localApproval"], true)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], .null)
    XCTAssertEqual(status.data["capabilities"]["projectWrite"], true)
    XCTAssertEqual(status.data["capabilities"]["commandExecution"], true)
    XCTAssertEqual(status.data["capabilities"]["rawShell"], true)
  }

  func testReadOnlyRuntimeStatusDoesNotClaimSandboxOrExecution() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["profile"], "readOnly")
    XCTAssertEqual(status.data["executionPolicy"]["workspace"]["read"], true)
    XCTAssertEqual(status.data["executionPolicy"]["workspace"]["write"], false)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], .null)
    XCTAssertEqual(status.data["executionEnabled"], false)
    XCTAssertEqual(status.data["capabilities"]["commandExecution"], false)
  }

  func testProcessScopeAllowsProjectPathsButRejectsExternalAndSymlinkPaths() throws {
    let f = try Fixture(); defer { f.remove() }
    let inside = f.root.appendingPathComponent("build/output.txt").path
    for path in ["src/main.swift", inside] {
      XCTAssertNoThrow(try ProcessPolicy.validateProjectScope(
        ProcessRequest(program: "/bin/echo", args: [path], cwd: f.root, projectRoot: f.root)))
    }
    let outside = f.root.deletingLastPathComponent().appendingPathComponent("outside.txt").path
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("escape"), withDestinationURL: f.root.deletingLastPathComponent())
    for path in [outside, "escape/new.txt"] {
      XCTAssertThrowsError(try ProcessPolicy.validateProjectScope(
        ProcessRequest(program: "/usr/bin/touch", args: [path], cwd: f.root, projectRoot: f.root))) {
        XCTAssertEqual(($0 as? Failure)?.code, "project_scope_denied")
      }
    }
  }

  func testFullAccessRejectsExternalProcessPathsBeforeExecution() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let target = f.root.deletingLastPathComponent().appendingPathComponent("luti-denied-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: target) }
    let result = await router.callInCurrentProject("run_process", arguments: [
      "program": "/usr/bin/touch", "args": .array([.string(target.path)]), "syncWait": 3,
    ])
    XCTAssertEqual(result.data["error"], "project_scope_denied")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let jobs = await router.jobList()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testFullAccessRejectsExternalFileReadsAndWrites() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let read = await router.callInCurrentProject("read_files", arguments: ["paths": ["../outside.txt"]])
    XCTAssertEqual(read.data["files"].array?.first?["failure"]["error"], "path_outside_workspace")
    let write = await router.callInCurrentProject("edit_files", arguments: [
      "action": "create", "path": "../outside.txt", "content": "blocked",
    ])
    XCTAssertEqual(write.data["error"], "path_outside_workspace")
  }

  func testDiscoveredNodeTaskRetainsProjectScopeAndRunsWithoutOperationPrompt() async throws {
    let outside = try Fixture(), inside = try Fixture(); defer { outside.remove(); inside.remove() }
    try outside.write("package.json", #"{"scripts":{"test":"rm ../must-not-be-removed"}}"#)
    let deniedRouter = try outside.router(execution: true)
    addTeardownBlock { await deniedRouter.stop() }
    let denied = await deniedRouter.callInCurrentProject("run_process", arguments: ["taskId": "task:test", "syncWait": 3])
    XCTAssertEqual(denied.data["error"], "project_scope_denied")
    try inside.write("generated.txt", "remove me")
    try inside.write("package.json", #"{"scripts":{"test":"rm generated.txt"}}"#)
    let allowedRouter = try inside.router(execution: true)
    addTeardownBlock { await allowedRouter.stop() }
    let allowed = await allowedRouter.callInCurrentProject("run_process", arguments: ["taskId": "task:test", "syncWait": 3])
    XCTAssertFalse(allowed.isError)
    XCTAssertEqual(allowed.data["exitCode"], 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: inside.root.appendingPathComponent("generated.txt").path))
  }

  func testFullAccessRetainsMachineLevelCommandDeny() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let denied = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/sudo", "args": ["-V"]])
    XCTAssertEqual(denied.data["error"], "dangerous_command_denied")
    let jobs = await router.jobList()
    XCTAssertTrue(jobs.isEmpty)
  }

  func testUnsupportedDiagnosticsNeverStartsProjectLanguageServer() async throws {
    let f = try Fixture(); defer { f.remove() }
    let serverPath = "node_modules/.bin/typescript-language-server"
    try f.write(serverPath, "#!/bin/sh\n: > language-server-started\nexit 0\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: f.root.appendingPathComponent(serverPath).path)
    try f.write("source.ts", "export const value = 1\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let result = await router.callInCurrentProject(
      "code_query", arguments: ["action": "diagnostics", "path": "source.ts"])

    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "language_service_action_unavailable")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("language-server-started").path))
    let events = await router.activity.snapshot()
    XCTAssertEqual(events.last?.effect, "none")
  }

  private func installBlockedLanguageServer(_ fixture: Fixture) throws {
    let path = "node_modules/.bin/typescript-language-server"
    // A functioning initialize handshake followed by a full stdin pipe. Both
    // provider and descendant ignore TERM to exercise supervisor escalation.
    try fixture.write(path, #"""
    #!/usr/bin/python3
    import json, os, pathlib, signal, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    request = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    child = os.fork()
    if child == 0:
        while True:
            time.sleep(1)
    response = json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"capabilities":{}}}).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(response)).encode() + b"\r\n\r\n" + response)
    sys.stdout.buffer.flush()
    pathlib.Path("language-server-ready").write_text(str(os.getpid()) + " " + str(child))
    while True:
        time.sleep(1)
    """#)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: fixture.root.appendingPathComponent(path).path)
    try fixture.write("source.ts", String(repeating: "x", count: 600_000))
  }

  private func languageServerPIDs(_ fixture: Fixture) async throws -> [pid_t] {
    let marker = fixture.root.appendingPathComponent("language-server-ready")
    // The first Python launch on a fresh CI runner can take longer than three seconds.
    for _ in 0..<500 {
      if let text = try? String(contentsOf: marker, encoding: .utf8) {
        let pids = text.split(separator: " ").compactMap { Int32($0) }
        if pids.count == 2 { return pids }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Language server did not finish its initialize handshake.")
    return []
  }

  private func assertLanguageServerStopped(_ pids: [pid_t]) async throws {
    // A descendant may briefly remain a zombie until launchd reaps it.
    for _ in 0..<100 {
      if pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    for pid in pids {
      XCTAssertEqual(kill(pid, 0), -1, "Language-service process \(pid) survived cleanup.")
      if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    }
  }

  func testLanguageServiceTimeoutBoundsBlockedInputAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper, timeout: 1.5)
    addTeardownBlock { await service.stop() }
    let started = Date()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("The provider never reads didOpen and must time out.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "language_service_timeout")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let pids = try await languageServerPIDs(f)
    try await assertLanguageServerStopped(pids)
  }

  func testLanguageServiceTimeoutBoundsUnansweredResponseAndStopRejectsNewQueries() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    // Small didOpen fits in the pipe, so this exercises receive(), not blocked send().
    try f.write("source.ts", "export const value = 1;")
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper, timeout: 1.5)
    addTeardownBlock { await service.stop() }
    let started = Date()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("The provider never answers documentSymbol and must time out.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "language_service_timeout")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let pids = try await languageServerPIDs(f)
    try await assertLanguageServerStopped(pids)
    await service.stop()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("A stopped service must not start a new provider.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "runtime_stopped")
    }
  }

  func testRuntimeStopInterruptsBlockedLanguageServiceAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let query = Task {
      await router.callInCurrentProject("code_query", arguments: ["action": "documentSymbols", "path": "source.ts"])
    }
    let pids = try await languageServerPIDs(f)
    let started = Date()
    await router.stop()
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    let result = await query.value
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "runtime_stopped")
    try await assertLanguageServerStopped(pids)
  }

  func testCancellationInterruptsBlockedLanguageServiceAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper)
    addTeardownBlock { await service.stop() }
    let query = Task { try await service.query(path: "source.ts", action: "documentSymbols") }
    let pids = try await languageServerPIDs(f)
    let started = Date()
    query.cancel()
    do {
      _ = try await query.value
      XCTFail("Cancelled language-service calls must stop.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "runtime_stopped")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    try await assertLanguageServerStopped(pids)
  }
}
