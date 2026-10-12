import XCTest
@testable import Luti

@MainActor final class ProjectActivityTests: XCTestCase {
  func testRuntimePersistsOnlyActivity() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    _ = await router.callInCurrentProject("edit_files", arguments: ["action": "create", "path": "source.txt", "content": "x"])
    await router.stop()
    let namespace = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot).deletingLastPathComponent()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: namespace.path), ["activity"])
  }

  func testRemovedToolsAreRejectedByLocalAndRemoteRouter() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let remote = ToolGrant.remote(RequestContext(transport: .openAI, clientID: "openai-tunnel",
      clientName: "Host", authorizationID: UUID()))
    for permission in [ToolGrant.local, remote] {
      for tool in ["projects", "memory", "skills"] {
        let result = await router.call(tool, arguments: ["action": "list"], grant: permission)
        XCTAssertTrue(result.isError)
      }
    }
  }

  func testActivityClearIsScopedAndBlockedWhileRuntimeActive() async throws {
    let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
    let event = ActivityEvent(id: UUID(), startedAt: Date(), finishedAt: Date(), tool: "read_files",
      target: "source.txt", status: "ok", summary: "Read", durationSeconds: 0)
    let own = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot)
    let peer = LocalLogStore.activityDirectory(for: other.root, dataRoot: f.contextDataRoot)
    LocalLogStore.appendActivity(event, directory: own)
    LocalLogStore.appendActivity(event, directory: peer)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    let selected = try XCTUnwrap(model.activeProject)
    model.phase = .running
    do { try await model.clearProjectActivity(selected); XCTFail("Running activity cannot be cleared") } catch {}
    XCTAssertFalse(LocalLogStore.recentActivities(limit: 10, directory: own).isEmpty)
    model.phase = .stopped
    try await model.clearProjectActivity(selected)
    XCTAssertTrue(model.activity.isEmpty)
    XCTAssertEqual(model.activeProject, selected)
    XCTAssertEqual(LocalLogStore.recentActivities(limit: 10, directory: peer).map(\.id), [event.id])
  }

  func testPrivateActivityPermissionsAndLinkRefusal() throws {
    let f = try Fixture(); defer { f.remove() }
    let directory = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot)
    let file = directory.appendingPathComponent("activity.jsonl")
    try PrivateFiles.atomicWrite(Data("x".utf8), to: file)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let external = f.root.appendingPathComponent("outside")
    try Data("UNTOUCHED".utf8).write(to: external)
    for name in ["symbolic", "hard"] {
      let link = directory.appendingPathComponent(name)
      if name == "symbolic" { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external) }
      else { try FileManager.default.linkItem(at: external, to: link) }
      XCTAssertThrowsError(try PrivateFiles.atomicWrite(Data(), to: link))
      XCTAssertThrowsError(try PrivateFiles.read(link, max: 4096))
    }
    let linkedParent = f.root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: directory)
    XCTAssertThrowsError(try PrivateFiles.atomicWrite(Data(), to: linkedParent.appendingPathComponent("new")))
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "UNTOUCHED")
  }

  func testStopDrainsCallsAndCannotRecreateClearedActivity() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    let running = Task {
      await router.callInCurrentProject("run_process", arguments: ["program": "/bin/sleep", "args": ["5"], "syncWait": 3])
    }
    var started = false
    for _ in 0..<100 {
      if await router.jobList().contains(where: { $0["terminal"] != true }) { started = true; break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(started)
    async let first: Void = router.stop()
    async let second: Void = router.stop()
    _ = await (first, second)
    _ = await running.value
    let directory = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot)
    try LocalLogStore.clearActivities(directory: directory)
    let refused = await router.call("runtime_status", arguments: [:])
    XCTAssertTrue(refused.isError)
    _ = await router.jobList()
    await router.stop()
    XCTAssertTrue(LocalLogStore.recentActivities(limit: 10, directory: directory).isEmpty)
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

  func testLogRotationIsBoundedAndDoesNotFollowLinks() throws {
    let f = try Fixture(); defer { f.remove() }
    let dir = f.contextDataRoot.appendingPathComponent("logs")
    let file = dir.appendingPathComponent("runtime.log")
    try PrivateFiles.appendRotating(Data("first\n".utf8), to: file, maxBytes: 10)
    try PrivateFiles.appendRotating(Data("second\n".utf8), to: file, maxBytes: 10)
    XCTAssertEqual(String(decoding: try PrivateFiles.read(file, max: 10), as: UTF8.self), "second\n")
    XCTAssertEqual(String(decoding: try PrivateFiles.read(dir.appendingPathComponent("runtime.log.1"), max: 10), as: UTF8.self), "first\n")
    try PrivateFiles.removeFile(file)
    let external = f.root.appendingPathComponent("outside")
    try Data("UNTOUCHED".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
    XCTAssertThrowsError(try PrivateFiles.appendRotating(Data("new\n".utf8), to: file, maxBytes: 10))
    XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "UNTOUCHED")
  }

  func testPrivateContextCannotBeSelectedOrReadAsSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(".luti/projects/private.txt", "NOT_SOURCE")
    XCTAssertThrowsError(try WorkspaceFiles(root: f.root.appendingPathComponent(".luti")))
    XCTAssertTrue(WorkspaceFiles.protected(".luti/projects/private.txt"))
    do { _ = try await f.files.text(".luti/projects/private.txt"); XCTFail("Private app data is not source.") } catch {}
  }

}
