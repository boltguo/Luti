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
    XCTAssertEqual(tools.count, 29)
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
    let edit = await endpoint.handle(
      try request(
        "tools/call",
        params: [
          "name": "edit_files",
          "arguments": [
            "action": "edit", "path": "a.txt", "expectedSHA256": .string(sha),
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
    let result = await router.call("run_shell", arguments: ["command": "echo no"])
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
