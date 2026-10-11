import XCTest

@testable import Luti

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
}
