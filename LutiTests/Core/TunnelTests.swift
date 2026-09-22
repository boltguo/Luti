import XCTest

@testable import Luti

@MainActor final class TunnelTests: XCTestCase {
  func testPublicBaseURLGrammar() async throws {
    let url = try ConnectionContract.validatePublicBaseURL("https://mcp.example.com")
    XCTAssertEqual(url.host, "mcp.example.com")
    try ConnectionContract.validatePublicBaseURL("https://mcp.example.com/")
    for value in [
      "http://mcp.example.com",  // TLS is terminated by Cloudflare; plaintext is never the issuer
      "https://mcp.example.com:8443",  // a port would desynchronize the issuer
      "https://mcp.example.com/mcp",  // the issuer is an origin, not a path
      "https://mcp.example.com?x=1", "https://mcp.example.com#x",
      "https://user:pass@mcp.example.com", "https://MCP.Example.com", "https://*.example.com",
      "https://127.0.0.1", "https://example", "https://-bad.example.com", "https://bad-.example.com",
      "", "https://" + String(repeating: "x", count: 300) + ".example.com",
    ] {
      XCTAssertThrowsError(try ConnectionContract.validatePublicBaseURL(value), value)
    }
  }
  func testTunnelTokenGrammar() async throws {
    try TunnelContract.validateToken(String(repeating: "eyJhIjoi", count: 16) + "==")
    for value in ["", "short", "has space " + String(repeating: "a", count: 60),
      String(repeating: "a", count: 9000), String(repeating: "a", count: 60) + "\n"]
    {
      XCTAssertThrowsError(try TunnelContract.validateToken(value), value)
    }
  }
  func testUnverifiedExecutableIsNeverAccepted() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("cloudflared", "#!/bin/sh\necho not-official")
    XCTAssertThrowsError(try TunnelInstaller.verify(f.root.appendingPathComponent("cloudflared")))
    { error in
      XCTAssertEqual((error as? Failure)?.code, "binary_hash_mismatch")
    }
  }
  func testReadinessProbeStaysOnLoopback() async throws {
    let url = TunnelManager.readinessURL
    XCTAssertEqual(url.scheme, "http")
    XCTAssertEqual(url.host, "127.0.0.1")
    XCTAssertEqual(url.port, TunnelContract.metricsPort)
    XCTAssertEqual(url.path, "/ready")
    XCTAssertNotEqual(TunnelContract.metricsPort, TunnelContract.defaultPort)
  }
  func testInvalidStartupHasNoRunningProcess() async throws {
    let tunnel = TunnelManager(activity: ActivityStore())
    do {
      try await tunnel.start(
        binary: URL(fileURLWithPath: "/nonexistent"), helper: Fixture.helper,
        endpoint: URL(string: "http://example.org:80/mcp")!,
        publicBaseURL: URL(string: "https://mcp.example.com")!,
        tunnelToken: String(repeating: "a", count: 64))
      XCTFail("Non-loopback endpoint must be rejected.")
    } catch let failure as Failure { XCTAssertEqual(failure.code, "invalid_arguments") }
    let state = await tunnel.snapshot()
    XCTAssertFalse(state.ready)
    XCTAssertEqual(state.state, "stopped")
    await tunnel.stop()
  }
}
