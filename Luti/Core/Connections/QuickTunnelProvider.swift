import Foundation

/// A zero-configuration Cloudflare Quick Tunnel for temporary remote MCP testing.
/// The public origin is discovered only after cloudflared starts, and is never
/// persisted. Recreating the provider produces a new OAuth issuer.
public actor QuickTunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.quick
  public nonisolated let ingressPort = 0

  private let helper: URL
  private let process = ProviderProcess()
  private var origin: URL?
  private var readinessURL: URL?
  private var started = false
  private var stopped = false

  public init(helper: URL) {
    self.helper = helper
  }

  public var publicOrigin: URL? { origin }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped else { throw Failure.stopped }
    started = true
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      let binary = try await TunnelInstaller.prepare()
      try Task.checkCancellation()
      try TunnelInstaller.verify(binary)
      guard !stopped else { throw Failure.stopped }

      _ = try await process.prepareDirectory()
      let upstream = endpoint.deletingLastPathComponent()
      try await process.launch(
        binary: binary,
        helper: helper,
        args: [
          "tunnel", "--no-autoupdate",
          "--loglevel", "info", "--output", "json",
          "--url", upstream.absoluteString,
        ])

      let deadline = ContinuousClock.now.advanced(by: .seconds(45))
      var edgeRegistered = false
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard !stopped, await process.running else { throw startupFailure }

        let output = await process.output
        if origin == nil {
          origin = Self.publicOrigin(from: output)
        }
        if readinessURL == nil {
          readinessURL = Self.readinessURL(from: output)
        }
        edgeRegistered = edgeRegistered || output.contains("Registered tunnel connection")
        if origin != nil, let readinessURL, await ConnectionProbe.ready(readinessURL) {
          return
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      // Keep the allocated URL if cloudflared connected to an edge but its
      // local readiness endpoint could not be checked before the deadline.
      if !stopped, await process.running, origin != nil, edgeRegistered { return }
      throw startupFailure
    } catch {
      await stop()
      throw error
    }
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard !stopped, started else { return .stopped }
    guard await process.running, origin != nil else {
      return ConnectionSnapshot(state: .failed, message: startupFailure.message)
    }

    // cloudflared's own status reflects its edge connection without relying
    // on this Mac's DNS, VPN, or proxy path back to the public hostname.
    if readinessURL == nil {
      readinessURL = Self.readinessURL(from: await process.output)
    }
    if let readinessURL, await ConnectionProbe.ready(readinessURL) {
      return ConnectionSnapshot(state: .ready)
    }
    return ConnectionSnapshot(
      state: .reconnecting,
      message: "Quick Tunnel is running while cloudflared reconnects to Cloudflare.")
  }

  public func stop() async {
    stopped = true
    origin = nil
    readinessURL = nil
    await process.stop()
  }

  static func publicOrigin(from output: String) -> URL? {
    var remainder = output[...]
    while let scheme = remainder.range(of: "https://") {
      let candidate = remainder[scheme.lowerBound...].prefix { character in
        !character.isWhitespace && !"\"'<>[](){};,\\".contains(character)
      }
      if let origin = try? validateQuickOrigin(String(candidate)) {
        return origin
      }
      remainder = remainder[scheme.upperBound...]
    }
    return nil
  }

  static func readinessURL(from output: String) -> URL? {
    let prefix = "Starting metrics server on 127.0.0.1:"
    let suffix = "/metrics"
    guard let match = output.range(
      of: #"Starting metrics server on 127\.0\.0\.1:[0-9]{1,5}/metrics"#,
      options: .regularExpression),
      let port = Int(output[match].dropFirst(prefix.count).dropLast(suffix.count)),
      (1...65_535).contains(port)
    else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/ready")
  }

  static func validateQuickOrigin(_ value: String) throws -> URL {
    let validated = try ConnectionContract.validatePublicBaseURL(value)
    guard let host = validated.host,
      host != "trycloudflare.com",
      host.hasSuffix(".trycloudflare.com")
    else {
      throw Failure.invalid("Quick Tunnel returned an unexpected public hostname.")
    }
    return URL(string: "https://" + host)!
  }

  private var startupFailure: Failure {
    Failure(
      "quick_tunnel_unavailable",
      "Quick Tunnel did not expose this Luti runtime.",
      "Try again later or use one of the configured persistent connection methods.")
  }
}
