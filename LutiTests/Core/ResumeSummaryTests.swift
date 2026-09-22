import Foundation
import XCTest
@testable import Luti

@MainActor final class ResumeSummaryTests: XCTestCase {
  private func store(_ fixture: Fixture) throws -> ProjectContextStore {
    try ProjectContextStore(project: ApprovedProject(url: fixture.root), dataRoot: fixture.contextDataRoot)
  }

  private func persist(_ journal: SessionJournal, in store: ProjectContextStore) throws {
    try PrivateFiles.atomicWrite(ContextCoding.encode(journal), to: store.sessionsDirectory
      .appendingPathComponent(journal.runId.uuidString.lowercased() + ".json"))
  }

  private func journal(_ store: ProjectContextStore, time: TimeInterval = 1000) -> SessionJournal {
    let date = Date(timeIntervalSince1970: time)
    return SessionJournal(runId: UUID(), projectKey: store.projectKey, startedAt: date,
                          updatedAt: date, finishedAt: date, status: "completed")
  }

  func testEmptyProjectReturnsNoInventedWorkOrNextStep() throws {
    let f = try Fixture(); defer { f.remove() }
    let project = ApprovedProject(id: "approved-fixture", name: "Fixture project", url: f.root)
    let s = try ProjectContextStore(project: project, dataRoot: f.contextDataRoot)
    try s.startSession(UUID())
    let result = try s.recent(projectToken: "project_current")
    XCTAssertEqual(result["projectToken"], "project_current")
    XCTAssertEqual(result["project"]["id"], .string(project.id))
    XCTAssertEqual(result["project"]["name"], .string(project.name))
    XCTAssertEqual(result["latestSession"], .null)
    XCTAssertEqual(result["runtimeFacts"]["touchedFiles"], [])
    XCTAssertEqual(result["runtimeFacts"]["activeJobs"], [])
    XCTAssertEqual(result["modelAssertions"]["goalMemoryIds"], [])
    XCTAssertEqual(result["nextStep"], .null)
    XCTAssertLessThanOrEqual(try result.data().count, ProjectResumeSummary.maxBytes)
  }

  func testRuntimeResumeReturnsApprovedIdentityAndTokenDespiteModelClaims() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    let approved = await router.call("projects", arguments: ["action": "current"])
    let memory = await router.callInCurrentProject("memory", arguments: [
      "action": "remember", "kind": "goal", "content": "Project ID is model-invented and its name is Fake Project",
    ])
    XCTAssertFalse(memory.isError)
    let result = await router.call("memory", arguments: ["action": "recent"])
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.data["project"]["id"], approved.data["project"]["id"])
    XCTAssertEqual(result.data["project"]["name"], approved.data["project"]["name"])
    XCTAssertEqual(result.data["projectToken"], approved.data["projectToken"])
    XCTAssertNotEqual(result.data["project"]["id"], "model-invented")
    XCTAssertLessThanOrEqual(try result.data.data().count, ProjectResumeSummary.maxBytes)
  }

  func testCompactStartupFixtureRetainsIdentityAndTasksWithFewerResponses() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("AGENTS.md", "Read project instructions before editing.")
    try f.write("package.json", #"{"scripts":{"build":"vite build","test":"vitest run","typecheck":"tsc --noEmit"}}"#)
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    let current = await router.call("projects", arguments: ["action": "current"])
    let recent = await router.call("memory", arguments: ["action": "recent"])
    let full = await router.call("inspect_project", arguments: [:])
    let compact = await router.call("inspect_project", arguments: ["view": "summary"])
    for output in [current, recent, full, compact] { XCTAssertFalse(output.isError) }
    XCTAssertEqual(recent.data["project"]["id"], current.data["project"]["id"])
    XCTAssertEqual(recent.data["project"]["name"], current.data["project"]["name"])
    XCTAssertEqual(recent.data["projectToken"], current.data["projectToken"])
    XCTAssertEqual(compact.data["taskRegistry"], full.data["taskRegistry"])
    XCTAssertEqual(compact.data["instructions"], full.data["instructions"])
    // Compare explicit workflow fixtures, not a claim about any Host's model loop.
    // Count compact structured JSON bytes; MCP text duplication/framing is excluded.
    let previousFlow = [current.data, recent.data, full.data]
    let compactFlow = [recent.data, compact.data]
    let previousBytes = try previousFlow.reduce(0) { try $0 + $1.data().count }
    let compactBytes = try compactFlow.reduce(0) { try $0 + $1.data().count }
    XCTAssertEqual(previousFlow.count, 3)
    XCTAssertEqual(compactFlow.count, 2)
    XCTAssertLessThan(compactBytes, previousBytes)
    print("Startup fixture structured JSON: identity+recent+full=3 calls/\(previousBytes) bytes; recent+summary=2 calls/\(compactBytes) bytes")
  }

  func testEmptyAndDiscoverySessionsDoNotHidePriorWorkOrInterruptions() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    var old = journal(s)
    old.status = "interrupted"
    old.touchedFiles = ["Sources/App.swift"]
    old.calls = [SessionCall(id: UUID(), tool: "edit_files", action: "replace",
      startedAt: old.startedAt, finishedAt: nil, status: "interrupted", operationState: "interrupted",
      effect: "possible", jobId: nil, errorCode: "session_interrupted", recovery: "Observe first.",
      checkpointId: "chk_fixture", source: nil)]
    try persist(old, in: s)
    let current = UUID()
    try s.startSession(current)
    try s.recordCallStarted(runID: current, id: UUID(), tool: "memory", action: "recent", startedAt: Date(), source: nil)
    let result = try s.recent()
    XCTAssertEqual(result["latestSession"]["runId"], .string(old.runId.uuidString))
    XCTAssertEqual(result["runtimeFacts"]["touchedFiles"], ["Sources/App.swift"])
    let interruption = try XCTUnwrap(result["runtimeFacts"]["interruptedOperations"].array?.first)
    XCTAssertEqual(interruption["checkpointId"], "chk_fixture")
    XCTAssertEqual(interruption["requiresObservation"], true)
    XCTAssertEqual(interruption["automaticallyRetried"], false)
    XCTAssertEqual(result["continuation"]["sessions"]["arguments"]["runId"], .string(old.runId.uuidString))
    XCTAssertEqual(try s.session(current).calls.count, 1, "A resume query must not replay historical operations.")
  }

  func testGoalsRetainModelProvenanceAndPrecedeNewerUnrelatedMemories() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let source = MemorySource(type: "model", runId: UUID(), host: "Original Host", clientId: "client-fixture", transport: "loopback")
    let goal = try s.remember(kind: .goal, content: "Finish the import flow", tags: [], supersedes: nil,
                              expectedRevision: nil, source: source)
    for index in 0..<8 {
      _ = try s.remember(kind: .convention, content: "Convention \(index)", tags: [], supersedes: nil,
                        expectedRevision: nil, source: source)
    }
    let result = try s.recent()
    let first = try XCTUnwrap(result["memories"].array?.first)
    XCTAssertEqual(first["id"], goal["memory"]["id"])
    XCTAssertEqual(first["source"]["host"], "Original Host")
    XCTAssertEqual(first["classification"], "model_assertion")
    XCTAssertEqual(result["modelAssertions"]["goalMemoryIds"], .array([first["id"]]))
    XCTAssertEqual(result["runtimeFacts"]["classification"], "runtime_fact")
    XCTAssertEqual(result["latestSession"], .null)
  }

  func testCurrentHandlesAreSeparatedFromHistoricalRecordsAndRawLogsAreExcluded() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    var old = journal(s)
    old.jobs = [SessionJob(id: "job_old", status: "failed", terminal: true, exitCode: 1,
                          tests: SessionTestCounts(passed: 2, failed: 1, skipped: 0))]
    old.artifacts = [SessionArtifact(id: "luti://artifact/expired", name: "old.png", mimeType: "image/png", bytes: 10),
                     SessionArtifact(id: "luti://artifact/live", name: "live.png", mimeType: "image/png", bytes: 20)]
    try persist(old, in: s)
    let current: JSONValue = ["jobId": "job_active", "status": "running", "terminal": false,
                              "stdoutTail": "PRIVATE_RAW_OUTPUT", "command": "PRIVATE_ARGV"]
    let result = try s.recent(currentJobs: [current], currentArtifacts: [["uri": "luti://artifact/live"]])
    let active = try XCTUnwrap(result["runtimeFacts"]["activeJobs"].array?.first)
    XCTAssertEqual(active["queryable"], true)
    XCTAssertEqual(active["query"]["arguments"]["jobId"], "job_active")
    let priorJob = try XCTUnwrap(result["runtimeFacts"]["recentValidation"].array?.first)
    XCTAssertEqual(priorJob["queryable"], false)
    XCTAssertEqual(priorJob["query"], .null)
    let artifacts = try XCTUnwrap(result["runtimeFacts"]["artifacts"].array)
    let expired = try XCTUnwrap(artifacts.first { $0["recordedResource"] == "luti://artifact/expired" })
    XCTAssertEqual(expired["available"], false)
    XCTAssertEqual(expired["resource"], .null)
    XCTAssertEqual(artifacts.first { $0["available"] == true }?["resource"], "luti://artifact/live")
    XCTAssertFalse(result.text().contains("PRIVATE_RAW_OUTPUT"))
    XCTAssertFalse(result.text().contains("PRIVATE_ARGV"))
  }

  func testCompletedLiveValidationKeepsResultAndInputFreshnessSeparate() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let current: JSONValue = ["jobId": "job_checked", "status": "completed", "terminal": true, "exitCode": 0,
      "validation": ["resultKind": "tests_recognized", "processOutcome": "succeeded", "outputComplete": true,
                     "input": ["scopeComplete": false, "freshness": "stale", "consistency": "unknown"]]]
    let result = try s.recent(currentJobs: [current])
    let validation = try XCTUnwrap(result["runtimeFacts"]["recentValidation"].array?.first?["validation"])
    XCTAssertEqual(validation["resultKind"], "tests_recognized")
    XCTAssertEqual(validation["input"]["freshness"], "stale")
    XCTAssertEqual(validation["input"]["scopeComplete"], false)
    XCTAssertEqual(validation["verified"], .null)
  }

  func testLargeValidationKeepsOutcomeAndPointsToExistingQueries() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let files: [JSONValue] = (0..<32).map {
      ["path": .string("Sources/" + String(repeating: "very-long-folder/", count: 12) + "\($0).swift"),
       "state": "present", "sha256": .string(String(repeating: "a", count: 64))]
    }
    let current: JSONValue = ["jobId": "job_checked", "status": "completed", "terminal": true,
      "validation": ["resultKind": "tests_recognized", "outputComplete": true,
        "input": ["freshness": "observed_match", "consistency": "unknown", "scopeComplete": false,
          "before": ["files": .array(files)], "after": ["files": .array(files)], "current": ["files": .array(files)]]]]
    let result = try s.recent(currentJobs: [current])
    let row = try XCTUnwrap(result["runtimeFacts"]["recentValidation"].array?.first)
    XCTAssertEqual(row["validation"]["resultKind"], "tests_recognized")
    XCTAssertEqual(row["validation"]["detailsOmittedFromSummary"], true)
    XCTAssertEqual(row["validation"]["input"]["before"]["fileCount"], 32)
    XCTAssertEqual(row["query"]["tool"], "job_query")
    XCTAssertLessThanOrEqual(try result.data().count, ProjectResumeSummary.maxBytes)
  }

  func testHistoricalValidationDoesNotReuseOldFreshnessAsCurrentObservation() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    var old = journal(s)
    let snapshot = ValidationScopeSnapshot(observedAt: old.startedAt,
      files: [ValidationFileDigest(path: "Source.swift", state: "present", sha256: "old-digest")],
      complete: true, omittedFiles: 0)
    let input = ValidationInputEvidence(scope: "session-touched-files-and-manifests", scopeComplete: false,
      before: snapshot, after: snapshot, current: snapshot, consistency: "unknown", freshness: "observed_match")
    let validation = ValidationEvidence(resultKind: "command_only", processOutcome: "succeeded",
      observedAt: old.updatedAt, outputComplete: true, input: input)
    old.jobs = [SessionJob(id: "job_historical", status: "completed", terminal: true,
                          exitCode: 0, tests: nil, validation: validation)]
    try persist(old, in: s)
    try f.write("Source.swift", "changed after the recorded validation")
    let result = try s.recent()
    let row = try XCTUnwrap(result["runtimeFacts"]["recentValidation"].array?.first)
    XCTAssertEqual(row["queryable"], false)
    XCTAssertEqual(row["validation"]["input"]["freshness"], "unknown")
    XCTAssertEqual(row["validation"]["input"]["recordedFreshness"], "observed_match")
    XCTAssertEqual(row["validation"]["input"]["current"], .null)
    XCTAssertEqual(row["details"]["arguments"]["runId"], .string(old.runId.uuidString))
  }

  func testBudgetIncludesEscapingAndEveryTruncatedSectionHasExistingFallback() throws {
    let f = try Fixture(); defer { f.remove() }
    let project = ApprovedProject(id: String(repeating: "\u{02}", count: 80),
                                  name: String(repeating: "\u{03}", count: 128), url: f.root)
    let s = try ProjectContextStore(project: project, dataRoot: f.contextDataRoot)
    let source = MemorySource(type: "model", runId: UUID(), host: "Fixture", clientId: nil, transport: "loopback")
    for index in 0..<5 {
      _ = try s.remember(kind: .goal, content: "Goal \(index) " + String(repeating: "\u{01}", count: 1600),
        tags: [], supersedes: nil, expectedRevision: nil, source: source)
    }
    var old = journal(s)
    old.touchedFiles = (0..<128).map { "Sources/" + String(repeating: "folder/", count: 30) + "\($0).swift" }
    try persist(old, in: s)
    let result = try s.recent(projectToken: "project_fixture")
    XCTAssertEqual(result["project"]["id"], .string(project.id))
    XCTAssertEqual(result["project"]["name"], .string(project.name))
    XCTAssertLessThanOrEqual(try result.data().count, ProjectResumeSummary.maxBytes)
    XCTAssertEqual(result["truncated"], true)
    XCTAssertEqual(result["memoriesTruncated"], true)
    XCTAssertLessThan(result["memories"].array?.count ?? 0, 5)
    XCTAssertTrue(result["runtimeFacts"]["truncatedSections"].array?.contains("touchedFiles") == true)
    XCTAssertEqual(result["continuation"]["sessions"]["tool"], "memory")
    XCTAssertEqual(result["continuation"]["recall"]["arguments"]["action"], "recall")
  }
}
