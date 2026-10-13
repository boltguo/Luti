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
  private var logs: URL?
  private var metrics: URL?
  private var lastMetricsCheck: ContinuousClock.Instant?
  private var pollState = PollState()
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
      var args = ["run", "--health.listen-addr", "127.0.0.1:0", "--health.url-file", healthFile.path]
      if let proxy = Self.systemProxy() { args += ["--control-plane.http-proxy", proxy] }
      try await process.launch(binary: binary, helper: helper, args: args,
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
          logs = URL(string: "api/logs?limit=100", relativeTo: base)?.absoluteURL
          metrics = base.appendingPathComponent("metrics")
        }
        if let health, await ConnectionProbe.ready(health) {
          await readLogs()
          // A verified key is enough to keep the client: it retries flaky polls
          // itself, and snapshot() reports them as reconnecting with the cause.
          if pollState.controlPlaneReached {
            guard !stopped, await process.running else { throw Failure.stopped }
            lastProbe = (ContinuousClock.now, pollState.pollError == nil)
            return
          }
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
      message: ready ? "" : notReadyMessage)
  }

  /// UI polling must not turn into one HTTP probe per tick.
  private func readiness() async -> Bool {
    if let lastProbe, lastProbe.at.duration(to: .now) < .seconds(5) { return lastProbe.ready }
    var ready = false
    if let health, await ConnectionProbe.ready(health) {
      await readLogs()
      ready = pollState.controlPlaneReached && pollState.pollError == nil
    }
    lastProbe = (ContinuousClock.now, ready)
    return ready
  }

  /// tunnel-client's local readiness ignores the control plane, so follow its
  /// own log: metadata fetch proves the key, poll failure/recovery the network.
  /// When the log cannot settle the state (missed events, or no metadata line),
  /// its poll metrics do.
  private func readLogs() async {
    guard let logs, let response = try? await ConnectionProbe.request(logs, limit: 262_144),
      response.status == 200, let events = response.json["events"].array
    else { return }
    let missedEvents = pollState.read(events)
    guard missedEvents || !pollState.controlPlaneReached,
      let last = await lastSuccessfulPoll() else { return }
    pollState.recordSuccess(last, missedEvents: missedEvents)
  }

  /// Log ordering is authoritative; metrics may fill gaps only with newer evidence.
  struct PollState {
    private var logSeq = 0
    private var lastFailureAt: Double?
    private(set) var controlPlaneReached = false
    private(set) var pollError: String?

    mutating func read(_ events: [JSONValue], now: Date = Date()) -> Bool {
      let firstNew = events.compactMap { $0["seq"].int }.filter { $0 > logSeq }.min()
      let missedEvents = logSeq > 0 && (firstNew ?? 0) > logSeq + 1
      for event in events {
        guard let seq = event["seq"].int, seq > logSeq else { continue }
        logSeq = seq
        switch event["message"].string {
        case "tunnel metadata fetched":
          controlPlaneReached = true
        case "poller recovered; polling operational":
          controlPlaneReached = true
          pollError = nil
          lastFailureAt = nil
        case "poll failed; backing off", "poll timed out; backing off":
          pollError = OpenAITunnelProvider.pollReason(event["attrs"]["error"].string ?? "poll timed out")
          // Go's time.Time JSON can include fractional seconds. If the timestamp
          // is missing or invalid, conservatively use when we observed the failure.
          let format = ISO8601DateFormatter()
          format.formatOptions.insert(.withFractionalSeconds)
          let time = event["time"].string ?? ""
          let fractional = format.date(from: time)
          format.formatOptions.remove(.withFractionalSeconds)
          lastFailureAt = (fractional ?? format.date(from: time) ?? now).timeIntervalSince1970
        default:
          break
        }
      }
      return missedEvents
    }

    mutating func recordSuccess(_ last: Double, missedEvents: Bool, now: Date = Date()) {
      guard last.isFinite, last > 0 else { return }
      controlPlaneReached = true
      let age = now.timeIntervalSince1970 - last
      // Metrics have whole-second precision; an equal timestamp cannot prove
      // recovery. An explicit recovery event can still clear the failure.
      if missedEvents, (0..<40).contains(age), last > (lastFailureAt ?? -.infinity) {
        pollError = nil
        lastFailureAt = nil
      }
    }
  }

  /// Unix time of this client's latest successful poll; at most one ~200 KB read per 2 s.
  private func lastSuccessfulPoll() async -> Double? {
    if let lastMetricsCheck, lastMetricsCheck.duration(to: .now) < .seconds(2) { return nil }
    lastMetricsCheck = .now
    guard let metrics, let response = try? await ConnectionProbe.request(metrics, limit: 1_048_576),
      response.status == 200
    else { return nil }
    return Self.lastSuccessfulPoll(String(decoding: response.body, as: UTF8.self))
  }

  static func lastSuccessfulPoll(_ metrics: String) -> Double? {
    for line in metrics.split(separator: "\n")
    where line.hasPrefix("commands_poll_last_successful_timestamp_seconds") {
      if let value = line.split(separator: " ").last.flatMap({ Double($0) }), value > 0 { return value }
    }
    return nil
  }

  /// Drops the request line (`Get "https://…": `) and keeps a bounded cause.
  static func pollReason(_ error: String) -> String {
    var reason = error
    if let range = reason.range(of: #"^[A-Za-z]+ "[^"]*": "#, options: .regularExpression) {
      reason.removeSubrange(range)
    }
    return Budget.prefix(reason.isEmpty ? "unknown error" : reason, bytes: 200)
  }

  /// tunnel-client ignores macOS proxy settings. Hand it the system HTTPS proxy
  /// for OpenAI traffic only; the loopback MCP listener stays direct.
  static func systemProxy() -> String? {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
      settings[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1,
      let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String,
      !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }),
      let port = settings[kCFNetworkProxiesHTTPSPort as String] as? Int, (1...65535).contains(port)
    else { return nil }
    return "http://\(host.contains(":") ? "[\(host)]" : host):\(port)"
  }

  private var notReadyMessage: String {
    if let pollError = pollState.pollError {
      return "Cannot reach OpenAI (\(pollError)). Retrying automatically; check the network or proxy. After changing proxy settings, stop and start Luti."
    }
    return pollState.controlPlaneReached
      ? "OpenAI Tunnel is not ready. Retrying automatically."
      : "OpenAI Tunnel has not reached OpenAI yet. Check network access, runtime-key permissions and workspace association."
  }

  public func stop() async {
    stopped = true
    apiKey = nil
    health = nil
    logs = nil
    metrics = nil
    await process.stop()
  }

  private var startupFailure: Failure {
    Failure("openai_tunnel_unavailable",
             "OpenAI Tunnel did not become ready." + (pollState.pollError.map { " Last error: \($0)." } ?? ""),
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
