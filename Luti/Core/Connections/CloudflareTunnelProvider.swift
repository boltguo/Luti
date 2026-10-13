import Foundation

/// Uses the dashboard's named-tunnel route. cloudflared reconnects its own edge
/// sockets; the app only replaces a child that actually exited. No monitor task.
public actor CloudflareTunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.cloudflare
  public nonisolated let privateCredential = "" // This listener requires OAuth, never a shared tunnel bearer.
  private let helper: URL
  private var token: String?
  private let process = ProviderProcess()
  private var health: URL?
  private var started = false
  private var stopped = false

  init(token: String, helper: URL) throws {
    try CloudflareContract.validateToken(token)
    self.token = token
    self.helper = helper
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let token else { throw Failure.stopped }
    started = true
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      guard endpoint.port == CloudflareContract.port else { throw Failure.invalid("Cloudflare requires its configured local port.") }
      let binary = try await CloudflareInstaller.prepare()
      try Task.checkCancellation()
      guard !stopped else { throw CancellationError() }
      _ = try await process.prepareDirectory()
      try await process.launch(binary: binary, helper: helper, args: [
        "tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:0", "--loglevel", "info", "--output", "json", "run",
      ], environment: ["TUNNEL_TOKEN": token], secrets: [token])
      self.token = nil
      let deadline = ContinuousClock.now.advanced(by: .seconds(45))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard !stopped, await process.running else { throw unavailable }
        if health == nil { health = Self.readinessURL(from: await process.startupOutput) }
        if let health, await ConnectionProbe.ready(health), !stopped, await process.running { return }
        try await Task.sleep(for: .milliseconds(300))
      }
      throw unavailable
    } catch {
      await stop()
      throw error
    }
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard started, !stopped else { return .stopped }
    guard await process.running else { return ConnectionSnapshot(state: .failed, message: unavailable.message) }
    let ready = if let health { await ConnectionProbe.ready(health) } else { false }
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: ready ? .ready : .reconnecting,
      message: ready ? "" : "Cloudflare is reconnecting to its edge. Project tasks keep running.")
  }

  public func stop() async {
    stopped = true
    token = nil
    health = nil
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
