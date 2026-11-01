import XCTest

@testable import Luti

private actor SelectionPause {
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var entered = false
  func pause() async {
    entered = true
    await withCheckedContinuation { waiter = $0 }
  }
  func resume() { waiter?.resume(); waiter = nil }
}

@MainActor final class ProjectBindingTests: XCTestCase {
  private func grant(_ host: String = "OpenAI") -> ToolGrant {
    .remote(RequestContext(transport: .openAI, clientID: host, clientName: host, authorizationID: UUID()))
  }

  func testReplacingFolderInvalidatesBothHostsOldBinding() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let old = try first.router(execution: true)
    let token = await old.projectToken
    await old.stop()
    let current = try second.router(execution: true)
    addTeardownBlock { await current.stop() }
    for host in ["A", "B"] {
      let permission = grant(host)
      for (name, arguments): (String, JSONValue) in [
        ("edit_files", ["action": "create", "path": "wrong.txt", "content": "wrong"]),
        ("run_process", ["program": "/usr/bin/touch", "args": ["wrong.txt"]]),
      ] {
        let result = await current.call(name, arguments: arguments.adding("projectToken", .string(token)), grant: permission)
        XCTAssertEqual(result.data["error"], "project_binding_mismatch")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.root.appendingPathComponent("wrong.txt").path))
    let fresh = await current.projectToken
    XCTAssertNotEqual(fresh, token)
  }

  func testMissingBindingCannotMutateAndRestartInvalidatesBinding() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router(execution: true)
    let before = await router.call("project_info", arguments: [:])
    let missing = await router.call("edit_files", arguments: ["action": "create", "path": "missing.txt", "content": "x"])
    XCTAssertEqual(missing.data["error"], "project_binding_required")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("missing.txt").path))
    let allowed = await router.call("edit_files", arguments: ["action": "create", "path": "ok.txt", "content": "x", "projectToken": before.data["projectToken"]])
    XCTAssertFalse(allowed.isError)
    await router.stop()
    let restarted = try ToolRouter(workspace: WorkspaceFiles(root: f.root), jobs: JobManager(helper: Fixture.helper),
      activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: true), contextDataRoot: f.contextDataRoot)
    let stale = await restarted.call("run_process", arguments: ["program": "/usr/bin/true", "projectToken": before.data["projectToken"]])
    XCTAssertEqual(stale.data["error"], "project_binding_mismatch")
    await restarted.stop()
  }

  func testReadsNeitherAdvertiseNorCheckProjectTokens() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("a.txt", "a")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    for definition in ToolCatalog.definitions {
      let name = try XCTUnwrap(definition["name"].string)
      let advertised = definition["inputSchema"]["properties"]["projectToken"] != .null
      XCTAssertEqual(advertised, !ToolCatalog.readOnlyNames.contains(name), name)
    }
    let read = await router.call("read_files", arguments: ["paths": ["a.txt"], "projectToken": "stale"])
    XCTAssertFalse(read.isError, "A token from an older tool list must not block reads.")
  }

  func testStaleBindingCannotBlockStop() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router(execution: true)
    let token = await router.projectToken
    let job = await router.call("run_process", arguments: ["program": "/bin/sleep", "args": ["10"], "syncWait": 0, "projectToken": .string(token)])
    XCTAssertFalse(job.isError)
    let stopped = await router.call("job_action", arguments: ["action": "stop", "jobId": job.data["jobId"], "projectToken": "stale"])
    XCTAssertFalse(stopped.isError)
    await router.stop()
  }

  func testProjectInfoReturnsDetailsForLocalAndDelegatedCallers() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    for caller in [ToolGrant.local, grant()] {
      let current = await router.call("project_info", arguments: [:], grant: caller)
      XCTAssertFalse(current.isError)
      XCTAssertEqual(current.data["root"], .string(f.root.path))
      XCTAssertNotNil(current.data["name"].string)
      XCTAssertNotNil(current.data["entries"].array)
      XCTAssertNotNil(current.data["projectToken"].string)
    }
    await router.stop()
  }

  private func router(_ first: Fixture, _ projects: [ApprovedProject]) throws -> ToolRouter {
    try ToolRouter(workspace: WorkspaceFiles(root: first.root), jobs: JobManager(helper: Fixture.helper),
      activity: ActivityStore(), executionPolicy: .fullLocal(localApproval: true),
      project: projects[0], helper: Fixture.helper, contextDataRoot: first.contextDataRoot,
      approvedProjects: projects)
  }

  func testApprovedListAndInvalidSelectionDoNotChangeTheWorkspace() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    let info = await router.call("project_info", arguments: [:], grant: grant())
    XCTAssertEqual(info.data["projects"].array?.map { $0["projectId"] }, [.string(a.id), .string(b.id)])
    XCTAssertEqual(info.data["projects"].array?.map { $0["selected"] }, [true, false])
    for (arguments, error): (JSONValue, String) in [
      (["projectId": .string(b.id)], "project_binding_required"),
      (["projectId": .string(b.id), "projectToken": "stale"], "project_binding_mismatch"),
      (["projectId": .string(second.root.path), "projectToken": info.data["projectToken"]], "project_not_found"),
    ] {
      let result = await router.call("project_select", arguments: arguments, grant: grant())
      XCTAssertEqual(result.data["error"], .string(error))
    }
    let unchanged = await router.call("project_info", arguments: [:])
    XCTAssertEqual(unchanged.data["projectToken"], info.data["projectToken"])
    XCTAssertEqual(unchanged.data["root"], .string(first.root.path))
  }

  func testSwitchSeparatesFilesMemoryActivityArtifactsAndInvalidatesEveryClientsToken() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let a = ApprovedProject(url: first.root, permissionMode: .fullProjectAccess)
    let b = ApprovedProject(url: second.root)
    for project in [a, b] {
      let memory = try ProjectMemoryStore(project: project, dataRoot: first.contextDataRoot)
      _ = try memory.write(file: "decision.md", name: project.name, description: "Scoped decision",
        kind: .decision, content: project.id, source: .model(grant: .local, redactor: Redactor()))
    }
    try first.write("only-a.txt", "a")
    try second.write("only-b.txt", "b")
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    let old = await router.call("project_info", arguments: [:])
    let created = await router.callInCurrentProject("edit_files", arguments: [
      "action": "create", "path": "a-created.txt", "content": "a"])
    XCTAssertFalse(created.isError)
    let artifact = try await router.artifacts.insert(Data("a".utf8), name: "a.txt")
    let oldBrowser = await router.browser
    let selected = await router.call("project_select", arguments: [
      "projectId": .string(b.id), "projectToken": old.data["projectToken"]], grant: grant("A"))
    XCTAssertFalse(selected.isError, selected.data.text())
    XCTAssertEqual(selected.data["changed"], true)
    XCTAssertEqual(selected.data["root"], .string(second.root.path))
    XCTAssertEqual(selected.data["permissionMode"], "ask")
    XCTAssertEqual(selected.data["generation"], 2)
    XCTAssertNotEqual(selected.data["projectToken"], old.data["projectToken"])
    XCTAssertTrue(selected.data["recentActivity"].array?.isEmpty == true)
    let memory = await router.call("memory_query", arguments: ["action": "read", "file": "decision.md"])
    XCTAssertEqual(memory.data["memory"]["content"], .string(b.id))
    for host in ["A", "B"] {
      let stale = await router.call("edit_files", arguments: ["action": "create", "path": "wrong.txt",
        "content": "wrong", "projectToken": old.data["projectToken"]], grant: grant(host))
      XCTAssertEqual(stale.data["error"], "project_binding_mismatch")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.root.appendingPathComponent("wrong.txt").path))
    do { _ = try await router.readResource(artifact.uri); XCTFail("Old artifacts must not cross projects.") }
    catch let error as Failure { XCTAssertEqual(error.code, "resource_not_found") }
    do { _ = try await oldBrowser.call("browser_tabs", [:]); XCTFail("The previous browser context must be closed.") }
    catch let error as Failure { XCTAssertEqual(error.code, "runtime_stopped") }
    let tabs = await router.call("browser_observe", arguments: ["action": "tabs"])
    XCTAssertEqual(tabs.data["tabs"], [])
    let returned = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(a.id)])
    XCTAssertFalse(returned.isError)
    XCTAssertEqual(returned.data["permissionMode"], "fullProjectAccess")
    XCTAssertEqual(returned.data["generation"], 3)
    XCTAssertNotEqual(returned.data["projectToken"], old.data["projectToken"])
    let recent = returned.data["recentActivity"].array ?? []
    XCTAssertTrue(recent.contains { $0["target"] == "a-created.txt" })
    XCTAssertFalse(recent.contains { $0["error"] == "project_binding_mismatch" })
    let read = await router.call("read_files", arguments: ["paths": ["only-a.txt"]])
    XCTAssertEqual(read.data["files"].array?.first?["content"], "a")
  }

  func testRunningJobPreventsSwitchWithoutStoppingItAndSameProjectIsANoop() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let a = ApprovedProject(url: first.root, permissionMode: .fullProjectAccess)
    let b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    let token = await router.projectToken
    let job = await router.callInCurrentProject("run_process", arguments: [
      "program": "/bin/sleep", "args": ["30"], "syncWait": 0])
    XCTAssertFalse(job.isError, job.data.text())
    let same = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(a.id)])
    XCTAssertEqual(same.data["changed"], false)
    XCTAssertEqual(same.data["projectToken"], .string(token))
    let blocked = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertEqual(blocked.data["error"], "project_busy")
    let status = await router.call("job_query", arguments: ["action": "status", "jobId": job.data["jobId"]])
    XCTAssertEqual(status.data["terminal"], false)
    XCTAssertEqual(status.data["status"], "running")
    let stopped = await router.call("job_action", arguments: ["action": "stop", "jobId": job.data["jobId"]])
    XCTAssertFalse(stopped.isError)
    let selected = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertFalse(selected.isError, selected.data.text())
    let oldJob = await router.call("job_query", arguments: ["action": "status", "jobId": job.data["jobId"]])
    XCTAssertEqual(oldJob.data["error"], "job_not_found")
  }

  func testPendingOperationCannotBeMovedIntoAnotherProject() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    try first.write("victim.txt", "a")
    try second.write("victim.txt", "b")
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    let call = Task { await router.callInCurrentProject("path_action", arguments: ["action": "delete", "path": "victim.txt"]) }
    var pending: PendingOperationApproval?
    for _ in 0..<300 {
      pending = await router.pendingOperationApprovals().first
      if pending != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let approval = try XCTUnwrap(pending)
    let blocked = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertEqual(blocked.data["error"], "project_busy")
    await router.resolveOperationApproval(approval.id, approved: true)
    let result = await call.value
    XCTAssertFalse(result.isError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.appendingPathComponent("victim.txt").path))
    XCTAssertEqual(try String(contentsOf: second.root.appendingPathComponent("victim.txt"), encoding: .utf8), "b")
  }

  func testUnavailableDestinationLeavesCurrentContextUsable() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    try first.write("a.txt", "a")
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    let token = await router.projectToken
    try FileManager.default.removeItem(at: second.root)
    let selected = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertTrue(selected.isError)
    let current = await router.call("project_info", arguments: [:])
    XCTAssertEqual(current.data["projectToken"], .string(token))
    let read = await router.call("read_files", arguments: ["paths": ["a.txt"]])
    XCTAssertFalse(read.isError)
  }

  func testInactiveProjectsLatestPermissionIsAppliedOnSelection() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    await router.setPermissionMode(.fullProjectAccess, for: b.id)
    let selected = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertEqual(selected.data["permissionMode"], "fullProjectAccess")
    let status = await router.call("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["permissionMode"], "fullProjectAccess")
  }

  func testStartupUsesTheApprovedListsLatestPermission() async throws {
    let f = try Fixture(); defer { f.remove() }
    let selected = ApprovedProject(url: f.root)
    let updated = selected.withPermissionMode(.fullProjectAccess)
    let router = try ToolRouter(workspace: WorkspaceFiles(root: f.root), jobs: JobManager(helper: Fixture.helper),
      activity: ActivityStore(), project: selected, contextDataRoot: f.contextDataRoot, approvedProjects: [updated])
    addTeardownBlock { await router.stop() }
    let info = await router.call("project_info", arguments: [:])
    XCTAssertEqual(info.data["permissionMode"], "fullProjectAccess")
    XCTAssertEqual(info.data["projects"].array?.first?["permissionMode"], "fullProjectAccess")
  }

  func testCallsAndSecondSelectionCannotEnterWhileSelectionIsCommitting() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let pause = SelectionPause()
    let router = try ToolRouter(workspace: WorkspaceFiles(root: first.root), jobs: JobManager(helper: Fixture.helper),
      activity: ActivityStore(), executionPolicy: .fullLocal(localApproval: true), project: a,
      helper: Fixture.helper, contextDataRoot: first.contextDataRoot, approvedProjects: [a, b],
      onProjectSelected: { _ in await pause.pause() })
    addTeardownBlock { await pause.resume(); await router.stop() }
    let selection = Task { await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)]) }
    for _ in 0..<300 {
      if await pause.entered { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let entered = await pause.entered
    XCTAssertTrue(entered)
    for (name, args): (String, JSONValue) in [
      ("project_select", ["projectId": .string(a.id)]),
      ("edit_files", ["action": "create", "path": "raced.txt", "content": "x"]),
      ("project_info", [:]),
    ] {
      let blocked = await router.callInCurrentProject(name, arguments: args)
      XCTAssertEqual(blocked.data["error"], "project_busy")
    }
    await pause.resume()
    let selected = await selection.value
    XCTAssertFalse(selected.isError)
    XCTAssertEqual(selected.data["root"], .string(second.root.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.appendingPathComponent("raced.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.root.appendingPathComponent("raced.txt").path))
  }

  func testApprovedPathReplacedBySymlinkCannotSelectAnUnapprovedFolder() async throws {
    let first = try Fixture(), second = try Fixture(), outside = try Fixture()
    defer { first.remove(); second.remove(); outside.remove() }
    let a = ApprovedProject(url: first.root), b = ApprovedProject(url: second.root)
    let router = try router(first, [a, b])
    addTeardownBlock { await router.stop() }
    try FileManager.default.removeItem(at: second.root)
    try FileManager.default.createSymbolicLink(at: second.root, withDestinationURL: outside.root)
    let result = await router.callInCurrentProject("project_select", arguments: ["projectId": .string(b.id)])
    XCTAssertEqual(result.data["error"], "path_outside_workspace")
    let current = await router.call("project_info", arguments: [:])
    XCTAssertEqual(current.data["root"], .string(first.root.path))
  }
}
