import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Luti

@MainActor final class ProjectMemoryTests: XCTestCase {
  private func store(_ fixture: Fixture, project: ApprovedProject? = nil) throws -> ProjectContextStore {
    try ProjectContextStore(project: project ?? ApprovedProject(url: fixture.root), dataRoot: fixture.contextDataRoot)
  }
  private func source(_ host: String = "Fixture Host") -> MemorySource {
    MemorySource(type: "model", runId: UUID(), host: host, clientId: "fixture-client", transport: "cloudflare")
  }
  @discardableResult private func remember(_ store: ProjectContextStore, _ content: String = "Use project-scoped stores.") throws -> JSONValue {
    try store.remember(kind: .architecture, content: content, tags: ["storage"], supersedes: nil,
                       expectedRevision: nil, source: source())
  }

  func testCanonicalKeyPreventsSeparatorCollisionAndBoundsLongNames() throws {
    let a = URL(fileURLWithPath: "/fixture/a-b/c"), b = URL(fileURLWithPath: "/fixture/a/b-c")
    XCTAssertNotEqual(LutiPaths.projectKey(for: a), LutiPaths.projectKey(for: b))
    let long = URL(fileURLWithPath: "/fixture/" + String(repeating: "中文", count: 160))
    XCTAssertLessThanOrEqual(LutiPaths.projectKey(for: long).utf8.count, 186)
    let f = try Fixture(); defer { f.remove() }
    let alias = f.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
    XCTAssertEqual(LutiPaths.projectKey(for: alias), LutiPaths.projectKey(for: f.root))
  }

  func testReapprovalUsesSameNamespaceAndDifferentProjectIsIsolated() throws {
    let f = try Fixture(); let other = try Fixture(); defer { f.remove(); other.remove() }
    let first = try store(f, project: ApprovedProject(id: "first", url: f.root))
    try remember(first)
    let reapproved = try store(f, project: ApprovedProject(id: "new-approval", url: f.root))
    XCTAssertEqual(first.directory, reapproved.directory)
    XCTAssertEqual(try reapproved.recall()["totalMatches"], 1)
    let independent = try ProjectContextStore(project: ApprovedProject(url: other.root), dataRoot: f.contextDataRoot)
    XCTAssertEqual(try independent.recall()["totalMatches"], 0)
    XCTAssertNotEqual(first.directory, independent.directory)
  }

  func testRememberSupersedeForgetAndRestart() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let first = try remember(s, "Use one process-wide store.")
    let firstID = try XCTUnwrap(first["memory"]["id"].string)
    XCTAssertEqual(first["revision"], 1)
    let newer = try s.remember(kind: .decision, content: "Use a separate namespace for every project.", tags: ["storage"],
                              supersedes: firstID, expectedRevision: 1, source: source("Second Host"))
    let secondID = try XCTUnwrap(newer["memory"]["id"].string)
    XCTAssertEqual(newer["revision"], 2)
    XCTAssertEqual(try s.recall()["totalMatches"], 1)
    let history = try s.recall(includeHistory: true)
    XCTAssertEqual(history["totalMatches"], 2)
    XCTAssertEqual(history["memories"].array?.last?["status"], "superseded")
    XCTAssertEqual(newer["memory"]["supersedes"], .string(firstID))
    XCTAssertThrowsError(try s.remember(kind: .decision, content: "Stale update", tags: [], supersedes: secondID,
                                      expectedRevision: 1, source: source())) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_revision_conflict")
    }
    XCTAssertThrowsError(try s.remember(kind: .decision, content: "Missing revision", tags: [], supersedes: secondID,
                                      expectedRevision: nil, source: source()))
    let forgotten = try s.forget(id: secondID, expectedRevision: 2, source: source())
    XCTAssertEqual(forgotten["physicalDeletion"], false)
    XCTAssertEqual(forgotten["revision"], 3)
    XCTAssertEqual(try s.forget(id: secondID, expectedRevision: nil, source: source())["changed"], false)
    let reopened = try store(f)
    XCTAssertEqual(try reopened.recall()["totalMatches"], 0)
    XCTAssertEqual(try reopened.recall(includeHistory: true)["totalMatches"], 1)
    XCTAssertEqual(try reopened.recall(includeHistory: true, memoryId: secondID)["totalMatches"], 0)
    let recent = try reopened.recent()
    XCTAssertFalse(try recent.data().string.contains("separate namespace"))
    let ledger = try PrivateFiles.read(s.memoryDirectory.appendingPathComponent("facts.jsonl"), max: 65_536)
    XCTAssertTrue(ledger.string.contains("separate namespace"), "Logical forgetting keeps provenance until explicit local clear.")
    try reopened.clear(.memory)
    XCTAssertFalse(try PrivateFiles.read(s.memoryDirectory.appendingPathComponent("facts.jsonl"), max: 65_536).string.contains("separate namespace"))
  }

  func testSummaryIsBoundedDerivedAndNeverTrustsCachedMarkdown() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try remember(s, "Use deterministic project summaries.")
    let summaryURL = s.memoryDirectory.appendingPathComponent("project.md")
    try PrivateFiles.atomicWrite(Data("INJECTED_CACHE_ONLY".utf8), to: summaryURL)
    let recent = try s.recent()
    XCTAssertEqual(recent["summary"]["sourceRevision"], 1)
    XCTAssertNotNil(recent["summary"]["generatedAt"].string)
    XCTAssertFalse(recent["summary"]["text"].string!.contains("INJECTED_CACHE_ONLY"))
    XCTAssertLessThanOrEqual(recent["summary"]["text"].string!.utf8.count, 4096)
    XCTAssertFalse(try PrivateFiles.read(summaryURL, max: 4096).string.contains("INJECTED_CACHE_ONLY"))
  }

  func testConcurrentWritersDoNotLoseFacts() async throws {
    let f = try Fixture(); defer { f.remove() }
    let a = try store(f), b = try store(f)
    let author = source()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<16 {
        group.addTask {
          _ = try (i.isMultiple(of: 2) ? a : b).remember(kind: .convention, content: "Independent fact \(i)", tags: [],
            supersedes: nil, expectedRevision: nil, source: author)
        }
      }
      try await group.waitForAll()
    }
    let result = try a.recall(limit: 50)
    XCTAssertEqual(result["revision"], 16)
    XCTAssertEqual(result["totalMatches"], 16)
    XCTAssertEqual(Set(result["memories"].array!.compactMap { $0["id"].string }).count, 16)
  }

  func testRecallPaginationFiltersAndByteBudget() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for i in 0..<18 { try remember(s, "事实\(i) " + String(repeating: "界", count: 1000)) }
    let first = try s.recall(query: "事实", kind: .architecture, tags: ["storage"], limit: 50)
    XCTAssertEqual(first["totalMatches"], 18)
    XCTAssertEqual(first["truncated"], true)
    XCTAssertLessThanOrEqual(try first.data().count, 32_768)
    let next = try XCTUnwrap(first["nextOffset"].int)
    let second = try s.recall(query: "事实", limit: 50, offset: next)
    let a = Set(first["memories"].array!.compactMap { $0["id"].string })
    let b = Set(second["memories"].array!.compactMap { $0["id"].string })
    XCTAssertTrue(a.isDisjoint(with: b))
    XCTAssertEqual(try s.recall(tags: ["not-present"])["totalMatches"], 0)
    XCTAssertThrowsError(try s.recall(limit: -1))
    XCTAssertThrowsError(try s.recall(offset: -1))
  }

  func testSensitiveAndOversizedContentRejectedBeforeCommit() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for text in ["access_token=synthetic-test-value", "Cookie: fixture_only", String(repeating: "x", count: 4097)] {
      XCTAssertThrowsError(try remember(s, text))
    }
    XCTAssertEqual(try s.recall()["revision"], 0)
    let known = try ProjectContextStore(project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot,
                                       redactor: Redactor(known: ["fixture-known-private-marker"]))
    XCTAssertThrowsError(try remember(known, "Do not store fixture-known-private-marker"))
    XCTAssertEqual(try s.recall()["totalMatches"], 0)
  }

  func testActiveMemoryLimitRejectsNewFactsButAllowsReplacement() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for index in 0..<ProjectContextStore.maxActiveMemories {
      try remember(s, "Bounded memory \(index)")
    }
    XCTAssertEqual(try s.recall(limit: 1)["totalMatches"], .int(ProjectContextStore.maxActiveMemories))
    XCTAssertThrowsError(try remember(s, "One memory too many")) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_capacity")
    }

    let latest = try s.recall(limit: 1)
    let latestID = try XCTUnwrap(latest["memories"].array?.first?["id"].string)
    let revision = try XCTUnwrap(latest["revision"].int)
    let replacement = try s.remember(
      kind: .decision,
      content: "Replacement at capacity",
      tags: [],
      supersedes: latestID,
      expectedRevision: revision,
      source: source())
    XCTAssertEqual(replacement["changed"], true)
    XCTAssertEqual(try s.recall(limit: 1)["totalMatches"], .int(ProjectContextStore.maxActiveMemories))
  }

  func testCorruptLedgerFailsClosedAndLocalClearRecovers() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let file = s.memoryDirectory.appendingPathComponent("facts.jsonl")
    let broken = Data("{\"revision\":1".utf8)
    try PrivateFiles.atomicWrite(broken, to: file)
    XCTAssertThrowsError(try store(f))
    XCTAssertThrowsError(try remember(s))
    XCTAssertEqual(try PrivateFiles.read(file, max: 4096), broken)
    let repair = try ProjectContextStore(project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot, validateMemory: false)
    try repair.clear(.memory)
    XCTAssertEqual(try store(f).recall()["revision"], 0)
  }

  func testManifestMismatchFailsWithoutOverwritingIdentity() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let file = s.directory.appendingPathComponent("manifest.json")
    var manifest = try ContextCoding.decode(ProjectManifest.self, PrivateFiles.read(file, max: 16_384))
    manifest.schemaVersion = 900
    let data = try ContextCoding.encode(manifest)
    try PrivateFiles.atomicWrite(data, to: file)
    XCTAssertThrowsError(try store(f))
    XCTAssertEqual(try PrivateFiles.read(file, max: 16_384), data)
  }

  func testPrivateFilesPermissionsSymlinkAndHardlinkRefusal() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try remember(s)
    let file = s.memoryDirectory.appendingPathComponent("facts.jsonl")
    let dirMode = try FileManager.default.attributesOfItem(atPath: s.memoryDirectory.path)[.posixPermissions] as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(dirMode?.intValue, 0o700)
    XCTAssertEqual(fileMode?.intValue, 0o600)
    let external = f.root.appendingPathComponent("unrelated.txt")
    try Data("DO_NOT_OVERWRITE".utf8).write(to: external)
    let symbolic = s.directory.appendingPathComponent("symbolic")
    try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: external)
    XCTAssertThrowsError(try PrivateFiles.atomicWrite(Data(), to: symbolic))
    XCTAssertThrowsError(try PrivateFiles.read(symbolic, max: 4096))
    let hard = s.directory.appendingPathComponent("hard")
    try FileManager.default.linkItem(at: external, to: hard)
    XCTAssertThrowsError(try PrivateFiles.atomicWrite(Data(), to: hard))
    let ancestor = f.root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: s.directory)
    XCTAssertThrowsError(try PrivateFiles.atomicWrite(Data(), to: ancestor.appendingPathComponent("new")))
    XCTAssertEqual(try Data(contentsOf: external).string, "DO_NOT_OVERWRITE")
  }

  func testLogRotationIsBoundedAndDoesNotFollowLinks() throws {
    let f = try Fixture(); defer { f.remove() }
    let dir = f.contextDataRoot.appendingPathComponent("logs")
    let file = dir.appendingPathComponent("runtime.log")
    try PrivateFiles.appendRotating(Data("first\n".utf8), to: file, maxBytes: 10)
    try PrivateFiles.appendRotating(Data("second\n".utf8), to: file, maxBytes: 10)
    XCTAssertEqual(try PrivateFiles.read(file, max: 10).string, "second\n")
    XCTAssertEqual(try PrivateFiles.read(dir.appendingPathComponent("runtime.log.1"), max: 10).string, "first\n")
    try PrivateFiles.removeFile(file)
    let external = f.root.appendingPathComponent("outside")
    try Data("UNTOUCHED".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
    XCTAssertThrowsError(try PrivateFiles.appendRotating(Data("new\n".utf8), to: file, maxBytes: 10))
    XCTAssertEqual(try Data(contentsOf: external).string, "UNTOUCHED")
  }

  func testSessionResumeAndCrashRecoveryPreservePriorFacts() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f), run = UUID(), call = UUID()
    try s.startSession(run)
    try s.recordCallStarted(runID: run, id: call, tool: "read_files", action: nil, startedAt: Date(), source: nil)
    try s.pauseSession(run)
    try s.startSession(run)
    XCTAssertEqual(try s.session(run).visits, 2)
    XCTAssertEqual(try s.session(run).toolCallCount, 1)
    let next = UUID()
    try s.startSession(next)
    let previous = try s.session(run)
    XCTAssertEqual(previous.status, "interrupted")
    XCTAssertEqual(previous.calls.first?.status, "interrupted")
    XCTAssertNotNil(previous.finishedAt)
    XCTAssertEqual(try s.sessionJournals().count, 2)
  }

  func testSessionRetentionPrunesOldestWithoutDeletingMemory() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try remember(s)
    var oldest: UUID?
    for index in 0..<102 {
      let id = UUID(), date = Date(timeIntervalSince1970: Double(index + 1000))
      if index == 0 { oldest = id }
      let journal = SessionJournal(runId: id, projectKey: s.projectKey, startedAt: date,
                                   updatedAt: date, finishedAt: date, status: "completed")
      try PrivateFiles.atomicWrite(ContextCoding.encode(journal),
        to: s.sessionsDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json"))
    }
    let current = UUID()
    try s.startSession(current)
    let journals = try s.sessionJournals()
    XCTAssertEqual(journals.count, 100)
    XCTAssertFalse(journals.contains { $0.runId == oldest })
    XCTAssertTrue(journals.contains { $0.runId == current })
    XCTAssertEqual(try s.recall()["totalMatches"], 1)
  }

  func testActivityCompletionKeepsOriginalProjectAfterSwitch() async throws {
    let f = try Fixture(); defer { f.remove() }
    let a = f.contextDataRoot.appendingPathComponent("a/activity")
    let b = f.contextDataRoot.appendingPathComponent("b/activity")
    let activity = ActivityStore(persistenceDirectory: a)
    let id = await activity.begin(tool: "read_files", targetType: "file", target: "a.txt")
    XCTAssertEqual(LocalLogStore.recentActivities(limit: 20, directory: a).first?.status, "running")
    await activity.setPersistenceDirectory(b)
    await activity.finish(id: id, status: "ok", started: Date(), summary: "Read metadata")
    XCTAssertEqual(LocalLogStore.recentActivities(limit: 20, directory: a).first?.status, "ok")
    XCTAssertTrue(LocalLogStore.recentActivities(limit: 20, directory: b).isEmpty)
    let visible = await activity.snapshot()
    XCTAssertTrue(visible.isEmpty)
  }

  func testRouterTwoHostsShareMemoryButCannotForgeSourceOrPurge() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    func grant(_ name: String, _ scopes: Set<OAuthScope>) -> ToolGrant {
      .remote(RequestContext(transport: .cloudflare, clientID: name, clientName: name, authorizationID: UUID(),
                             scopes: scopes, resource: "https://fixture.invalid/mcp"))
    }
    let writer = grant("Writer Host", [.projectWrite]), reader = grant("Reader Host", [.projectRead])
    let write = await router.call("memory", arguments: ["action": "remember", "kind": "decision", "content": "Shared project fact"], grant: writer)
    XCTAssertFalse(write.isError)
    XCTAssertEqual(write.data["memory"]["source"]["host"], "Writer Host")
    let recalled = await router.call("memory", arguments: ["action": "recall"], grant: reader)
    XCTAssertEqual(recalled.data["totalMatches"], 1)
    let denied = await router.call("memory", arguments: ["action": "remember", "kind": "decision", "content": "not allowed"], grant: reader)
    XCTAssertEqual(denied.data["error"], "insufficient_scope")
    for args: JSONValue in [
      ["action": "clear"], ["action": "purge"], ["action": "recent", "projectId": "other"],
      ["action": "remember", "kind": "goal", "content": "forged", "source": ["host": "Someone Else"]]
    ] {
      let output = await router.call("memory", arguments: args)
      XCTAssertTrue(output.isError)
    }
    await router.stop()
  }

  func testProjectSwitchRoundTripResumesSameSessionAndIsolatesRecall() async throws {
    let a = try Fixture(), b = try Fixture(); defer { a.remove(); b.remove() }
    let pa = ApprovedProject(id: "a", url: a.root), pb = ApprovedProject(id: "b", url: b.root)
    let activity = ActivityStore()
    let router = try ToolRouter(workspace: a.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: activity, executionPolicy: .readOnly,
      approvedProjects: [pa, pb], activeProjectID: "a", helper: Fixture.helper, contextDataRoot: a.contextDataRoot)
    let first = await router.call("memory", arguments: ["action": "remember", "kind": "goal", "content": "Only in project A"])
    XCTAssertFalse(first.isError)
    let toB = await router.call("projects", arguments: ["action": "switch", "projectId": "b"])
    XCTAssertFalse(toB.isError)
    let recallB = await router.call("memory", arguments: ["action": "recall"])
    XCTAssertEqual(recallB.data["totalMatches"], 0)
    let toA = await router.call("projects", arguments: ["action": "switch", "projectId": "a"])
    XCTAssertFalse(toA.isError)
    let recallA = await router.call("memory", arguments: ["action": "recall"])
    XCTAssertEqual(recallA.data["totalMatches"], 1)
    await router.stop()
    let sa = try store(a, project: pa)
    let sb = try ProjectContextStore(project: pb, dataRoot: a.contextDataRoot)
    XCTAssertEqual(try sa.sessionJournals().count, 1)
    XCTAssertEqual(try sb.sessionJournals().count, 1)
    XCTAssertEqual(try sa.session(activity.runID).visits, 2)
    XCTAssertEqual(try sa.session(activity.runID).status, "completed")
    XCTAssertEqual(try sa.session(activity.runID).tools["memory"], 2)
    XCTAssertEqual(try sb.session(activity.runID).tools["memory"], 1)
  }

  func testVerifiedJournalDoesNotPersistFileBodiesOrProcessArguments() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("input.txt", "PRIVATE_BODY_FIXTURE")
    let router = try f.router(execution: true)
    let read = await router.call("read_files", arguments: ["paths": ["input.txt"]])
    XCTAssertFalse(read.isError)
    let dry = await router.call("edit_files", arguments: ["action": "create", "path": "dry.txt", "content": "DRY_CONTENT_FIXTURE", "dryRun": true])
    XCTAssertFalse(dry.isError)
    let created = await router.call("edit_files", arguments: ["action": "create", "path": "actual.txt", "content": "PRIVATE_CREATED_FIXTURE"])
    XCTAssertFalse(created.isError)
    let exported = await router.call("export_artifact", arguments: ["path": "actual.txt"])
    XCTAssertFalse(exported.isError)
    let process = await router.call("run_process", arguments: ["program": "/bin/echo", "args": ["PRIVATE_ARGV_AND_STDOUT_FIXTURE"], "syncWait": 2])
    XCTAssertFalse(process.isError)
    await router.stop()
    let s = try store(f)
    let journal = try XCTUnwrap(s.sessionJournals().first)
    XCTAssertEqual(journal.readFiles, ["input.txt"])
    XCTAssertTrue(journal.touchedFiles.contains("actual.txt"))
    XCTAssertFalse(journal.touchedFiles.contains("dry.txt"))
    XCTAssertTrue(journal.calls.contains {
      $0.tool == "edit_files" && $0.action == "create"
        && $0.checkpointId?.hasPrefix("chk_") == true
    })
    XCTAssertEqual(journal.commands.first?.program, "echo")
    XCTAssertEqual(journal.artifacts.count, 1)
    XCTAssertEqual(journal.jobs.first?.status, "completed")
    let persisted = try ContextCoding.encode(journal).string
    let activity = try ContextCoding.encode(LocalLogStore.recentActivities(limit: 200, directory: s.activityDirectory)).string
    for marker in ["PRIVATE_BODY_FIXTURE", "DRY_CONTENT_FIXTURE", "PRIVATE_CREATED_FIXTURE", "PRIVATE_ARGV_AND_STDOUT_FIXTURE"] {
      XCTAssertFalse(persisted.contains(marker), marker)
      XCTAssertFalse(activity.contains(marker), marker)
    }
  }

  func testDiscoveredTaskPersistsOnlyTaskProvenanceInSessionCommand() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(
      "package.json",
      #"{"scripts":{"test":"/bin/echo TASK_BODY_NOT_FOR_JOURNAL"}}"#)
    let router = try f.router(execution: true)

    let output = await router.call(
      "run_process",
      arguments: ["taskId": "task:test", "syncWait": 3, "timeout": 20])
    XCTAssertFalse(output.isError)
    await router.stop()

    let s = try store(f)
    let journal = try XCTUnwrap(s.sessionJournals().first)
    let command = try XCTUnwrap(journal.commands.first)
    XCTAssertEqual(command.taskId, "task:test")
    XCTAssertEqual(command.program, "npm")
    XCTAssertEqual(command.purpose, "test")
    let persisted = try ContextCoding.encode(journal).string
    XCTAssertFalse(persisted.contains("TASK_BODY_NOT_FOR_JOURNAL"))
    XCTAssertTrue(persisted.contains("task:test"))
  }

  func testSessionPersistsStructuredDiagnosticsWithoutRawProcessOutput() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/app.ts", "const value = 1")
    let router = try f.router(execution: true, permissionMode: .fullProjectAccess)
    let output = await router.call(
      "run_process",
      arguments: [
        "program": "/bin/sh",
        "args": [
          "-c",
          "printf '%s\\n' RAW_STDOUT_NOT_FOR_SESSION; printf '%s\\n' 'src/app.ts(6,4): error TS2322: Type mismatch' >&2; exit 1",
        ],
        "syncWait": 3,
      ])
    XCTAssertTrue(output.isError)
    XCTAssertEqual(output.data["diagnosticSummary"]["count"], 1)
    await router.stop()

    let s = try store(f)
    let journal = try XCTUnwrap(s.sessionJournals().first)
    let diagnostic = try XCTUnwrap(journal.diagnostics.first)
    XCTAssertEqual(diagnostic.file, "src/app.ts")
    XCTAssertEqual(diagnostic.line, 6)
    XCTAssertEqual(diagnostic.column, 4)
    XCTAssertEqual(diagnostic.severity, "error")
    XCTAssertEqual(diagnostic.code, "TS2322")
    XCTAssertEqual(diagnostic.source, "tsc")
    let persisted = try ContextCoding.encode(journal).string
    XCTAssertFalse(persisted.contains("RAW_STDOUT_NOT_FOR_SESSION"))
    XCTAssertTrue(persisted.contains("Type mismatch"))
  }

  func testAsyncJobReconciliationKeepsFailureAndParsedCounts() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f), run = UUID(), call = UUID(), start = Date()
    try s.startSession(run)
    try s.recordCallStarted(runID: run, id: call, tool: "run_process", action: nil, startedAt: start, source: nil)
    let initial = ActivityEvent(id: call, runID: run, startedAt: start, tool: "run_process", target: "swift", status: "ok",
      operationState: "running", summary: "Job started", jobID: "job_fixture", durationSeconds: 0)
    try s.recordCallFinished(runID: run, event: initial, arguments: ["program": "swift", "args": ["test"]],
      output: ToolOutput(["jobId": "job_fixture", "status": "running", "terminal": false]))
    let terminal: JSONValue = ["jobId": "job_fixture", "status": "failed", "terminal": true, "exitCode": 1,
                              "testSummary": ["passed": 8, "failed": 2, "skipped": 1], "stdoutTail": "NOT_FOR_JOURNAL"]
    // A successful job_query has already recorded this terminal state. Reconciliation
    // must still finish the original command, without failing the observation call.
    let observationID = UUID()
    let observed = ActivityEvent(id: observationID, runID: run, startedAt: start, finishedAt: Date(),
      tool: "job_query", action: "status", target: "job_fixture", status: "ok",
      summary: "Job observed", jobID: "job_fixture", durationSeconds: 0)
    try s.recordCallFinished(runID: run, event: observed, arguments: ["action": "status"], output: ToolOutput(terminal))
    try s.reconcileSessionJobs([terminal], runID: run)
    try s.reconcileSessionJobs([terminal], runID: run)
    let journal = try s.session(run)
    XCTAssertEqual(journal.failedCallCount, 1)
    XCTAssertEqual(journal.calls.first?.errorCode, "job_failed")
    XCTAssertEqual(journal.calls.last?.status, "ok")
    XCTAssertNil(journal.calls.last?.errorCode)
    XCTAssertEqual(journal.jobs.first?.tests?.failed, 2)
    XCTAssertEqual(journal.jobs.first?.exitCode, 1)
    XCTAssertEqual(journal.calls.first?.status, "failed")
    XCTAssertFalse(try ContextCoding.encode(journal).string.contains("NOT_FOR_JOURNAL"))
    XCTAssertEqual(try s.sessionsResult(runID: run, limit: 1, offset: 0)["tests"].array?.count, 1)
  }

  func testLocalClearIsScopedAndBlockedWhileRuntimeActive() async throws {
    let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
    try f.write("source.swift", "SOURCE_SURVIVES")
    let project = ApprovedProject(url: f.root), s = try store(f)
    let peer = try ProjectContextStore(project: ApprovedProject(url: other.root), dataRoot: f.contextDataRoot)
    try remember(s); try remember(peer, "Other project survives")
    let run = UUID(); try s.startSession(run); try s.finishSession(run)
    let auth = f.contextDataRoot.appendingPathComponent("auth/fixture-metadata.json")
    try PrivateFiles.atomicWrite(Data("AUTH_METADATA_SURVIVES".utf8), to: auth)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.approvedProjects = [project]; model.activeProjectID = project.id
    model.phase = .running
    do { try await model.clearProjectContext(project, selection: .all); XCTFail("Running context must not be cleared.") } catch {}
    XCTAssertEqual(try s.recall()["totalMatches"], 1)
    model.phase = .stopped
    try await model.clearProjectContext(project, selection: .memory)
    XCTAssertEqual(try s.recall()["totalMatches"], 0)
    XCTAssertEqual(try s.sessionJournals().count, 1)
    try await model.clearProjectContext(project, selection: .all)
    XCTAssertTrue(try s.sessionJournals().isEmpty)
    XCTAssertEqual(model.approvedProjects, [project])
    XCTAssertEqual(try peer.recall()["totalMatches"], 1)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("source.swift")).string, "SOURCE_SURVIVES")
    XCTAssertEqual(try PrivateFiles.read(auth, max: 4096).string, "AUTH_METADATA_SURVIVES")
  }

  func testPrivateContextCannotBeSelectedOrReadAsSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".luti/projects/private.txt", "NOT_SOURCE")
    XCTAssertThrowsError(try WorkspaceFiles(root: f.root.appendingPathComponent(".luti")))
    XCTAssertTrue(WorkspaceFiles.protected(".luti/projects/private.txt"))
    do { _ = try await f.files.text(".luti/projects/private.txt"); XCTFail("Private app data is not source.") } catch {}
  }

  func testRecentIncludesJSONEscapingInItsByteBudget() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for i in 0..<5 { try remember(s, "Fact \(i) " + String(repeating: "\u{01}", count: 1600)) }
    let recent = try s.recent()
    XCTAssertLessThanOrEqual(try recent.data().count, 32_768)
    XCTAssertEqual(recent["memoriesTruncated"], true)
    XCTAssertLessThan(recent["memories"].array!.count, 5)
  }

  func testStopDrainsCallsAndCannotRecreateClearedContext() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    let running = Task {
      await router.call("run_process", arguments: ["program": "/bin/sleep", "args": ["5"], "syncWait": 3])
    }
    var sawRunning = false
    for _ in 0..<100 {
      if await router.jobList().contains(where: { $0["terminal"] != true }) { sawRunning = true; break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(sawRunning)
    async let firstStop: Void = router.stop()
    async let secondStop: Void = router.stop()
    _ = await (firstStop, secondStop)
    _ = await running.value
    let s = try store(f)
    let finished = try XCTUnwrap(s.sessionJournals().first)
    XCTAssertNotNil(finished.finishedAt)
    XCTAssertFalse(finished.calls.contains { $0.status == "running" })
    try s.clear(.all)
    let refused = await router.call("memory", arguments: ["action": "recent"])
    XCTAssertTrue(refused.isError)
    _ = await router.jobList()
    await router.stop()
    XCTAssertTrue(try s.sessionJournals().isEmpty)
    XCTAssertTrue(LocalLogStore.recentActivities(limit: 20, directory: s.activityDirectory).isEmpty)
  }

  func testRenderContextMemoryAndSessions() throws {
    let f = try Fixture(); defer { f.remove() }
    let project = ApprovedProject(name: "Project context", url: f.root), s = try store(f)
    try remember(s, "记忆按项目隔离，Host 仅记录来源。切换项目时继续使用同一个会话 ID。")
    let run = UUID(); try s.startSession(run); try s.finishSession(run)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.approvedProjects = [project]; model.activeProjectID = project.id
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let output = repo.appendingPathComponent("build/ui-review-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let language = LanguageSettings.shared, prior = LanguageSettings.shared.selection
    defer { language.selection = prior }
    for locale in AppLanguage.allCases where locale != .system {
      language.selection = locale
      for selection in [ProjectContextSelection.memory, .sessions] {
        let root = ProjectContextBrowser(model: model, project: project, selection: selection, back: {})
          .frame(width: 460, height: 640).environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 640)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: output.appendingPathComponent("context-" + selection.rawValue + "-" + locale.rawValue + ".png"))
      }
    }
  }
}

private extension Data {
  var string: String { String(decoding: self, as: UTF8.self) }
}
