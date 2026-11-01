import Foundation

/// Uses the dashboard's named-tunnel route. cloudflared reconnects its own edge
/// sockets. An initial auto-protocol timeout switches once to HTTP/2; a live
/// HTTP/2 child keeps retrying without restarting the listener or project jobs.
public actor CloudflareTunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.cloudflare
  public nonisolated let privateCredential = "" // This listener requires OAuth, never a shared tunnel bearer.
  private let helper: URL
  private let prepareBinary: @Sendable () async throws -> URL
  private let probe: @Sendable (URL) async -> Bool
  private let startupTimeout: Duration
  private var token: String?
  private var process = ProviderProcess()
  private var health: URL?
  private var lastProbe: (at: ContinuousClock.Instant, ready: Bool)?
  private var started = false
  private var stopped = false

  init(token: String, helper: URL,
       startupTimeout: Duration = .seconds(45),
       prepareBinary: @escaping @Sendable () async throws -> URL = { try await CloudflareInstaller.prepare() },
       probe: @escaping @Sendable (URL) async -> Bool = { await ConnectionProbe.ready($0) }) throws {
    try CloudflareContract.validateToken(token)
    self.token = token
    self.helper = helper
    self.startupTimeout = startupTimeout
    self.prepareBinary = prepareBinary
    self.probe = probe
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let token else { throw Failure.stopped }
    started = true
    defer { self.token = nil }
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      guard endpoint.port == CloudflareContract.port else { throw Failure.invalid("Cloudflare requires its configured local port.") }
      let binary = try await prepareBinary()
      for transport in ["auto", "http2"] {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        _ = try await process.prepareDirectory()
        try await process.launch(binary: binary, helper: helper, args: [
          "tunnel", "--no-autoupdate", "--protocol", transport,
          "--metrics", "127.0.0.1:0", "--loglevel", "info", "--output", "json", "run",
        ], environment: ["TUNNEL_TOKEN": token], secrets: [token])
        if try await waitUntilReady() { return }
        // Metrics discovery confirms startup; missing output is not a transport timeout.
        guard health != nil else { throw unavailable }
        // The live HTTP/2 child owns further network retries; snapshot reports reconnecting.
        if transport == "http2" { return }
        await process.stop()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        process = ProviderProcess()
        health = nil
        lastProbe = nil
      }
    } catch {
      await stop()
      throw error
    }
  }

  private func waitUntilReady() async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: startupTimeout)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      guard await process.running else { throw unavailable }
      if health == nil { health = Self.readinessURL(from: await process.startupOutput) }
      if let health, await probe(health), !stopped, await process.running {
        lastProbe = (ContinuousClock.now, true)
        return true
      }
      try await Task.sleep(for: .milliseconds(300))
    }
    try Task.checkCancellation()
    guard !stopped else { throw CancellationError() }
    guard await process.running else { throw unavailable }
    return false
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard started, !stopped else { return .stopped }
    guard await process.running else { return ConnectionSnapshot(state: .failed, message: unavailable.message) }
    let ready = await readiness()
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: ready ? .ready : .reconnecting,
      message: ready ? "" : "Cloudflare is reconnecting to its edge. Project tasks keep running.")
  }

  /// UI polling must not turn into one HTTP probe per tick.
  private func readiness() async -> Bool {
    if let lastProbe, lastProbe.at.duration(to: .now) < .seconds(5) { return lastProbe.ready }
    let ready = if let health { await probe(health) } else { false }
    lastProbe = (ContinuousClock.now, ready)
    return ready
  }

  public func stop() async {
    stopped = true
    token = nil
    health = nil
    lastProbe = nil
    await process.stop()
  }

  static func readinessURL(from output: String) -> URL? {
    guard let match = output.range(of: #"Starting metrics server on 127\.0\.0\.1:[0-9]{1,5}/metrics"#, options: .regularExpression),
      let port = Int(output[match].dropFirst("Starting metrics server on 127.0.0.1:".count).dropLast("/metrics".count)),
      (1...65535).contains(port) else { return nil }
    return URL(string: "http://127.0.0.1:\(port)/ready")
  }

  private var unavailable: Failure {
    Failure("cloudflare_unavailable", "Cloudflare Tunnel could not connect.",
      "Check the Tunnel Token and network. The dashboard's hostname route must point to \(CloudflareContract.localService).")
  }
}
