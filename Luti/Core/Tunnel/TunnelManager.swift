import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct TunnelSnapshot: Sendable, Equatable {
  public let state: String
  public let ready: Bool
  public let restartCount: Int
  public let message: String
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
public actor TunnelManager {
  private struct Configuration: Sendable {
    let binary: URL, helper: URL, endpoint: URL, publicBaseURL: URL
    let token: String
  }
  private var config: Configuration?
  private var process: OwnedProcess?
  private var runDirectory: URL?
  private var healthURL: URL?
  private var generation = UUID(), restartCount = 0
  private var desired = false
  private var monitor: Task<Void, Never>?
  private var state = "stopped", message = ""
  private let activity: ActivityStore
  private let probe: URLSession
  public init(activity: ActivityStore) {
    self.activity = activity
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 3
    #if os(macOS)
      configuration.connectionProxyDictionary = [:]
    #endif
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    probe = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
  }
  public func snapshot() -> TunnelSnapshot {
    TunnelSnapshot(
      state: state, ready: state == "ready" && process?.finished == false,
      restartCount: restartCount, message: message)
  }
  public func start(
    binary: URL, helper: URL, endpoint: URL, publicBaseURL: URL, tunnelToken: String
  ) async throws {
    guard !desired else { throw Failure.invalid("Tunnel is already starting or running.") }
    try ConnectionContract.validatePublicBaseURL(publicBaseURL.absoluteString)
    try TunnelContract.validateToken(tunnelToken)
    guard endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.path == "/mcp",
      endpoint.port == TunnelContract.defaultPort
    else { throw Failure.invalid("Invalid local Tunnel configuration.") }
    desired = true
    generation = UUID()
    let token = generation
    restartCount = 0
    config = Configuration(
      binary: binary, helper: helper, endpoint: endpoint, publicBaseURL: publicBaseURL,
      token: tunnelToken)
    do {
      try await launch(token)
      monitor = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          guard let self, await self.tick(token) else { return }
        }
      }
    } catch {
      await stop()
      throw error
    }
  }
  private func launch(_ token: UUID) async throws {
    guard desired, token == generation, let config else { throw CancellationError() }
    try Task.checkCancellation()
    try TunnelInstaller.verify(config.binary)
    state = restartCount == 0 ? "starting" : "reconnecting"
    message = "Starting the pinned cloudflared build."
    let directory = LutiPaths.runs.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(directory)
    runDirectory = directory
    // The Tunnel Token is injected through the environment only. It must never
    // reach argv, a config file, a log line or a crash payload.
    let environment = ["TUNNEL_TOKEN": config.token]
    // Ingress is owned by the Cloudflare dashboard for a token-managed tunnel:
    // the published hostname points at http://127.0.0.1:<defaultPort>. Passing
    // --url here would silently compete with that remote configuration.
    let args = [
      "tunnel", "--no-autoupdate",
      "--metrics", "127.0.0.1:\(TunnelContract.metricsPort)",
      "--loglevel", "info", "--output", "json",
      "run",
    ]
    let request = ProcessRequest(
      program: config.binary.path, args: args, cwd: directory, environment: environment,
      timeout: 86_400, syncWait: 0)
    let child: OwnedProcess
    do {
      child = try OwnedProcess(
        request, helper: config.helper, redactor: Redactor(known: [config.token]))
    } catch {
      throw failed(
        "cloudflared could not start. Check that the cached binary is the reviewed Cloudflare release; do not disable system security."
      )
    }
    process = child
    healthURL = Self.readinessURL
    let until = ContinuousClock.now.advanced(by: .seconds(45))
    while ContinuousClock.now < until {
      try Task.checkCancellation()
      guard desired, token == generation else { throw CancellationError() }
      guard !child.finished else {
        throw failed(
          "cloudflared exited before readiness. Check the Tunnel Token, that the tunnel still exists in Cloudflare, and network access."
        )
      }
      if let healthURL, await isReady(healthURL) {
        guard desired, token == generation, !child.finished else { throw CancellationError() }
        state = "ready"
        message = "Tunnel ready; waiting for a real tool call."
        await activity.record(
          tool: "tunnel", target: config.publicBaseURL.host ?? "Cloudflare Tunnel",
          status: "ready", started: Date(),
          summary: "cloudflared reported at least one edge connection; no host call inferred.")
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw failed("cloudflared did not become ready before its startup deadline.")
  }
  /// cloudflared answers 200 here once it holds at least one edge connection.
  static var readinessURL: URL {
    URL(string: "http://127.0.0.1:\(TunnelContract.metricsPort)/ready")!
  }
  private func isReady(_ url: URL) async -> Bool {
    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 2
      // Status only: the local endpoint is owned by the reviewed client.
      let (_, response) = try await probe.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch { return false }
  }
  private func tick(_ token: UUID) async -> Bool {
    guard desired, token == generation else { return false }
    if let process, !process.finished, let healthURL, await isReady(healthURL) {
      guard desired, token == generation else { return false }
      state = "ready"
      message = "Tunnel ready; recent tool activity is shown separately."
      return true
    }
    guard desired, token == generation else { return false }
    if let process, !process.finished {
      // cloudflared owns network reconnection. Do not spawn a competing
      // process just because one probe was unsuccessful.
      state = "reconnecting"
      message = "Tunnel is alive but not ready; cloudflared is reconnecting."
      return true
    }
    guard restartCount < 3 else {
      state = "failed"
      message = "Tunnel stopped after three bounded restart attempts."
      desired = false
      config = nil
      await cleanupProcess()
      return false
    }
    restartCount += 1
    state = "reconnecting"
    await cleanupProcess()
    do {
      try await Task.sleep(for: .seconds(1 << (restartCount - 1)))
      try await launch(token)
      return true
    } catch {
      guard desired, token == generation else { return false }
      await cleanupProcess()
      state = "reconnecting"
      message = "Restart attempt failed. Rechecking within the bounded retry budget."
      return true
    }
  }
  private func cleanupProcess() async {
    // Capture owned values before suspension; do not delete a newer run.
    let child = process
    let directory = runDirectory
    process = nil
    runDirectory = nil
    healthURL = nil
    child?.requestStop()
    let until = ContinuousClock.now.advanced(by: .seconds(4))
    while let child, !child.finished, ContinuousClock.now < until {
      try? await Task.sleep(for: .milliseconds(30))
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }
  public func stop() async {
    desired = false
    generation = UUID()
    monitor?.cancel()
    monitor = nil
    state = "stopped"
    message = ""
    config = nil
    await cleanupProcess()
  }
  private func failed(_ text: String) -> Failure {
    Failure(
      "tunnel_failed", text,
      "Check the saved Public Base URL and Tunnel Token against the Cloudflare dashboard. Start again explicitly after correcting the issue."
    )
  }
}
