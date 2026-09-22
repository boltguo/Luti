import XCTest

@testable import Luti

@MainActor final class ProjectBindingTests: XCTestCase {
  private func grant(_ scopes: Set<OAuthScope>) -> ToolGrant {
    .remote(RequestContext(transport: .cloudflare, clientID: "scope-fixture", clientName: "Scoped Host",
      authorizationID: UUID(), scopes: scopes, resource: "https://example.com/mcp"))
  }

  func testTwoHostsCannotWriteOrRunUsingOldProjectBinding() async throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let router = try ToolRouter(
      workspace: first.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: true),
      approvedProjects: [ApprovedProject(id: "a", url: first.root), ApprovedProject(id: "b", url: second.root)],
      activeProjectID: "a", helper: Fixture.helper, contextDataRoot: first.contextDataRoot)
    func host(_ id: String) -> ToolGrant {
      .remote(RequestContext(transport: .cloudflare, clientID: id, clientName: id,
        authorizationID: UUID(), scopes: Set(OAuthScope.allCases), resource: "https://example.com/mcp"))
    }
    let a = await router.call("project_info", arguments: [:], grant: host("A"))
    let tokenA = a.data["projectToken"]
    let switched = await router.call("projects", arguments: ["action": "switch", "projectId": "b", "projectToken": tokenA], grant: host("B"))
    XCTAssertFalse(switched.isError)
    for (name, arguments): (String, JSONValue) in [
      ("edit_files", ["action": "create", "path": "wrong.txt", "content": "wrong"]),
      ("run_process", ["program": "/usr/bin/touch", "args": ["wrong.txt"]]),
      ("memory", ["action": "remember", "kind": "goal", "content": "wrong project"]),
      ("projects", ["action": "switch", "projectId": "a"]),
    ] {
      let result = await router.call(name, arguments: arguments.adding("projectToken", tokenA), grant: host("A"))
      XCTAssertEqual(result.data["error"], "project_binding_mismatch", name)
      XCTAssertEqual(result.data["currentProject"]["projectId"], "b")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.root.appendingPathComponent("wrong.txt").path))
    let memory = await router.call("memory", arguments: ["action": "recall"])
    XCTAssertEqual(memory.data["totalMatches"], 0)
    let back = await router.call("projects", arguments: ["action": "switch", "projectId": "a", "projectToken": switched.data["projectToken"]])
    XCTAssertFalse(back.isError)
    XCTAssertNotEqual(back.data["projectToken"], tokenA)
    let oldRead = await router.call("read_files", arguments: ["paths": ["wrong.txt"], "projectToken": tokenA])
    XCTAssertEqual(oldRead.data["error"], "project_binding_mismatch")
    await router.stop()
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
      images: ImageStore(), computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: true), contextDataRoot: f.contextDataRoot)
    let stale = await restarted.call("run_process", arguments: ["program": "/usr/bin/true", "projectToken": before.data["projectToken"]])
    XCTAssertEqual(stale.data["error"], "project_binding_mismatch")
    await restarted.stop()
  }

  func testBindingDoesNotGrantPermissionAndCannotBlockStop() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router(execution: true)
    let token = await router.projectToken
    let reader = ToolGrant.remote(RequestContext(transport: .cloudflare, clientID: "reader", clientName: "Reader",
      authorizationID: UUID(), scopes: [.projectRead], resource: "https://example.com/mcp"))
    let denied = await router.call("edit_files", arguments: ["action": "create", "path": "no.txt", "content": "x", "projectToken": .string(token)], grant: reader)
    XCTAssertEqual(denied.data["error"], "insufficient_scope")
    let job = await router.call("run_process", arguments: ["program": "/bin/sleep", "args": ["10"], "syncWait": 0, "projectToken": .string(token)])
    XCTAssertFalse(job.isError)
    let stopped = await router.call("job_action", arguments: ["action": "stop", "jobId": job.data["jobId"], "projectToken": "stale"])
    XCTAssertFalse(stopped.isError)
    await router.stop()
  }

  func testIndependentProjectCapabilitiesDiscoverOnlyMinimalBinding() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("private.txt", "PRIVATE_PROJECT_CONTENT")
    let router = try f.router(execution: true)
    for scope in [OAuthScope.projectWrite, .processRun, .browserUse] {
      let delegated = grant([scope])
      let current = await router.call("projects", arguments: ["action": "current"], grant: delegated)
      XCTAssertFalse(current.isError, scope.rawValue)
      XCTAssertEqual(Set(current.data.object?.keys.map { $0 } ?? []), ["action", "generation", "projectToken", "project"])
      XCTAssertEqual(Set(current.data["project"].object?.keys.map { $0 } ?? []), ["id"])
      XCTAssertNotNil(current.data["projectToken"].string)
      XCTAssertNotNil(current.data["project"]["id"].string)
      XCTAssertFalse(current.data.text().contains(f.root.path))
      for (tool, arguments): (String, JSONValue) in [
        ("project_info", [:]), ("read_files", ["paths": ["private.txt"]]),
        ("memory", ["action": "recent"]), ("projects", ["action": "list"]),
        ("projects", ["action": "switch", "projectId": current.data["project"]["id"],
                      "projectToken": current.data["projectToken"]]),
      ] {
        let denied = await router.call(tool, arguments: arguments, grant: delegated)
        XCTAssertEqual(denied.data["error"], "insufficient_scope", "\(scope.rawValue): \(tool)")
      }
      switch scope {
      case .projectWrite:
        let saved = await router.call("memory", arguments: ["action": "remember", "kind": "goal",
          "content": "Write-only Host goal", "projectToken": current.data["projectToken"]], grant: delegated)
        XCTAssertFalse(saved.isError)
      case .processRun:
        let process = await router.call("run_process", arguments: ["program": "/usr/bin/true",
          "syncWait": 3, "projectToken": current.data["projectToken"]], grant: delegated)
        XCTAssertFalse(process.isError)
      case .browserUse:
        XCTAssertNoThrow(try delegated.authorize(tool: "browser_session", arguments: ["action": "open"]))
      default: XCTFail("Unexpected fixture scope")
      }
    }
    await router.stop()
  }

  func testCurrentProjectKeepsDetailsForReadScopeAndLocalCallers() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    for delegated in [ToolGrant.local, grant([.projectRead]), grant([.projectRead, .processRun])] {
      let current = await router.call("projects", arguments: ["action": "current"], grant: delegated)
      XCTAssertFalse(current.isError)
      XCTAssertEqual(current.data["project"]["path"], .string(f.root.path))
      XCTAssertNotNil(current.data["project"]["name"].string)
      XCTAssertNotNil(current.data["project"]["permissionMode"].string)
    }
    for scopes: Set<OAuthScope> in [[], [.computerRead], [.computerControl], [.computerRead, .computerControl]] {
      let denied = await router.call("projects", arguments: ["action": "current"], grant: grant(scopes))
      XCTAssertEqual(denied.data["error"], "insufficient_scope")
      XCTAssertEqual(denied.data["projectToken"], .null)
    }
    await router.stop()
  }

  func testMCPDiscoveryUsesSameActionAuthorizationAsCalls() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let bearer = String(repeating: "s", count: 64)
    let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
    let request = HTTPRequest(headers: [
      "Host": ["127.0.0.1:\(TunnelContract.defaultPort)"], "Authorization": ["Bearer " + bearer],
      "Content-Type": ["application/json"], "Accept": ["application/json, text/event-stream"],
    ], body: try body.data())
    for scopes: Set<OAuthScope> in [
      [.projectWrite], [.processRun], [.browserUse], [.projectRead], [.projectRead, .projectWrite],
      [.computerRead], [.computerControl], [],
    ] {
      let delegated = grant(scopes)
      let endpoint = MCPDispatcher(authentication: .delegated(bearer: bearer, context: delegated.context!),
                                   port: TunnelContract.defaultPort, router: router)
      let reply = await endpoint.handle(request)
      XCTAssertEqual(reply.status, 200)
      let definitions = try XCTUnwrap(reply.json["result"]["tools"].array)
      let projects = definitions.first { $0["name"] == "projects" }
      if scopes.contains(.projectRead) {
        XCTAssertEqual(projects?["inputSchema"]["properties"]["action"]["enum"],
          scopes.contains(.projectWrite) ? ["list", "current", "switch"] : ["list", "current"])
      } else if !scopes.isDisjoint(with: [.projectWrite, .processRun, .browserUse]) {
        XCTAssertEqual(projects?["inputSchema"]["properties"]["action"]["enum"], ["current"])
        XCTAssertNil(definitions.first { $0["name"] == "read_files" })
        XCTAssertNil(definitions.first { $0["name"] == "project_info" })
      } else {
        XCTAssertNil(projects)
      }
      let memory = definitions.first { $0["name"] == "memory" }
      if scopes == [.projectWrite] {
        XCTAssertEqual(memory?["inputSchema"]["properties"]["action"]["enum"], ["remember", "forget"])
      } else if scopes == [.projectRead] {
        XCTAssertEqual(memory?["inputSchema"]["properties"]["action"]["enum"], ["recall", "recent", "sessions"])
      }
      for definition in definitions {
        let name = try XCTUnwrap(definition["name"].string)
        for action in definition["inputSchema"]["properties"]["action"]["enum"].array ?? [] {
          XCTAssertNoThrow(try delegated.authorize(tool: name, arguments: ["action": action]))
        }
      }
      await endpoint.shutdown()
    }
    await router.stop()
  }
}
