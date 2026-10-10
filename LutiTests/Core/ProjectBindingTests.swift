import XCTest

@testable import Luti

@MainActor final class ProjectBindingTests: XCTestCase {
  private func grant(_ scopes: Set<OAuthScope>) -> ToolGrant {
    .remote(RequestContext(transport: .cloudflare, clientID: OAuthContract.newClientID(), clientName: "Scoped Host",
      authorizationID: UUID(), scopes: scopes, resource: "https://example.com/mcp"))
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
      let permission = ToolGrant.remote(RequestContext(transport: .cloudflare, clientID: host,
        clientName: host, authorizationID: UUID(), scopes: Set(OAuthScope.allCases),
        resource: "https://example.com/mcp"))
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
      let current = await router.call("project_info", arguments: [:], grant: delegated)
      XCTAssertFalse(current.isError, scope.rawValue)
      XCTAssertEqual(Set(current.data.object?.keys.map { $0 } ?? []), ["projectId", "generation", "projectToken"])
      XCTAssertNotNil(current.data["projectToken"].string)
      XCTAssertNotNil(current.data["projectId"].string)
      XCTAssertFalse(current.data.text().contains(f.root.path))
      XCTAssertFalse(current.data.text().contains("private.txt"))
      for (tool, arguments): (String, JSONValue) in [
        ("read_files", ["paths": ["private.txt"]]),
        ("runtime_status", [:]),
      ] {
        let denied = await router.call(tool, arguments: arguments, grant: delegated)
        XCTAssertEqual(denied.data["error"], "insufficient_scope", "\(scope.rawValue): \(tool)")
      }
      switch scope {
      case .projectWrite:
        let saved = await router.call("edit_files", arguments: ["action": "create", "path": "write-only.txt",
          "content": "Write-only Host file", "projectToken": current.data["projectToken"]], grant: delegated)
        XCTAssertFalse(saved.isError)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("write-only.txt"), encoding: .utf8), "Write-only Host file")
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

  func testProjectInfoKeepsDetailsForReadScopeAndLocalCallers() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    for delegated in [ToolGrant.local, grant([.projectRead]), grant([.projectRead, .processRun])] {
      let current = await router.call("project_info", arguments: [:], grant: delegated)
      XCTAssertFalse(current.isError)
      XCTAssertEqual(current.data["root"], .string(f.root.path))
      XCTAssertNotNil(current.data["name"].string)
      XCTAssertNotNil(current.data["entries"].array)
      XCTAssertNotNil(current.data["projectToken"].string)
    }
    for scopes: Set<OAuthScope> in [[]] {
      let denied = await router.call("project_info", arguments: [:], grant: grant(scopes))
      XCTAssertEqual(denied.data["error"], "insufficient_scope")
      XCTAssertEqual(denied.data["projectToken"], .null)
    }
    await router.stop()
  }

  func testMCPDiscoveryUsesSameActionAuthorizationAsCalls() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let bearer = OAuthContract.accessPrefix + String(repeating: "s", count: 64)
    let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
    let request = HTTPRequest(headers: [
      "Host": ["127.0.0.1:\(TunnelContract.defaultPort)"], "Authorization": ["Bearer " + bearer],
      "Content-Type": ["application/json"], "Accept": ["application/json, text/event-stream"],
    ], body: try body.data())
    for scopes: Set<OAuthScope> in [
      [.projectWrite], [.processRun], [.browserUse], [.projectRead], [.projectRead, .projectWrite],
      [],
    ] {
      let delegated = grant(scopes)
      let endpoint = MCPDispatcher(authentication: try fixtureRemoteAuthentication(bearer: bearer, context: delegated.context!),
                                   port: TunnelContract.defaultPort, router: router)
      let reply = await endpoint.handle(request)
      XCTAssertEqual(reply.status, 200)
      let definitions = try XCTUnwrap(reply.json["result"]["tools"].array)
      XCTAssertNil(definitions.first { $0["name"] == "projects" })
      XCTAssertNil(definitions.first { $0["name"] == "memory" })
      let info = definitions.first { $0["name"] == "project_info" }
      if !scopes.isDisjoint(with: [.projectRead, .projectWrite, .processRun, .browserUse]) {
        XCTAssertNotNil(info)
      } else {
        XCTAssertNil(info)
      }
      if !scopes.contains(.projectRead) {
        XCTAssertNil(definitions.first { $0["name"] == "read_files" })
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
