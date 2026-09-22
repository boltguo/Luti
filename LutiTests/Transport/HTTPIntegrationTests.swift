import Foundation
import XCTest

@testable import Luti

@MainActor final class HTTPIntegrationTests: XCTestCase {
  func testRealLoopbackTransport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "luti-http-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let router = try ToolRouter(
      workspace: try WorkspaceFiles(root: root), jobs: JobManager(helper: JobManager.defaultHelper),
      images: ImageStore(), computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .readOnly, contextDataRoot: root.appendingPathComponent("test-private-data"))
    let server = MCPServer()
    let token = Budget.token()
    let url = try await server.start(router: router, authentication: .local(bearer: token), port: 0)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let payload: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
    request.httpBody = try payload.data()
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let tools = try JSONValue.decode(data)["result"]["tools"].array ?? []
    XCTAssertEqual(tools.count, 29)
    XCTAssertNotNil(tools.first { $0["name"] == "projects" })
    request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
    let (_, denied) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
    await server.stop()
    await router.stop()
  }
}
