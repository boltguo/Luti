import XCTest

@testable import Luti

@MainActor final class ProcessTests: XCTestCase {
  func testRealStdoutStderrExitCode() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh", args: ["-c", "printf out; printf err >&2; exit 7"], cwd: f.root,
        syncWait: 3))
    XCTAssertEqual(result["status"].string, "failed")
    XCTAssertEqual(result["exitCode"].int, 7)
    XCTAssertEqual(result["stdoutTail"].string, "out")
    XCTAssertEqual(result["stderrTail"].string, "err")
    XCTAssertEqual(result["testSummary"], .null)
    await jobs.shutdown()
  }

  func testTerminalTestOutputAddsStructuredSummaryWithoutReplacingLogs() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let output = """
    Test Suite 'All tests' passed.
    Executed 12 tests, with 0 failures (0 unexpected) in 1.23 seconds
    """
    let result = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh",
        args: ["-c", "printf '%s\\n' \"$1\"", "sh", output],
        cwd: f.root, syncWait: 3))
    XCTAssertEqual(result["status"], "completed")
    XCTAssertEqual(result["testSummary"]["framework"], "xctest")
    XCTAssertEqual(result["testSummary"]["status"], "passed")
    XCTAssertEqual(result["testSummary"]["total"], 12)
    XCTAssertEqual(result["testSummary"]["passed"], 12)
    XCTAssertEqual(result["testSummary"]["failed"], 0)
    XCTAssertTrue(result["stdoutTail"].string?.contains("Executed 12 tests") == true)
    XCTAssertEqual(result["exitCode"], 0)
    await jobs.shutdown()
  }

  func testDiagnosticParserNormalizesKnownFormatsAndRejectsOutsidePaths() throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/app.ts", "const value: number = 'x'")
    try f.write("src/app.py", "value: int = 'x'")
    try f.write("src/App.swift", "let value: Int = \"x\"")

    let stdout = """
    src/app.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.
    src/app.py:5:9 - warning: Type mismatch (reportAssignmentType)
    src/App.swift:2:4: error: cannot convert value of type 'String' to specified type 'Int'
    /tmp/outside.ts(1,1): error TS9999: Outside project
    .env(1,1): error TS0001: Protected
    """
    let eslint = """
    \(f.root.appendingPathComponent("src/app.ts").path)
      4:11  warning  Unexpected any  @typescript-eslint/no-explicit-any
    """
    let report = try XCTUnwrap(
      DiagnosticOutputParser.parse(
        command: "eslint . && tsc --noEmit && pyright",
        cwd: f.root,
        projectRoot: f.root,
        stdout: stdout + "\n" + eslint,
        stderr: "",
        inputTruncated: false))
    let rows = report["diagnostics"].array ?? []
    XCTAssertEqual(rows.count, 4)
    XCTAssertTrue(rows.contains {
      $0["file"] == "src/app.ts" && $0["code"] == "TS2322"
        && $0["severity"] == "error" && $0["source"] == "tsc"
    })
    XCTAssertTrue(rows.contains {
      $0["file"] == "src/app.py" && $0["code"] == "reportAssignmentType"
        && $0["severity"] == "warning"
    })
    XCTAssertTrue(rows.contains {
      $0["file"] == "src/App.swift" && $0["source"] == "swift"
    })
    XCTAssertTrue(rows.contains {
      $0["file"] == "src/app.ts"
        && $0["code"] == "@typescript-eslint/no-explicit-any"
        && $0["source"] == "eslint"
    })
    XCTAssertFalse(rows.contains { $0["file"].string?.contains("outside") == true })
    XCTAssertFalse(rows.contains { $0["file"] == ".env" })
    XCTAssertEqual(report["diagnosticSummary"]["count"], 4)
    XCTAssertEqual(report["diagnosticSummary"]["errors"], 2)
    XCTAssertEqual(report["diagnosticSummary"]["warnings"], 2)
    XCTAssertEqual(report["diagnosticSummary"]["inputTruncated"], false)
  }

  func testTerminalJobAddsBoundedStructuredDiagnostics() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/app.ts", "const value = 1")
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh",
        args: [
          "-c",
          "printf '%s\\n' 'src/app.ts(8,12): error TS2345: Argument mismatch' >&2; exit 1",
        ],
        cwd: f.root,
        projectRoot: f.root,
        syncWait: 3))
    XCTAssertEqual(result["status"], "failed")
    XCTAssertEqual(result["diagnosticSummary"]["count"], 1)
    let diagnostic = try XCTUnwrap(result["diagnostics"].array?.first)
    XCTAssertEqual(diagnostic["file"], "src/app.ts")
    XCTAssertEqual(diagnostic["line"], 8)
    XCTAssertEqual(diagnostic["column"], 12)
    XCTAssertEqual(diagnostic["code"], "TS2345")
    XCTAssertEqual(diagnostic["source"], "tsc")
    XCTAssertTrue(result["stderrTail"].string?.contains("TS2345") == true)
    await jobs.shutdown()
  }

  func testStdin() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(
      ProcessRequest(program: "/bin/cat", cwd: f.root, input: "你好\n", syncWait: 3))
    XCTAssertEqual(result["stdoutTail"].string, "你好\n")
    await jobs.shutdown()
  }
  func testUnifiedJobToolsPreserveQueryAndActionCapabilities() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router(execution: true)

    let started = await router.call(
      "run_process",
      arguments: [
        "program": "/bin/cat", "interactive": true, "syncWait": 0,
      ])
    XCTAssertFalse(started.isError)
    let id = try XCTUnwrap(started.data["jobId"].string)

    let listed = await router.call("job_query", arguments: ["action": "list"])
    XCTAssertFalse(listed.isError)
    XCTAssertTrue(listed.data["jobs"].array?.contains { $0["jobId"] == .string(id) } == true)

    let input = await router.call(
      "job_action",
      arguments: [
        "action": "input", "jobId": .string(id), "text": "hello unified job\n", "close": true,
      ])
    XCTAssertFalse(input.isError)
    XCTAssertEqual(input.data["action"], "input")

    let status = await router.call(
      "job_query",
      arguments: ["action": "status", "jobId": .string(id), "waitMs": 5_000])
    XCTAssertFalse(status.isError)
    XCTAssertEqual(status.data["action"], "status")
    XCTAssertEqual(status.data["terminal"], true)
    XCTAssertEqual(status.data["status"], "completed")

    let logs = await router.call(
      "job_query", arguments: ["action": "logs", "jobId": .string(id)])
    XCTAssertFalse(logs.isError)
    XCTAssertEqual(logs.data["action"], "logs")
    XCTAssertTrue(logs.data["stdoutTail"].string?.contains("hello unified job") == true)
    XCTAssertNotNil(logs.data["nextStdoutOffset"].int)

    let invalidQuery = await router.call(
      "job_query",
      arguments: ["action": "list", "jobId": .string(id)])
    XCTAssertTrue(invalidQuery.isError)

    let invalidAction = await router.call(
      "job_action",
      arguments: ["action": "stop", "jobId": .string(id), "text": "not allowed"])
    XCTAssertTrue(invalidAction.isError)

    await router.stop()
  }

  func testJobObservationActivityFinishesEvenWhenTargetJobIsRunningOrStopping() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    let started = await router.call(
      "run_process",
      arguments: ["program": "/bin/cat", "interactive": true, "syncWait": 0])
    let id = try XCTUnwrap(started.data["jobId"].string)

    let observed = await router.call(
      "job_query", arguments: ["action": "status", "jobId": .string(id)])
    XCTAssertFalse(observed.isError)
    XCTAssertEqual(observed.data["status"], "running")
    var events = await router.activity.snapshot()
    let queryEvent = try XCTUnwrap(events.first { $0.tool == "job_query" })
    XCTAssertEqual(queryEvent.action, "status")
    XCTAssertEqual(queryEvent.status, "ok")
    XCTAssertNil(queryEvent.operationState)
    XCTAssertNotNil(queryEvent.finishedAt)
    XCTAssertTrue(queryEvent.summary.contains("running"))

    let stopped = await router.call(
      "job_action", arguments: ["action": "stop", "jobId": .string(id)])
    XCTAssertFalse(stopped.isError)
    events = await router.activity.snapshot()
    let stopEvent = try XCTUnwrap(events.first { $0.tool == "job_action" })
    XCTAssertEqual(stopEvent.action, "stop")
    XCTAssertNil(stopEvent.operationState)
    XCTAssertNotNil(stopEvent.finishedAt)

    await router.stop()
  }

  func testJobQueryObservesFailedJobWithoutFailingTheQuery() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    let started = await router.call(
      "run_process",
      arguments: [
        "program": "/bin/sh", "args": ["-c", "exit 7"], "syncWait": 3,
      ])
    XCTAssertTrue(started.isError)
    XCTAssertEqual(started.data["localApproval"], .null)
    let id = try XCTUnwrap(started.data["jobId"].string)

    let status = await router.call(
      "job_query", arguments: ["action": "status", "jobId": .string(id)])
    XCTAssertFalse(status.isError)
    XCTAssertEqual(status.data["status"], "failed")
    XCTAssertEqual(status.data["exitCode"], 7)
    XCTAssertNotEqual(status.data["failure"], .null)

    let logs = await router.call(
      "job_query", arguments: ["action": "logs", "jobId": .string(id)])
    XCTAssertFalse(logs.isError)
    XCTAssertEqual(logs.data["status"], "failed")
    XCTAssertNotEqual(logs.data["failure"], .null)

    let events = await router.activity.snapshot()
    let queryEvents = events.filter { $0.tool == "job_query" }
    XCTAssertEqual(queryEvents.count, 2)
    XCTAssertTrue(queryEvents.allSatisfy { $0.status == "ok" && $0.finishedAt != nil })
    XCTAssertTrue(queryEvents.allSatisfy { $0.operationState == nil })
    await router.stop()
  }

  func testTimeout() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    var result = try await jobs.submit(
      ProcessRequest(program: "/bin/sleep", args: ["10"], cwd: f.root, timeout: 1, syncWait: 3))
    for _ in 0..<50 where result["terminal"] != true {
      try await Task.sleep(for: .milliseconds(100))
      result = try await jobs.status(result["jobId"].string!)
    }
    XCTAssertEqual(result["status"].string, "timed_out")
    XCTAssertEqual(result["terminal"], true)
    XCTAssertEqual(result["failure"]["error"].string, "process_timeout")
    await jobs.shutdown()
  }
  func testJobStatusCanWaitForSameJobWithoutPolling() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let running = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh", args: ["-c", "sleep 0.2"], cwd: f.root,
        timeout: 5, syncWait: 0))
    let id = try XCTUnwrap(running["jobId"].string)
    XCTAssertEqual(running["status"], "running")

    let terminal = try await jobs.status(
      id, waitMilliseconds: 2000, knownStatus: "running")
    XCTAssertEqual(terminal["status"], "completed")
    XCTAssertEqual(terminal["terminal"], true)
    XCTAssertEqual(terminal["waitSatisfied"], true)
    XCTAssertGreaterThan(terminal["waitedMilliseconds"].int ?? 0, 0)
    await jobs.shutdown()
  }

  func testJobHandoffAndStop() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let running = try await jobs.submit(
      ProcessRequest(program: "/bin/sleep", args: ["20"], cwd: f.root, syncWait: 0))
    XCTAssertEqual(running["status"].string, "running")
    let stopped = try await jobs.stop(try XCTUnwrap(running["jobId"].string))
    XCTAssertEqual(stopped["status"].string, "stopped")
    XCTAssertEqual(stopped["terminal"], true)
    await jobs.shutdown()
  }
  func testStopActiveJobsKeepsManagerAvailable() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    _ = try await jobs.submit(
      ProcessRequest(program: "/bin/sleep", args: ["20"], cwd: f.root, syncWait: 0))
    _ = try await jobs.submit(
      ProcessRequest(program: "/bin/sleep", args: ["20"], cwd: f.root, syncWait: 0))
    let activeBefore = await jobs.activeCount()
    XCTAssertEqual(activeBefore, 2)
    let stopped = await jobs.stopActive()
    XCTAssertEqual(stopped, 2)
    let activeAfter = await jobs.activeCount()
    XCTAssertEqual(activeAfter, 0)
    var next = try await jobs.submit(
      ProcessRequest(program: "/usr/bin/true", cwd: f.root, syncWait: 3))
    if let id = next["jobId"].string {
      for _ in 0..<200 where next["terminal"] != true {
        try await Task.sleep(for: .milliseconds(50))
        next = try await jobs.status(id)
      }
    }
    XCTAssertEqual(next["status"].string, "completed")
    await jobs.shutdown()
  }
  func testInteractiveJobAcceptsFollowupInput() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let running = try await jobs.submit(
      ProcessRequest(program: "/bin/cat", cwd: f.root, interactive: true, syncWait: 0))
    let id = try XCTUnwrap(running["jobId"].string)
    XCTAssertEqual(running["interactive"], true)
    XCTAssertEqual(running["terminalMode"], "pipe")
    XCTAssertEqual(running["stdinOpen"], true)

    _ = try await jobs.input(id, text: "hello interactive\n", close: true)
    var result = try await jobs.status(id)
    for _ in 0..<50 where result["terminal"] != true {
      try await Task.sleep(for: .milliseconds(50))
      result = try await jobs.status(id)
    }
    XCTAssertEqual(result["status"].string, "completed")
    XCTAssertTrue(result["stdoutTail"].string?.contains("hello interactive") == true)
    XCTAssertEqual(result["stdinOpen"], false)
    await jobs.shutdown()
  }

  func testPTYModeProvidesRealTTYAndInteractiveInput() async throws {
    #if os(macOS)
      let f = try Fixture()
      defer { f.remove() }
      let jobs = JobManager(helper: Fixture.helper)
      let script = "import os; print(f'tty={os.isatty(0)},{os.isatty(1)},{os.isatty(2)}', flush=True); print(input(), flush=True)"
      let running = try await jobs.submit(
        ProcessRequest(
          program: "/usr/bin/python3", args: ["-c", script], cwd: f.root,
          interactive: true, terminalMode: "pty", timeout: 10, syncWait: 0))
      let id = try XCTUnwrap(running["jobId"].string)
      XCTAssertEqual(running["terminalMode"], "pty")
      XCTAssertTrue(running["stdinOpen"] == true)

      _ = try await jobs.input(id, text: "hello pty\n", close: false)
      var result = try await jobs.status(id)
      for _ in 0..<100 where result["terminal"] != true {
        try await Task.sleep(for: .milliseconds(30))
        result = try await jobs.status(id)
      }
      XCTAssertEqual(result["status"], "completed")
      XCTAssertTrue(result["stdoutTail"].string?.contains("tty=True,True,True") == true)
      XCTAssertTrue(result["stdoutTail"].string?.contains("hello pty") == true)
      await jobs.shutdown()
    #endif
  }

  func testSameIdempotencyKeyDoesNotRunTwice() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let request = ProcessRequest(
      program: "/bin/sh", args: ["-c", "echo x >> once"], cwd: f.root, syncWait: 3,
      idempotencyKey: "one")
    let first = try await jobs.submit(request)
    let second = try await jobs.submit(request)
    XCTAssertEqual(first["jobId"], second["jobId"])
    XCTAssertEqual(
      try String(contentsOf: f.root.appendingPathComponent("once"), encoding: .utf8), "x\n")
    do {
      _ = try await jobs.submit(
        ProcessRequest(
          program: "/bin/echo", args: ["different"], cwd: f.root, idempotencyKey: "one"))
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "idempotency_conflict") }
    await jobs.shutdown()
  }
  func testBoundedOutputDoesNotDeadlock() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh", args: ["-c", "yes x | head -c 200000"], cwd: f.root, syncWait: 3))
    XCTAssertEqual(result["terminal"], true)
    XCTAssertEqual(result["stdoutTruncated"], true)
    XCTAssertLessThanOrEqual(result["stdoutTail"].string?.utf8.count ?? Int.max, 65_536)
    await jobs.shutdown()
  }
  func testOutputIsVisibleBeforeProcessExit() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let first = try await jobs.submit(ProcessRequest(program: "/bin/sh", args: ["-c", "printf 'http://localhost:5173/\\n'; sleep 10"], cwd: f.root, syncWait: 1))
    XCTAssertEqual(first["terminal"], false)
    XCTAssertEqual(first["detectedUrls"].array, ["http://localhost:5173/"])
    XCTAssertTrue(first["stdoutTail"].string?.contains("5173") == true)
    _ = try await jobs.stop(first["jobId"].string!)
    await jobs.shutdown()
  }
  func testIncrementalJobLogsUseOffsetsWithoutRepeatingOldOutput() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let first = try await jobs.submit(
      ProcessRequest(
        program: "/bin/sh",
        args: ["-c", "printf 'first\\n'; sleep 1; printf 'second\\n'"],
        cwd: f.root, timeout: 10, syncWait: 0))
    let id = try XCTUnwrap(first["jobId"].string)

    var observed = try await jobs.status(id)
    for _ in 0..<40 where !(observed["stdoutTail"].string?.contains("first") == true) {
      try await Task.sleep(for: .milliseconds(25))
      observed = try await jobs.status(id)
    }
    XCTAssertTrue(observed["stdoutTail"].string?.contains("first") == true)
    XCTAssertFalse(observed["stdoutTail"].string?.contains("second") == true)
    let offset = try XCTUnwrap(observed["stdoutBytes"].int)

    var terminal = observed
    for _ in 0..<80 where terminal["terminal"] != true {
      try await Task.sleep(for: .milliseconds(25))
      terminal = try await jobs.status(id)
    }
    XCTAssertEqual(terminal["status"], "completed")

    let delta = try await jobs.logs(
      id, stdoutOffset: offset, stderrOffset: 0, maxBytes: 65_536)
    let stdout = delta["delta"]["stdout"]
    XCTAssertEqual(stdout["fromOffset"].int, offset)
    XCTAssertTrue(stdout["text"].string?.contains("second") == true)
    XCTAssertFalse(stdout["text"].string?.contains("first") == true)
    XCTAssertEqual(stdout["nextOffset"], terminal["stdoutBytes"])
    await jobs.shutdown()
  }

  func testChangedEnvironmentRejectsIdempotentReplay() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    _ = try await jobs.submit(ProcessRequest(program: "/usr/bin/true", cwd: f.root, environment: ["CUSTOM_FLAG": "one"], syncWait: 3, idempotencyKey: "env"))
    do {
      _ = try await jobs.submit(ProcessRequest(program: "/usr/bin/true", cwd: f.root, environment: ["CUSTOM_FLAG": "two"], idempotencyKey: "env"))
      XCTFail()
    } catch let error as Failure { XCTAssertEqual(error.code, "idempotency_conflict") }
    await jobs.shutdown()
  }
  func testShutdownRejectsNewWork() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    await jobs.shutdown()
    do {
      _ = try await jobs.submit(ProcessRequest(program: "/bin/echo", cwd: f.root))
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "runtime_stopped") }
  }
}
