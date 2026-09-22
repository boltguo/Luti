import Foundation

/// OpenAI is an outbound-only, workspace-authorized transport, not public HTTPS
/// ingress. Its private MCP listener has a fresh delegated credential; it never
/// uses the owner's Local MCP credential and never pretends to expose OAuth.
public actor OpenAITunnelProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.openAI
  public nonisolated let ingressPort = 0
  public nonisolated let publicOrigin: URL? = nil
  public nonisolated let privateCredential: String? = OAuthContract.newClientSecret()
  private let tunnelID: String
  private let helper: URL
  private var apiKey: String?
  private let process = ProviderProcess()
  private var health: URL?
  private var started = false
  private var stopped = false

  public init(tunnelID: String, apiKey: String, helper: URL) throws {
    try ConnectionContract.validateTunnelID(tunnelID)
    try ConnectionContract.validateCredential(apiKey, provider: .openAI)
    self.tunnelID = tunnelID
    self.apiKey = apiKey
    self.helper = helper
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let apiKey, let privateCredential else { throw Failure.stopped }
    started = true
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      let binary = try await ConnectionExecutables.openAI()
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
    let ready: Bool
    if let health { ready = await ConnectionProbe.ready(health) } else { ready = false }
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: ready ? .ready : .reconnecting,
      message: ready ? "" : "OpenAI Tunnel is not ready. Check network access, runtime-key permissions and workspace association.")
  }

  public func stop() async {
    stopped = true
    apiKey = nil
    health = nil
    await process.stop()
  }

  private var startupFailure: Failure {
    Failure("openai_tunnel_unavailable", "OpenAI Tunnel did not become ready.",
            "Check the tunnel_id, runtime API key with Tunnels Read + Use, and the target workspace association. Local MCP is unaffected.")
  }
}
