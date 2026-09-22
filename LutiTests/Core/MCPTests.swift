import XCTest

@testable import Luti

@MainActor final class MCPTests: XCTestCase {
  private let token = String(repeating: "a", count: 64)
  private func request(
    _ method: String, params: JSONValue = [:], modern: Bool = false, id: JSONValue? = 1,
    extra: [String: [String]] = [:]
  ) throws -> HTTPRequest {
    var headers: [String: [String]] = [
      "Host": ["127.0.0.1:\(TunnelContract.defaultPort)"], "Authorization": ["Bearer " + token],
      "Content-Type": ["application/json"], "Accept": ["application/json, text/event-stream"],
    ]
    var p = params
    if modern {
      headers["MCP-Protocol-Version"] = [MCPDispatcher.modern]
      headers["Mcp-Method"] = [method]
      if let name = params["name"].string ?? params["uri"].string { headers["Mcp-Name"] = [name] }
      p = p.adding(
        "_meta",
        [
          "io.modelcontextprotocol/protocolVersion": .string(MCPDispatcher.modern),
          "io.modelcontextprotocol/clientCapabilities": [:],
        ])
    }
    headers.merge(extra, uniquingKeysWith: { _, b in b })
    var body: JSONValue = ["jsonrpc": "2.0", "method": .string(method), "params": p]
    if let id { body = body.adding("id", id) }
    return HTTPRequest(headers: headers, body: try body.data())
  }
  func testLegacyInitializeAndTools() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let initResult = await endpoint.handle(
      try request(
        "initialize",
        params: [
          "protocolVersion": "2025-11-25", "capabilities": [:],
          "clientInfo": ["name": "tests", "version": "1"],
        ]))
    XCTAssertEqual(initResult.status, 200)
    XCTAssertEqual(initResult.json["result"]["protocolVersion"], "2025-11-25")
    let list = await endpoint.handle(try request("tools/list"))
    let tools = try XCTUnwrap(list.json["result"]["tools"].array)
    XCTAssertEqual(tools.count, 30)
    XCTAssertNotNil(tools.first { $0["name"] == "projects" })
    let readFiles = try XCTUnwrap(tools.first { $0["name"] == "read_files" })
    XCTAssertEqual(readFiles["inputSchema"]["properties"]["endLine"]["default"], .null)
    XCTAssertEqual(readFiles["inputSchema"]["properties"]["byteOffset"]["default"], 0)
    XCTAssertEqual(readFiles["inputSchema"]["properties"]["lineByteOffset"], .null)
    let jobQuery = try XCTUnwrap(tools.first { $0["name"] == "job_query" })
    let jobAction = try XCTUnwrap(tools.first { $0["name"] == "job_action" })
    let gitQuery = try XCTUnwrap(tools.first { $0["name"] == "git_query" })
    XCTAssertEqual(jobQuery["annotations"]["readOnlyHint"], true)
    XCTAssertEqual(jobAction["annotations"]["readOnlyHint"], false)
    XCTAssertEqual(gitQuery["annotations"]["readOnlyHint"], true)
    XCTAssertNil(tools.first { $0["name"] == "git_status" })
    XCTAssertNil(tools.first { $0["name"] == "job_status" })
    XCTAssertNil(tools.first { $0["name"] == "export_archive" })
    XCTAssertNil(tools.first { $0["name"] == "browser_click" })
    XCTAssertNil(tools.first { $0["name"] == "browser_snapshot" })
    XCTAssertNil(tools.first { $0["name"] == "browser_network" })
    XCTAssertNil(tools.first { $0["name"] == "browser_open" })
    XCTAssertNil(tools.first { $0["name"] == "browser_wait" })
    XCTAssertNil(tools.first { $0["name"] == "browser_upload" })
    XCTAssertNotNil(tools.first { $0["name"] == "browser_session" })
    XCTAssertNotNil(tools.first { $0["name"] == "browser_action" })
    XCTAssertNotNil(tools.first { $0["name"] == "browser_transfer" })
    XCTAssertNotNil(tools.first { $0["name"] == "browser_observe" })
    XCTAssertNotNil(tools.first { $0["name"] == "browser_inspect" })

    let computerObserve = try XCTUnwrap(tools.first { $0["name"] == "computer_observe" })
    XCTAssertEqual(computerObserve["inputSchema"]["properties"]["displayId"]["default"], .null)
    XCTAssertEqual(computerObserve["inputSchema"]["properties"]["includeAccessibility"]["default"], .null)
    let notification = await endpoint.handle(try request("notifications/initialized", id: nil))
    XCTAssertEqual(notification.status, 202)
    XCTAssertTrue(notification.body.isEmpty)
    await router.stop()
  }
  func testModernDiscovery() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let response = await endpoint.handle(try request("server/discover", modern: true))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.json["result"]["resultType"], "complete")
    XCTAssertEqual(
      response.json["result"]["supportedVersions"].array?.first, .string(MCPDispatcher.modern))
    await router.stop()
  }
  func testModernHeaderMismatch() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let response = await endpoint.handle(
      try request(
        "tools/call", params: ["name": "project_info", "arguments": [:]], modern: true,
        extra: ["Mcp-Name": ["run_shell"]]))
    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.json["error"]["code"].int, -32020)
    await router.stop()
  }
  func testAuthenticationOriginAndDuplicateHeader() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    for (headers, status) in [
      (["Authorization": ["Bearer wrong"]], 401), (["Origin": ["https://evil.example"]], 403),
      (["Host": ["evil.example"]], 403), (["Authorization": ["x", "y"]], 400),
    ] {
      let reply = await endpoint.handle(try request("tools/list", extra: headers))
      XCTAssertEqual(reply.status, status)
    }
    await router.stop()
  }
  func testPublicHostnameIsAdmittedAndNeverEchoed() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(
      authentication: .remote(publicHost: "mcp.example.com",
        oauth: LutiOAuthService(issuer: URL(string: "https://mcp.example.com")!,
          store: OAuthStore(url: f.contextDataRoot.appendingPathComponent("oauth.json")))),
      port: TunnelContract.defaultPort, router: router)
    // The hostname is admitted, but the local bearer must never grant public access.
    for headers in [
      ["Host": ["mcp.example.com"]], ["Host": ["MCP.Example.com"]],
      ["Host": ["mcp.example.com"], "Origin": ["https://mcp.example.com"]],
    ] {
      let reply = await endpoint.handle(try request("tools/list", extra: headers))
      XCTAssertEqual(reply.status, 401, headers.description)
    }
    // Allowlisted, never echoed: a neighbouring name and plaintext stay out.
    for headers in [
      ["Host": ["evil.example.com"]], ["Host": ["mcp.example.com.evil.example"]],
      ["Host": ["mcp.example.com"], "Origin": ["http://mcp.example.com"]],
      ["Host": ["mcp.example.com:443"]],
    ] {
      let reply = await endpoint.handle(try request("tools/list", extra: headers))
      XCTAssertEqual(reply.status, 403, headers.description)
    }
    // A dispatcher without a published hostname keeps the tunnel out entirely.
    let local = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let reply = await local.handle(
      try request("tools/list", extra: ["Host": ["mcp.example.com"]]))
    XCTAssertEqual(reply.status, 403)
    await router.stop()
  }
  func testReadAndEditViaMCP() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a.txt", "hello")
    let router = try f.router(execution: true)
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let read = await endpoint.handle(
      try request(
        "tools/call", params: ["name": "read_files", "arguments": ["paths": ["a.txt"]]],
        modern: true))
    let sha = try XCTUnwrap(
      read.json["result"]["structuredContent"]["files"].array?[0]["sha256"].string)
    let context = await endpoint.handle(try request("tools/call", params: ["name": "project_info", "arguments": [:]], modern: true))
    let edit = await endpoint.handle(
      try request(
        "tools/call",
        params: [
          "name": "edit_files",
          "arguments": [
            "action": "edit", "path": "a.txt", "expectedSHA256": .string(sha),
            "projectToken": context.json["result"]["structuredContent"]["projectToken"],
            "edits": [["oldText": "hello", "newText": "world"]],
          ],
        ], modern: true))
    XCTAssertEqual(edit.json["result"]["isError"], false)
    let after = try await f.files.text("a.txt")
    XCTAssertEqual(after.text, "world")
    await router.stop()
  }
  func testToolsCallNotificationCannotMutate() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let result = await endpoint.handle(
      try request(
        "tools/call",
        params: [
          "name": "edit_files",
          "arguments": ["action": "create", "path": "bad", "content": "bad"],
        ], id: nil))
    XCTAssertEqual(result.status, 202)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.root.appendingPathComponent("bad").path))
    await router.stop()
  }
  func testReadOnlyPolicyDeniesExecution() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let result = await router.callInCurrentProject("run_shell", arguments: ["command": "echo no"])
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "execution_policy_denied")
    await router.stop()
  }
  func testBadRequestAndUnknownMethod() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let nullID = await endpoint.handle(try request("tools/list", id: .null))
    XCTAssertEqual(nullID.status, 400)
    let unknown = await endpoint.handle(try request("not/a/method", modern: true))
    XCTAssertEqual(unknown.status, 404)
    await endpoint.shutdown()
    let stopped = await endpoint.handle(try request("tools/list"))
    XCTAssertEqual(stopped.status, 503)
    await router.stop()
  }
  func testEncodedHeader() {
    XCTAssertEqual(MCPDispatcher.decodeHeader("=?base64?5L2g5aW9?="), "你好")
    XCTAssertNil(MCPDispatcher.decodeHeader("=?base64?invalid?="))
  }
  func testResourceCannotReadDisk() async throws {
    let images = ImageStore()
    do {
      _ = try await images.read("file:///etc/passwd")
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "resource_not_found") }
  }
  func testArtifactProtocolRoundTrip() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("report.json", "{\"ok\":true}")
    let router = try f.router()
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let exported = await endpoint.handle(try request("tools/call", params: ["name": "export_artifact", "arguments": ["path": "report.json"]], modern: true))
    let result = exported.json["result"]
    XCTAssertEqual(result["isError"], false)
    XCTAssertEqual(result["content"].array?.last?["type"], "resource_link")
    let uri = try XCTUnwrap(result["structuredContent"]["resource"].string)
    let read = await endpoint.handle(try request("resources/read", params: ["uri": .string(uri)], modern: true))
    XCTAssertEqual(read.status, 200)
    XCTAssertEqual(read.json["result"]["contents"].array?.first?["mimeType"], "application/json")
    let encoded = try XCTUnwrap(read.json["result"]["contents"].array?.first?["blob"].string)
    XCTAssertEqual(Data(base64Encoded: encoded), Data("{\"ok\":true}".utf8))
    let denied = await endpoint.handle(try request("resources/read", params: ["uri": .string(uri)], extra: ["Authorization": ["Bearer wrong"]]))
    XCTAssertEqual(denied.status, 401)
    await router.stop()
  }
  func testImageContentAndStopExpiry() async throws {
    let images = ImageStore()
    let image = try await images.insert(
      bytes: Data([1, 2, 3]), mimeType: "image/png", width: 100, height: 50,
      bounds: ScreenBounds(x: -200, y: 0, width: 200, height: 100))
    XCTAssertEqual(image.imageContent["type"], "image")
    XCTAssertEqual(image.imageContent["data"], "AQID")
    let read = try await images.read(image.uri)
    XCTAssertEqual(read["contents"].array?.first?["blob"], "AQID")
    await images.stop()
    do {
      _ = try await images.read(image.uri)
      XCTFail()
    } catch {}
  }

  private func delegatedContext(_ scopes: Set<OAuthScope>) -> RequestContext {
    RequestContext(transport: .loopback, clientID: "resource-reader", clientName: "Resource reader",
      authorizationID: UUID(), scopes: scopes, resource: "http://localhost/mcp")
  }

  func testResourceListingAndReadingRequireTheProducingCapability() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("report.txt", "project bytes")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let exported = await router.callInCurrentProject("export_artifact", arguments: ["path": "report.txt"])
    let projectURI = try XCTUnwrap(exported.data["resource"].string)
    let job = await router.callInCurrentProject("run_process",
      arguments: ["program": "/usr/bin/printf", "args": ["process bytes"], "syncWait": 3])
    XCTAssertFalse(job.isError)
    let log = await router.callInCurrentProject("job_query",
      arguments: ["action": "logs", "jobId": job.data["jobId"], "exportFull": true])
    let logURI = try XCTUnwrap(log.data["artifact"]["resource"].string)
    let artifacts = await router.artifacts
    let screenshot = try await artifacts.insert(Data([1, 2]), name: "browser.png", source: .browser)
    let download = try await artifacts.insert(Data([3, 4]), name: "download.bin", source: .browser)
    let image = try await router.images.insert(bytes: Data([5, 6]), mimeType: "image/png",
      width: 1, height: 1, bounds: ScreenBounds(x: 0, y: 0, width: 1, height: 1))
    let resources: [(scope: OAuthScope, uri: String)] = [
      (.projectRead, projectURI), (.processRun, logURI), (.browserUse, screenshot.uri),
      (.browserUse, download.uri), (.computerRead, image.uri),
    ]
    for scopes: Set<OAuthScope> in [
      [.projectRead], [.processRun], [.browserUse], [.computerRead], [.projectWrite],
      [.computerControl], [], Set(OAuthScope.allCases),
    ] {
      let endpoint = MCPDispatcher(authentication: .delegated(bearer: token, context: delegatedContext(scopes)),
        port: TunnelContract.defaultPort, router: router)
      let listed = await endpoint.handle(try request("resources/list", modern: true))
      XCTAssertEqual(listed.status, 200)
      let visible = Set(try XCTUnwrap(listed.json["result"]["resources"].array).compactMap { $0["uri"].string })
      XCTAssertEqual(visible, Set(resources.filter { scopes.contains($0.scope) }.map(\.uri)))
      for resource in resources {
        let reply = await endpoint.handle(try request("resources/read",
          params: ["uri": .string(resource.uri)], modern: true))
        if scopes.contains(resource.scope) {
          XCTAssertEqual(reply.status, 200)
          XCTAssertNotNil(reply.json["result"]["contents"].array?.first?["blob"].string)
        } else {
          XCTAssertEqual(reply.json["error"]["data"]["error"], "insufficient_scope")
          XCTAssertEqual(reply.json["result"], .null)
        }
      }
      await endpoint.shutdown()
    }
  }

  func testBrowserUploadAndCodeQueryScopesMatchDiscoveryAndCalls() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let binding = await router.projectToken
    for scopes: Set<OAuthScope> in [[.projectRead], [.processRun], [.browserUse],
      [.projectRead, .browserUse], [.projectRead, .processRun]] {
      let context = delegatedContext(scopes)
      let grant = ToolGrant.remote(context)
      let endpoint = MCPDispatcher(authentication: .delegated(bearer: token, context: context),
        port: TunnelContract.defaultPort, router: router)
      let reply = await endpoint.handle(try request("tools/list"))
      let definitions = try XCTUnwrap(reply.json["result"]["tools"].array)
      let transfer = definitions.first { $0["name"] == "browser_transfer" }
      if scopes.contains(.browserUse) {
        XCTAssertEqual(transfer?["inputSchema"]["properties"]["action"]["enum"],
          scopes.contains(.projectRead) ? ["upload", "download"] : ["download"])
        XCTAssertNoThrow(try grant.authorize(tool: "browser_transfer", arguments: ["action": "download"]))
      } else { XCTAssertNil(transfer) }
      if !scopes.isSuperset(of: [.projectRead, .browserUse]) {
        let denied = await router.callInCurrentProject("browser_transfer", arguments: [
          "action": "upload", "path": "file.txt", "tabId": "tab", "snapshotId": "snapshot", "ref": "ref",
        ], grant: grant)
        XCTAssertEqual(denied.data["error"], "insufficient_scope")
      } else {
        XCTAssertNoThrow(try grant.authorize(tool: "browser_transfer", arguments: ["action": "upload"]))
      }
      let code = definitions.first { $0["name"] == "code_query" }
      if scopes.isSuperset(of: [.projectRead, .processRun]) {
        let definition = try XCTUnwrap(code)
        XCTAssertTrue(definition["inputSchema"]["required"].array?.contains("projectToken") == true)
        XCTAssertEqual(definition["annotations"]["readOnlyHint"], false)
        XCTAssertEqual(definition["annotations"]["idempotentHint"], false)
        XCTAssertEqual(definition["annotations"]["openWorldHint"], true)
        let missing = await router.call("code_query", arguments: ["action": "documentSymbols", "path": "file.txt"], grant: grant)
        XCTAssertEqual(missing.data["error"], "project_binding_required")
        let stale = await router.call("code_query", arguments: ["action": "documentSymbols",
          "path": "file.txt", "projectToken": "old-project"], grant: grant)
        XCTAssertEqual(stale.data["error"], "project_binding_mismatch")
      } else {
        XCTAssertNil(code)
        let denied = await router.call("code_query", arguments: ["action": "documentSymbols",
          "path": "file.txt", "projectToken": .string(binding)], grant: grant)
        XCTAssertEqual(denied.data["error"], "insufficient_scope")
      }
      await endpoint.shutdown()
    }
  }
  func testActionSchemasShareBoundariesAndNeverInjectForeignDefaults() throws {
    XCTAssertEqual(ToolCatalog.names.count, 30)
    for (name, contracts) in ActionContracts.rules {
      let definition = try XCTUnwrap(ToolCatalog.definitions.first { $0["name"].string == name })
      let schema = definition["inputSchema"]
      let properties = try XCTUnwrap(schema["properties"].object)
      XCTAssertEqual(Set(schema["properties"]["action"]["enum"].array!.compactMap(\.string)), Set(contracts.keys))
      XCTAssertEqual(schema["type"], "object")
      XCTAssertEqual(schema["additionalProperties"], false)
      XCTAssertEqual(schema["oneOf"], .null)
      for (field, property) in properties where property["default"] != .null {
        XCTAssertTrue(contracts.values.allSatisfy { $0.fields.contains(field) }, "\(name).\(field) leaks a default across actions.")
        XCTAssertNotEqual(field, "waitTimeoutMs", "Conditional timeouts must not be injected without a condition.")
      }
      for (action, rule) in contracts {
        let projected = ActionContracts.present(definition, actions: [.string(action)])
        let actionSchema = projected["inputSchema"]
        var required = rule.required.union(["action"])
        if ProjectBindingContract.requiresToken(name, arguments: ["action": .string(action)]) {
          required.insert("projectToken")
        }
        XCTAssertEqual(Set(actionSchema["required"].array!.compactMap(\.string)), required)
        XCTAssertEqual(Set(actionSchema["properties"].object!.keys), rule.fields.union(["projectToken"]))
        XCTAssertEqual(projected["annotations"]["readOnlyHint"], .bool(rule.readOnly))
        XCTAssertEqual(ActionContracts.present(projected), projected, "Schema projection must be stable.")
        for missing in rule.required {
          let values = Dictionary(uniqueKeysWithValues: rule.required.subtracting([missing]).map { ($0, JSONValue.string("fixture")) })
          XCTAssertThrowsError(try ActionContracts.arguments(name, .object(values).adding("action", .string(action))))
        }
      }
    }
    let bytes = try JSONValue.array(ToolCatalog.definitions).data().count
    print("Public tool catalog: count=\(ToolCatalog.names.count), bytes=\(bytes)")
  }

  func testBrowserActionParsersUseTheSameFieldsAndValidMinimalInputs() throws {
    let samples: [String: JSONValue] = [
      "tabId": "tab_fixture", "snapshotId": "snapshot_fixture", "ref": "e1",
      "url": "https://example.test/", "text": "", "key": "Enter", "value": "option",
      "path": "fixture.txt", "dialogId": "dialog_00000000-0000-0000-0000-000000000000",
    ]
    for (tool, contracts) in ActionContracts.rules where tool.hasPrefix("browser_") {
      for (action, rule) in contracts {
        let backend = try XCTUnwrap(rule.backend)
        let values = try Dictionary(uniqueKeysWithValues: rule.required.map { field in
          (field, try XCTUnwrap(samples[field], "Missing fixture field \(field)"))
        })
        let publicValue = JSONValue.object(values).adding("action", .string(action))
        XCTAssertNoThrow(try ActionContracts.arguments(tool, publicValue))
        let forwarded = tool == "browser_dialog" ? publicValue : publicValue.removing(["action"])
        let parsed = try BrowserArguments.validate(backend, forwarded)
        let fields = try ActionContracts.browserFields(backend, action: action)
        XCTAssertTrue(Set(parsed.object!.keys).isSubset(of: fields))
        XCTAssertThrowsError(try BrowserArguments.validate(backend, forwarded.adding("unrelatedField", true)))
      }
    }
    let target: JSONValue = ["tabId": "tab", "snapshotId": "snapshot", "ref": "e1"]
    XCTAssertEqual(try BrowserArguments.validate("browser_check", target)["checked"], true)
    XCTAssertEqual(try BrowserArguments.validate("browser_click", target)["waitTimeoutMs"], .null)
    XCTAssertEqual(try BrowserArguments.validate("browser_click", target.adding("waitForText", "done"))["waitTimeoutMs"], 5_000)
    XCTAssertEqual(try BrowserArguments.validate("browser_wait", ["tabId": "tab"])["state"], "load")
  }

  func testInvalidActionArgumentsFailBeforeMemoryBrowserOrJobEffects() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let target: JSONValue = ["action": "click", "tabId": "tab", "snapshotId": "snapshot", "ref": "e1"]
    let cases: [(String, JSONValue)] = [
      ("memory", ["action": "recent", "limit": 10]),
      ("memory", ["action": "recall", "limit": .null]),
      ("memory", ["action": "sessions", "runId": .string(UUID().uuidString), "offset": 0]),
      ("memory", ["action": "remember", "kind": "goal", "content": "Must not be saved", "supersedes": "memory_old"]),
      ("projects", ["action": "current", "projectId": "unused"]),
      ("job_query", ["action": "list", "waitMs": 0]),
      ("job_query", ["action": "status"]),
      ("job_query", ["action": "logs", "jobId": "job", "stdoutOffset": 0]),
      ("job_query", ["action": "logs", "jobId": "job", "maxBytes": 100]),
      ("job_action", ["action": "stop", "jobId": "job", "close": false]),
      ("job_action", ["action": "input", "jobId": "job", "text": "", "close": false]),
      ("browser_session", ["action": "open"]),
      ("browser_session", ["action": "close", "tabId": "tab", "url": "https://example.test/"]),
      ("browser_action", target.adding("text", "not a fill")),
      ("browser_action", target.adding("waitTimeoutMs", 500)),
      ("browser_action", target.adding("waitForText", "done").adding("waitForState", "load")),
      ("browser_observe", ["action": "wait", "tabId": "tab", "text": "done", "state": "load"]),
      ("browser_observe", ["action": "snapshot", "tabId": "tab", "scopeRef": "e1"]),
      ("browser_observe", ["action": "screenshot", "tabId": "tab", "scopeSnapshotId": "snapshot", "scopeRef": "e1", "fullPage": true]),
      ("browser_dialog", ["action": "dismiss", "tabId": "tab", "dialogId": "dialog_00000000-0000-0000-0000-000000000000", "promptText": "unused"]),
    ]
    for (name, arguments) in cases {
      let result = await router.callInCurrentProject(name, arguments: arguments)
      XCTAssertTrue(result.isError, "\(name): \(arguments)")
      XCTAssertEqual(result.data["error"], "invalid_arguments", "\(name): \(arguments)")
    }
    let events = await router.activity.snapshot()
    XCTAssertTrue(events.allSatisfy { $0.effect == "none" })
    let jobs = await router.jobList()
    XCTAssertTrue(jobs.isEmpty)
    let recent = await router.call("memory", arguments: ["action": "recent"])
    XCTAssertFalse(recent.isError)
    XCTAssertEqual(recent.data["memoryCount"], 0)
  }

  func testAuthorizedActionSchemasTrimFieldsRequiredBindingsAndRiskHints() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    for scopes: Set<OAuthScope> in [[], [.projectRead], [.projectWrite], [.processRun], [.browserUse],
      [.projectRead, .projectWrite], [.projectRead, .browserUse], Set(OAuthScope.allCases)] {
      let context = delegatedContext(scopes)
      let grant = ToolGrant.remote(context)
      let endpoint = MCPDispatcher(authentication: .delegated(bearer: token, context: context),
        port: TunnelContract.defaultPort, router: router)
      let response = await endpoint.handle(try request("tools/list"))
      let tools = try XCTUnwrap(response.json["result"]["tools"].array)
      for (name, contracts) in ActionContracts.rules {
        let allowed = contracts.filter { action, _ in
          (try? grant.authorize(tool: name, arguments: ["action": .string(action)])) != nil
        }
        let visible = tools.first { $0["name"].string == name }
        if allowed.isEmpty { XCTAssertNil(visible); continue }
        let definition = try XCTUnwrap(visible)
        let schema = definition["inputSchema"]
        let expectedFields = allowed.values.reduce(Set(["projectToken"])) { $0.union($1.fields) }
        XCTAssertEqual(Set(schema["properties"].object!.keys), expectedFields)
        XCTAssertEqual(Set(schema["properties"]["action"]["enum"].array!.compactMap(\.string)), Set(allowed.keys))
        let description = schema["properties"]["action"]["description"].string ?? ""
        for hidden in Set(contracts.keys).subtracting(allowed.keys) {
          XCTAssertFalse(description.split(separator: "\n").contains { $0.hasPrefix(hidden + ":") })
        }
        let readOnly = allowed.values.allSatisfy(\.readOnly)
        XCTAssertEqual(definition["annotations"]["readOnlyHint"], .bool(readOnly))
        XCTAssertEqual(definition["annotations"]["idempotentHint"], .bool(readOnly))
        let needsBinding = allowed.keys.allSatisfy {
          ProjectBindingContract.requiresToken(name, arguments: ["action": .string($0)])
        }
        XCTAssertEqual(schema["required"].array!.contains("projectToken"), needsBinding)
      }
      await endpoint.shutdown()
    }
  }

  func testInitializeRecommendsCompactDiscoveryWithoutAddingTools() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    let endpoint = MCPDispatcher(authentication: .local(bearer: token), port: TunnelContract.defaultPort, router: router)
    let response = await endpoint.handle(try request("initialize", params: [
      "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "tests", "version": "1"],
    ]))
    let instructions = try XCTUnwrap(response.json["result"]["instructions"].string)
    XCTAssertTrue(instructions.contains("memory(action=recent)"))
    XCTAssertTrue(instructions.contains("inspect_project(view=summary)"))
    XCTAssertTrue(instructions.contains("omit unused fields instead of null"))
    XCTAssertFalse(ToolCatalog.names.contains("agent_start"))
    XCTAssertFalse(ToolCatalog.names.contains("resume_project"))
  }

  func testRetinaAndNegativeDisplayCoordinateMapping() throws {
    let bounds = ScreenBounds(x: -1000, y: -200, width: 1000, height: 500)
    let point = try bounds.globalPoint(
      pixelX: 500, pixelY: 250, imageWidth: 2000, imageHeight: 1000)
    XCTAssertEqual(point.0, -750)
    XCTAssertEqual(point.1, -75)
    XCTAssertThrowsError(
      try bounds.globalPoint(pixelX: 2000, pixelY: 0, imageWidth: 2000, imageHeight: 1000))
  }
}
