import XCTest

@testable import Luti

@MainActor final class ValidationEvidenceTests: XCTestCase {
  func testFinalXCTestSummaryWithSkippedTestsSupersedesPassingChildSuite() throws {
    let output = """
    Test Suite 'PassingTests' passed.
      Executed 1 test, with 0 failures (0 unexpected) in 0.001 seconds
    Test Suite 'All tests' failed.
      Executed 3 tests, with 1 test skipped and 1 failure (0 unexpected) in 0.003 seconds
    """
    let result = try XCTUnwrap(TestEvidenceParser.parse(output))
    XCTAssertEqual(result.framework, "xctest")
    XCTAssertEqual(result.status, "failed")
    XCTAssertEqual(result.total, 3)
    XCTAssertEqual(result.passed, 1)
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.skipped, 1)
    let skipped = try XCTUnwrap(TestEvidenceParser.parse(
      "Executed 4 tests, with 2 tests skipped and 0 failures (0 unexpected) in 0.003 seconds"))
    XCTAssertEqual(skipped.passed, 2)
    XCTAssertEqual(skipped.skipped, 2)
    XCTAssertNil(TestEvidenceParser.parse(
      "Executed 1 test, with 2 tests skipped and 0 failures (0 unexpected) in 0.003 seconds"))
  }

  func testFinalPytestSummaryWithWarningsDoesNotFallBackToEarlierPass() throws {
    let result = try XCTUnwrap(TestEvidenceParser.parse("""
    ================ 2 passed in 0.14s ================
    ================ 1 failed, 1 passed, 2 warnings in 0.14s ================
    """))
    XCTAssertEqual(result.framework, "pytest")
    XCTAssertEqual(result.status, "failed")
    XCTAssertEqual(result.total, 2)
    XCTAssertEqual(result.passed, 1)
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.skipped, 0)
  }

  func testParsesRunnerOutputThroughWrappersWithoutGuessingFromCommand() throws {
    let pytest = try XCTUnwrap(TestEvidenceParser.parse("================ 2 passed, 1 skipped in 0.14s ================\n"))
    XCTAssertEqual(pytest.framework, "pytest")
    XCTAssertEqual(pytest.total, 3)
    XCTAssertEqual(pytest.passed, 2)
    let errors = try XCTUnwrap(TestEvidenceParser.parse("=== 1 passed, 2 errors in 0.14s ==="))
    XCTAssertEqual(errors.errors, 2, "Plural errors must not be counted twice.")
    XCTAssertEqual(errors.total, 3)
    let vitest = try XCTUnwrap(TestEvidenceParser.parse(" Test Files  1 passed (1)\n      Tests  3 passed | 1 skipped (4)\n"))
    XCTAssertEqual(vitest.framework, "vitest")
    XCTAssertEqual(vitest.total, 4)
    XCTAssertEqual(vitest.passed, 3, "Test file counts must not be confused with case counts.")
    XCTAssertNil(TestEvidenceParser.parse("deployment complete: 7 passed, 1 failed\n"))
    for invalid in [
      "=== 1 passed, 9223372036854775808 errors in 0.14s ===",
      "Tests: 9223372036854775808 failed, 1 passed, 1 total",
      "Tests  1 passed | 9223372036854775808 failed (1)",
      "Tests: 1 passed, 2 total",
    ] { XCTAssertNil(TestEvidenceParser.parse(invalid), "Invalid counts must not become zero failures.") }
  }

  func testZeroTestsCommandSuccessAndIncompleteAreSeparateObservations() {
    let zero = ValidationEvidence.process(command: "npm test", stdout: "No test files found, exiting with code 0\n",
      stderr: "", status: "completed", terminal: true, outputComplete: true, observedAt: Date())
    XCTAssertEqual(zero.resultKind, "no_tests")
    XCTAssertEqual(zero.processOutcome, "succeeded")
    XCTAssertEqual(zero.tests?.status, "no_tests")
    let command = ValidationEvidence.process(command: "npm test", stdout: "done", stderr: "",
      status: "completed", terminal: true, outputComplete: true, observedAt: Date())
    XCTAssertEqual(command.resultKind, "command_only")
    XCTAssertNil(command.tests)
    for status in ["completed", "stopped", "timed_out"] {
      let result = ValidationEvidence.process(command: "wrapper", stdout: "Tests: 5 passed, 5 total", stderr: "",
        status: status, terminal: true, outputComplete: false, observedAt: Date())
      XCTAssertEqual(result.resultKind, "incomplete")
      XCTAssertEqual(result.tests?.status, "unknown")
    }
    let failedAfterTests = ValidationEvidence.process(command: "wrapper", stdout: "Tests: 5 passed, 5 total",
      stderr: "cleanup failed", status: "failed", terminal: true, outputComplete: true, observedAt: Date())
    XCTAssertEqual(failedAfterTests.processOutcome, "failed")
    XCTAssertEqual(failedAfterTests.tests?.status, "passed")
  }

  func testJUnitNestedSuitesAreCountedOnceAndInvalidDocumentsAreRejected() throws {
    let valid = """
    <testsuites tests="3" failures="1" errors="0" skipped="1">
      <testsuite tests="2" failures="1"><testcase name="a"/><testcase name="b"><failure>failed</failure></testcase></testsuite>
      <testsuite tests="1" skipped="1"><testcase name="c"><skipped/></testcase></testsuite>
    </testsuites>
    """
    let result = try XCTUnwrap(TestEvidenceParser.junit(Data(valid.utf8)))
    XCTAssertEqual(result.total, 3)
    XCTAssertEqual(result.passed, 1)
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.skipped, 1)
    XCTAssertEqual(result.status, "failed")
    for invalid in [
      "<testsuite tests=\"2\"><testcase/></testsuite>",
      "<testsuite tests=\"1\" failures=\"2\"/>",
      "<!DOCTYPE x [<!ENTITY secret SYSTEM \"file:///etc/passwd\">]><testsuite tests=\"0\"/>",
      "<testsuite tests=\"1\"><testcase>",
      "<other tests=\"100\"/>",
    ] { XCTAssertNil(TestEvidenceParser.junit(Data(invalid.utf8)), invalid) }
  }

  func testScopedHashesDetectChangesAndNeverClaimIntervalConsistency() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/main.swift", "let first = 1")
    let files = try WorkspaceFiles(root: f.root)
    let before = await ValidationScopeSnapshot.capture(files: files, paths: ["src/main.swift", "missing.swift"])
    var evidence = ValidationInputEvidence(scope: "session-touched-files-and-manifests", scopeComplete: false,
      before: before, after: before, current: before, consistency: "unknown", freshness: "unknown")
    evidence.assess()
    XCTAssertEqual(evidence.freshness, "observed_match")
    XCTAssertFalse(evidence.scopeComplete)
    XCTAssertEqual(evidence.consistency, "unknown")
    try f.write("src/main.swift", "let second = 2")
    evidence.current = await ValidationScopeSnapshot.capture(files: files, paths: before.files.map(\.path))
    evidence.assess()
    XCTAssertEqual(evidence.freshness, "stale")
    let incomplete = await ValidationScopeSnapshot.capture(files: files, paths: [".env", "src/main.swift"])
    XCTAssertFalse(incomplete.complete)
    XCTAssertEqual(incomplete.omittedFiles, 1)
    XCTAssertFalse(incomplete.files.contains { $0.path == ".env" })
  }

  func testJobCapturesBeforeAfterAndRefreshesAfterExternalEdits() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("input.txt", "initial")
    let files = try WorkspaceFiles(root: f.root)
    let jobs = JobManager(helper: Fixture.helper)
    let scope = ValidationScopeRequest(files: files, paths: ["input.txt"], taskID: "task:check", purpose: "test")
    let request = ProcessRequest(program: "/bin/sh", args: ["-c", "printf 'Tests: 2 passed, 2 total\\n'"],
      cwd: f.root, syncWait: 3, idempotencyKey: "validation-once")
    let result = try await jobs.submit(request, validation: scope)
    XCTAssertEqual(result["validation"]["tests"]["total"], 2)
    XCTAssertEqual(result["validation"]["taskId"], "task:check")
    XCTAssertEqual(result["validation"]["input"]["freshness"], "observed_match")
    XCTAssertNotEqual(result["validation"]["input"]["after"], .null)
    let id = try XCTUnwrap(result["jobId"].string)
    try f.write("input.txt", "external change")
    let changed = try await jobs.status(id)
    XCTAssertEqual(changed["validation"]["input"]["freshness"], "stale")
    let repeatResult = try await jobs.submit(request, validation: scope)
    XCTAssertEqual(repeatResult["jobId"], result["jobId"])
    XCTAssertEqual(repeatResult["validation"]["input"]["freshness"], "stale")
    await jobs.shutdown()
  }

  func testFreshJUnitReportAndUnchangedOldReportRemainDistinguishable() async throws {
    let f = try Fixture(); defer { f.remove() }
    let files = try WorkspaceFiles(root: f.root)
    let jobs = JobManager(helper: Fixture.helper)
    let scope = ValidationScopeRequest(files: files, paths: [], reportPath: "report.xml")
    let created = try await jobs.submit(ProcessRequest(program: "/bin/sh",
      args: ["-c", "printf '<testsuite tests=\"2\" failures=\"0\"/>' > report.xml"], cwd: f.root, syncWait: 3), validation: scope)
    XCTAssertEqual(created["validation"]["report"]["provenance"], "changed_since_launch")
    XCTAssertEqual(created["validation"]["tests"]["source"], "junit-xml")
    XCTAssertEqual(created["validation"]["tests"]["total"], 2)
    let old = try await jobs.submit(ProcessRequest(program: "/usr/bin/true", cwd: f.root, syncWait: 3), validation: scope)
    XCTAssertEqual(old["validation"]["report"]["status"], "unattributed")
    XCTAssertEqual(old["validation"]["tests"], .null)
    XCTAssertEqual(old["validation"]["input"]["freshness"], "unknown")
    await jobs.shutdown()
  }

  func testBuildOnlyAndActualTruncatedOutputDoNotClaimPassingTests() async throws {
    let f = try Fixture(); defer { f.remove() }
    let files = try WorkspaceFiles(root: f.root)
    let jobs = JobManager(helper: Fixture.helper)
    let build = try await jobs.submit(ProcessRequest(program: "/usr/bin/true", cwd: f.root, syncWait: 3),
      validation: ValidationScopeRequest(files: files, paths: [], purpose: "build"))
    XCTAssertEqual(build["validation"]["resultKind"], "build_only")
    XCTAssertEqual(build["validation"]["tests"], .null)
    let truncated = try await jobs.submit(ProcessRequest(program: "/usr/bin/awk",
      args: ["BEGIN { for (i=0; i<10000; i++) print \"padding line\"; print \"Tests: 1 passed, 1 total\" }"],
      cwd: f.root, syncWait: 3))
    XCTAssertEqual(truncated["status"], "completed")
    XCTAssertEqual(truncated["stdoutTruncated"], true)
    XCTAssertEqual(truncated["validation"]["resultKind"], "incomplete")
    XCTAssertEqual(truncated["validation"]["tests"]["status"], "unknown")
    await jobs.shutdown()
  }

  func testLifecyclePollingDoesNotPresentOldHashesAsCurrentObservations() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("input.txt", "before")
    let files = try WorkspaceFiles(root: f.root)
    let jobs = JobManager(helper: Fixture.helper)
    let result = try await jobs.submit(ProcessRequest(program: "/usr/bin/true", cwd: f.root, syncWait: 3),
      validation: ValidationScopeRequest(files: files, paths: ["input.txt"]))
    let id = try XCTUnwrap(result["jobId"].string)
    try f.write("input.txt", "after")
    let lifecycleRows = await jobs.list(refreshInputs: false)
    let lifecycle = try XCTUnwrap(lifecycleRows.first)
    XCTAssertEqual(lifecycle["validation"]["input"]["current"], .null)
    XCTAssertEqual(lifecycle["validation"]["input"]["freshness"], "unknown")
    XCTAssertNotEqual(lifecycle["validation"]["input"]["after"], .null)
    let status = try await jobs.status(id)
    XCTAssertEqual(status["validation"]["input"]["freshness"], "stale")
    let queriedRows = await jobs.list(refreshInputs: true)
    let queried = try XCTUnwrap(queriedRows.first)
    XCTAssertEqual(queried["validation"]["input"]["freshness"], "stale")
    await jobs.shutdown()
  }

  func testSessionBudgetDropsOldEvidenceBeforeLosingTouchedFilesAndCommands() async throws {
    let f = try Fixture(); defer { f.remove() }
    let store = try ProjectContextStore(project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot)
    let run = UUID(), started = Date()
    try store.startSession(run)
    let paths = (0..<32).map { "Sources/" + String(repeating: "a", count: 96) + "-\($0).swift" }
    for path in paths { try f.write(path, "let value = 1") }
    let edit = ActivityEvent(id: UUID(), runID: run, startedAt: started, finishedAt: started,
      tool: "edit_files", target: "Sources", status: "ok", summary: "Edited files", durationSeconds: 0)
    try store.recordCallFinished(runID: run, event: edit, arguments: [:], output: ToolOutput([
      "applied": true, "files": .array(paths.map { ["path": .string($0), "wouldChange": true] }),
    ]))
    let observed = await ValidationScopeSnapshot.capture(files: f.files, paths: paths)
    XCTAssertTrue(observed.complete)
    var snapshots: [JSONValue] = []
    for index in 0..<10 {
      let time = started.addingTimeInterval(Double(index + 1)), id = "job_budget_\(index)"
      var evidence = ValidationEvidence.process(command: "swift test", stdout: "Executed 1 test, with 0 failures",
        stderr: "", status: "completed", terminal: true, outputComplete: true, observedAt: time)
      evidence.input = ValidationInputEvidence(scope: "session-touched-files-and-manifests", scopeComplete: false,
        before: observed, after: observed, current: observed, consistency: "unknown", freshness: "observed_match")
      let snapshot: JSONValue = ["jobId": .string(id), "status": "completed", "terminal": true, "exitCode": 0,
        "testSummary": evidence.tests!.json, "validation": try ContextCoding.json(evidence)]
      snapshots.append(snapshot)
      let event = ActivityEvent(id: UUID(), runID: run, startedAt: time, finishedAt: time,
        tool: "run_process", target: "swift", status: "ok", summary: "Tests completed", jobID: id, durationSeconds: 0)
      try store.recordCallFinished(runID: run, event: event, arguments: ["program": "swift", "args": ["test"]],
        output: ToolOutput(snapshot))
    }
    let journal = try store.session(run)
    XCTAssertEqual(journal.touchedFiles, paths)
    XCTAssertEqual(journal.commands.count, 10)
    XCTAssertEqual(journal.jobs.count, 10)
    XCTAssertNotNil(journal.jobs.last?.validation)
    XCTAssertTrue(journal.jobs.contains { $0.validationOmitted == true && $0.validation == nil })
    XCTAssertGreaterThan(journal.omittedFacts, 0)
    XCTAssertLessThanOrEqual(try ContextCoding.encode(journal).count, ProjectContextStore.maxSessionBytes)
    try store.reconcileSessionJobs(snapshots, runID: run)
    try store.reconcileSessionJobs(snapshots, runID: run)
    let reconciled = try store.session(run)
    XCTAssertEqual(reconciled.omittedFacts, journal.omittedFacts)
    XCTAssertEqual(reconciled.updatedAt, journal.updatedAt)
  }
}
