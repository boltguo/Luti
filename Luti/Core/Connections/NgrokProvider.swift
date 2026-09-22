import Foundation

/// A fixed HTTPS domain from the user's ngrok account. Random ngrok addresses
/// are intentionally not another Quick provider: OAuth needs a stable issuer.
public actor NgrokProvider: ConnectionProvider {
  public nonisolated let id = ConnectionProviderID.ngrok
  public nonisolated let ingressPort = 0
  public nonisolated let publicOrigin: URL?
  private let helper: URL
  private var authtoken: String?
  private let process = ProviderProcess()
  private var endpoint: URL?
  private var started = false
  private var stopped = false
  private let health = URL(string: "http://127.0.0.1:39395/api/tunnels")!

  static let configuration = """
    version: "3"
    agent:
      web_addr: 127.0.0.1:39395
      update_check: false
      remote_management: false
    """

  public init(publicOrigin: URL, authtoken: String, helper: URL) throws {
    let validated = try ConnectionContract.validatePublicBaseURL(publicOrigin.absoluteString)
    self.publicOrigin = URL(string: "https://" + validated.host!)!
    try ConnectionContract.validateCredential(authtoken, provider: .ngrok)
    self.authtoken = authtoken
    self.helper = helper
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let authtoken, let publicOrigin else { throw Failure.stopped }
    started = true
    self.endpoint = endpoint
    do {
      try ConnectionContract.validateIngressEndpoint(endpoint)
      let binary = try await ConnectionExecutables.ngrok()
      try Task.checkCancellation()
      guard !stopped else { throw Failure.stopped }
      let directory = try await process.prepareDirectory()
      guard !stopped else { throw Failure.stopped }
      let config = directory.appendingPathComponent("ngrok.yml")
      // Only non-secret settings go to a private run file. The account credential
      // is never given to `ngrok config add-authtoken` or placed in argv.
      try PrivateFiles.atomicWrite(Data(Self.configuration.utf8), to: config)
      try await process.launch(binary: binary, helper: helper,
        args: ["http", endpoint.deletingLastPathComponent().absoluteString,
               "--url", publicOrigin.absoluteString, "--config", config.path,
               "--log", "stdout", "--log-format", "json", "--log-level", "info", "--inspect=false"],
        environment: ["NGROK_AUTHTOKEN": authtoken], secrets: [authtoken])
      let deadline = ContinuousClock.now.advanced(by: .seconds(45))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        guard !stopped, await process.running else { throw startupFailure }
        if await ready() {
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

  static func matches(_ json: JSONValue, origin: URL, endpoint: URL) -> Bool {
    json["tunnels"].array?.contains { tunnel in
      guard tunnel["public_url"].string == origin.absoluteString,
        let raw = tunnel["config"]["addr"].string, let upstream = URL(string: raw)
      else { return false }
      return upstream.scheme == "http" && upstream.host == "127.0.0.1"
        && upstream.port == endpoint.port && ["", "/"].contains(upstream.path)
        && upstream.user == nil && upstream.password == nil
        && upstream.query == nil && upstream.fragment == nil
    } == true
  }

  private func ready() async -> Bool {
    guard let origin = publicOrigin, let endpoint,
      let response = try? await ConnectionProbe.request(health), response.status == 200
    else { return false }
    return Self.matches(response.json, origin: origin, endpoint: endpoint)
  }

  public func snapshot() async -> ConnectionSnapshot {
    guard !stopped, started else { return .stopped }
    guard await process.running else {
      return ConnectionSnapshot(state: .failed, message: startupFailure.message)
    }
    let healthy = await ready()
    guard !stopped else { return .stopped }
    return ConnectionSnapshot(state: healthy ? .ready : .reconnecting,
      message: healthy ? "" : "ngrok is reconnecting or the public domain does not match this connection.")
  }

  public func stop() async {
    stopped = true
    authtoken = nil
    endpoint = nil
    await process.stop()
  }

  private var startupFailure: Failure {
    Failure("ngrok_unavailable", "ngrok did not confirm the configured HTTPS endpoint.",
            "Check the account authtoken, assigned domain and port 39395. Local MCP is unaffected.")
  }
}
