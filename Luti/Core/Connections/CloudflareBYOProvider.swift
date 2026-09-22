import Foundation

/// The existing pinned cloudflared implementation, behind the transport boundary.
/// Every Connect gets a fresh provider. Preparation happens only after Connect,
/// never on the Local MCP startup path.
public actor CloudflareBYOProvider: ConnectionProvider {
  public nonisolated let publicOrigin: URL?
  public nonisolated var ingressPort: Int { TunnelContract.defaultPort }
  private let helper: URL
  private var tunnelToken: String?
  private let tunnel: TunnelManager
  private var started = false
  private var stopped = false

  public init(publicOrigin: URL, tunnelToken: String, helper: URL, activity: ActivityStore) throws {
    self.publicOrigin = try ConnectionContract.validatePublicBaseURL(publicOrigin.absoluteString)
    try TunnelContract.validateToken(tunnelToken)
    self.tunnelToken = tunnelToken
    self.helper = helper
    tunnel = TunnelManager(activity: activity)
  }

  public func start(endpoint: URL) async throws {
    guard !started, !stopped, let token = tunnelToken, let publicOrigin else { throw Failure.stopped }
    started = true
    let binary = try await TunnelInstaller.prepare()
    try Task.checkCancellation()
    guard !stopped else { throw Failure.stopped }
    try await tunnel.start(binary: binary, helper: helper, endpoint: endpoint,
                           publicBaseURL: publicOrigin, tunnelToken: token)
    try Task.checkCancellation()
    guard !stopped else { throw Failure.stopped }
  }

  public func snapshot() async -> ConnectionSnapshot {
    let result = await tunnel.snapshot()
    return ConnectionSnapshot(state: ConnectionState(rawValue: result.state) ?? .failed,
                              message: result.message)
  }

  public func stop() async {
    stopped = true
    tunnelToken = nil
    await tunnel.stop()
  }
}
