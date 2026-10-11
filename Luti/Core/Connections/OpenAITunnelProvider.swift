import Foundation

/// OpenAI's outbound-only, workspace-authorized transport. Its private MCP
/// listener accepts only a fresh per-connection credential that tunnel-client
/// forwards; nothing is exposed as public HTTPS ingress and no OAuth is involved.
public actor OpenAITunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.openAI
  public nonisolated let privateCredential = "lt_" + Budget.token()
  private let tunnelID: String
  private let helper: URL
  private var apiKey: String?
  private let process = ProviderProcess()
  private var health: URL?
  private var lastProbe: (at: ContinuousClock.Instant, ready: Bool)?
  private var started = false
  private var stopped = false

  public init(tunnelID: String, apiKey: String, helper: URL) throws {
    try ConnectionContract.validateTunnelID(tunnelID)
    try ConnectionContract.validateAPIKey(apiKey)
    self.tunnelID = tunnelID
    self.apiKey = apiKey
    self.helper = helper
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let apiKey else { throw Failure.stopped }
    started = true
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      let binary = try await TunnelClientInstaller.prepare()
      try Task.checkCancellation()
      guard !stopped else { throw Failure.stopped }
      let directory = try await process.prepareDirectory()
      let healthFile = directory.appendingPathComponent("health.url")
      let header = "Authorization: Bearer " + privateCredential
      try await process.launch(binary: binary, helper: helper,
        args: ["run", "--health.listen-addr", "127.0.0.1:0", "--health.url-file", healthFile.path],
        environment: ["CONTROL_PLANE_API_KEY": apiKey, "CONTROL_PLANE_TUNNEL_ID": tunnelID,
          "MCP_SERVER_URL": endpoint.absoluteString, "MCP_EXTRA_HEADERS": header,
          "MCP_DISCOVERY_EXTRA_HEADERS": header, "LOG_HTTP_RAW_UNSAFE": "false"],
        secrets: [apiKey, privateCredential])
      let deadline = ContinuousClock.now.advanced(by: .seconds(45))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard !stopped, await process.running else { throw startupFailure }
        if health == nil, let data = try? PrivateFiles.read(healthFile, max: 2048),
          let text = String(data: data, encoding: .utf8), let base = Self.healthBase(text) {
          health = base.appendingPathComponent("readyz")
        }
        if let health, await ConnectionProbe.ready(health) {
          guard !stopped, await process.running else { throw Failure.stopped }
          lastProbe = (ContinuousClock.now, true)
          return
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      throw startupFailure
    } catch {
      await stop()
      throw error
    }
  }

  static func healthBase(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
      (1...65535).contains(port), url.user == nil, url.password == nil,
      ["", "/"].contains(url.path), url.query == nil, url.fragment == nil
    else { return nil }
    return url
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard !stopped, started else { return .stopped }
    guard await process.running else {
      return ConnectionSnapshot(state: .failed, message: startupFailure.message)
    }
    let ready = await readiness()
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: ready ? .ready : .reconnecting,
      message: ready ? "" : "OpenAI Tunnel is not ready. Check network access, runtime-key permissions and workspace association.")
  }

  /// UI polling must not turn into one HTTP probe per tick.
  private func readiness() async -> Bool {
    if let lastProbe, lastProbe.at.duration(to: .now) < .seconds(5) { return lastProbe.ready }
    let ready: Bool
    if let health { ready = await ConnectionProbe.ready(health) } else { ready = false }
    lastProbe = (ContinuousClock.now, ready)
    return ready
  }

  public func stop() async {
    stopped = true
    apiKey = nil
    health = nil
    await process.stop()
  }

  private var startupFailure: Failure {
    Failure("openai_tunnel_unavailable", "OpenAI Tunnel did not become ready.",
            "Check the tunnel_id, runtime API key with Tunnels Read + Use, and the target workspace association.")
  }
}

/// Small owner around the process supervisor. It never enters JobManager and
/// cannot cancel a project's jobs. Stop joins cleanup and permanently closes the
/// owner, including a Stop racing with a binary download or process launch.
actor ProviderProcess {
  private var child: OwnedProcess?
  private var runDirectory: URL?
  private var closed = false
  private var closing: Task<Void, Never>?

  func prepareDirectory() throws -> URL {
    guard !closed, child == nil else { throw Failure.stopped }
    if let runDirectory { return runDirectory }
    let directory = LutiPaths.runs.appendingPathComponent("connection-" + UUID().uuidString, isDirectory: true)
    try PrivateFiles.directory(directory)
    runDirectory = directory
    return directory
  }

  func launch(binary: URL, helper: URL, args: [String], environment: [String: String] = [:],
              secrets: [String] = []) throws {
    guard !closed, child == nil, let directory = runDirectory else { throw Failure.stopped }
    try Task.checkCancellation()
    // Do not inherit the user's tunnel-client profile.
    var env = environment
    env["HOME"] = directory.path
    env["TMPDIR"] = directory.path
    let request = ProcessRequest(program: binary.path, args: args, cwd: directory,
      environment: env, timeout: 86_400, syncWait: 0)
    child = try OwnedProcess(request, helper: helper, redactor: Redactor(known: secrets))
  }

  var running: Bool { child.map { !$0.finished } ?? false }

  func stop() async {
    if let closing { await closing.value; return }
    closed = true
    let owned = child
    let directory = runDirectory
    child = nil
    runDirectory = nil
    // Unstructured: a cancelled caller must not turn the throttled wait into a spin.
    let cleanup = Task {
      owned?.requestStop()
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while let owned, !owned.finished, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    closing = cleanup
    await cleanup.value
    closing = nil
  }
}
