import Foundation

public enum ConnectionState: String, Sendable {
  case stopped, starting, ready, reconnecting, stopping, failed

  public var isActive: Bool { [.starting, .ready, .reconnecting, .stopping].contains(self) }
}

/// Safe to display or log: never contains credentials or child-process output.
public struct ConnectionSnapshot: Sendable, Equatable {
  public let state: ConnectionState
  public let message: String
  public let providerID: ConnectionProviderID?
  public let publicOrigin: URL?
  public init(state: ConnectionState, message: String = "",
              providerID: ConnectionProviderID? = nil, publicOrigin: URL? = nil) {
    self.state = state
    self.message = message
    self.providerID = providerID
    self.publicOrigin = publicOrigin
  }
  public static let stopped = ConnectionSnapshot(state: .stopped)
}

/// Internal transport contract, not a plugin API. A provider owns only transport
/// resources, never the project's router, jobs, files or local credentials.
public protocol ConnectionProvider: Sendable {
  var id: ConnectionProviderID { get }
  /// Public OAuth providers expose their configured origin; private providers such as OpenAI return nil.
  var publicOrigin: URL? { get async }
  var ingressPort: Int { get }
  /// A fresh per-connection credential, never the Local MCP credential or API key.
  var privateCredential: String? { get }
  func start(endpoint: URL) async throws
  func stop() async
  func snapshot() async -> ConnectionSnapshot
}

public extension ConnectionProvider {
  var id: ConnectionProviderID { .cloudflare }
  var privateCredential: String? { nil }
}

/// Optional OAuth ingress has a separate listener and failure domain. Both
/// listeners share one router; disconnecting remote access never stops its jobs.
public actor ConnectionManager {
  private struct Attempt {
    let id: UUID
    let server: MCPServer
    var oauth: LutiOAuthService?
    let provider: any ConnectionProvider
    let store: OAuthStore
    var origin: URL?
    var endpoint: URL?
  }
  private let router: ToolRouter
  private let store: OAuthStore
  private var attempt: Attempt?
  private var state = ConnectionSnapshot.stopped
  private var closing: Task<Void, Never>?
  private var retired = false

  init(router: ToolRouter, store: OAuthStore = .shared) {
    self.router = router
    self.store = store
  }

  public func connect(_ provider: any ConnectionProvider,
                      authorizationStore: OAuthStore? = nil) async throws {
    guard !retired else { throw Failure.stopped }
    guard attempt == nil, closing == nil else {
      throw Failure.invalid("A remote connection is already starting, running or stopping.")
    }
    let selectedStore = authorizationStore ?? store
    let owned = Attempt(id: UUID(), server: MCPServer(), oauth: nil,
                        provider: provider, store: selectedStore, origin: nil, endpoint: nil)
    attempt = owned
    state = ConnectionSnapshot(state: .starting, providerID: provider.id)
    do {
      // Bind first, but answer only 503 until the explicit admission boundary is installed.
      let endpoint = try await owned.server.start(
        router: router, authentication: nil, port: provider.ingressPort)
      try check(owned.id)
      attempt?.endpoint = endpoint
      let configuredOrigin = await provider.publicOrigin
      try check(owned.id)
      if provider.id.usesOAuth {
        if let configuredOrigin {
          try await activatePublic(owned.id, origin: configuredOrigin)
        }
      } else {
        guard let credential = provider.privateCredential, credential.utf8.count >= 32 else {
          throw Failure.invalid("The private tunnel requires a fresh ingress credential.")
        }
        let context = RequestContext(
          transport: provider.id.transport, clientID: "openai-tunnel", clientName: provider.id.title,
          authorizationID: owned.id, scopes: Set(OAuthScope.allCases),
          resource: endpoint.absoluteString)
        try await owned.server.activate(router: router,
          authentication: .delegated(bearer: credential, context: context))
        try check(owned.id)
      }
      try await provider.start(endpoint: endpoint)
      try check(owned.id)
      if provider.id.usesOAuth {
        guard let origin = await provider.publicOrigin else {
          throw Failure.invalid("The provider did not return a public HTTPS origin.")
        }
        try check(owned.id)
        if let configuredOrigin, origin != configuredOrigin {
          throw Failure.invalid("The provider changed its configured public origin.")
        }
        if configuredOrigin == nil { try await activatePublic(owned.id, origin: origin) }
      }
      let result = await provider.snapshot()
      try check(owned.id)
      guard result.state == .ready else {
        throw Failure("connection_not_ready", "The remote provider did not confirm readiness.",
                      "Inspect the connection settings and reconnect explicitly. Local MCP is still available.")
      }
      state = decorate(result)
    } catch {
      if attempt?.id == owned.id {
        await close(final: error is CancellationError ? .stopped : ConnectionSnapshot(
          state: .failed, message: Failure.safe(error).localizedDescription, providerID: provider.id))
      }
      throw error
    }
  }

  private func activatePublic(_ id: UUID, origin: URL) async throws {
    try check(id)
    let url = try ConnectionContract.validatePublicBaseURL(origin.absoluteString)
    guard let owned = attempt, let host = url.host else { throw CancellationError() }
    let canonical = URL(string: "https://" + host)!
    try owned.store.bindOrigin(canonical.absoluteString)
    let oauth = LutiOAuthService(issuer: canonical, store: owned.store,
                                 transport: owned.provider.id.transport)
    attempt?.oauth = oauth
    attempt?.origin = canonical
    try await owned.server.activate(router: router, authentication: .remote(publicHost: host, oauth: oauth))
    try check(id)
  }

  private func decorate(_ result: ConnectionSnapshot) -> ConnectionSnapshot {
    ConnectionSnapshot(state: result.state, message: result.message,
      providerID: attempt?.provider.id,
      publicOrigin: [.ready, .reconnecting].contains(result.state) ? attempt?.origin : nil)
  }

  private func check(_ id: UUID) throws {
    try Task.checkCancellation()
    guard !retired, attempt?.id == id, closing == nil else { throw CancellationError() }
  }

  public func snapshot() async -> ConnectionSnapshot {
    if let owned = attempt, [.ready, .reconnecting].contains(state.state) {
      let result = await owned.provider.snapshot()
      guard attempt?.id == owned.id, closing == nil else { return state }
      if result.state == .failed || result.state == .stopped {
        await close(final: ConnectionSnapshot(state: .failed,
          message: result.message.isEmpty ? "Remote connection stopped. Local MCP is still available." : result.message,
          providerID: owned.provider.id))
      } else {
        state = decorate(result)
      }
    }
    return state
  }

  func doctor() async -> ConnectionDoctorReport? {
    guard let owned = attempt, [.ready, .reconnecting].contains(state.state) else { return nil }
    let report: ConnectionDoctorReport
    if let origin = owned.origin {
      report = await ConnectionDoctor.publicEndpoint(origin)
    } else if let endpoint = owned.endpoint, let credential = owned.provider.privateCredential {
      let transport = await owned.provider.snapshot()
      guard attempt?.id == owned.id, closing == nil else { return nil }
      report = await ConnectionDoctor.privateEndpoint(endpoint, credential: credential,
                                                      transportReady: transport.state == .ready)
    } else { return nil }
    return attempt?.id == owned.id && closing == nil ? report : nil
  }

  public func pendingApprovals() async -> [PendingAuthorization] {
    guard let owned = attempt else { return [] }
    let pending = await owned.oauth?.pendingApprovals() ?? []
    return attempt?.id == owned.id ? pending : []
  }
  public func resolveApproval(_ id: UUID, approved: Bool) async {
    await attempt?.oauth?.resolve(id, approved: approved)
  }

  public func disconnect() async {
    await close(final: .stopped)
  }
  /// Runtime Stop retires the manager so a delayed Connect cannot reopen ingress.
  public func shutdown() async {
    retired = true
    await close(final: .stopped)
  }
  private func close(final: ConnectionSnapshot) async {
    if let closing { await closing.value; return }
    guard let owned = attempt else { state = final; return }
    attempt = nil
    state = ConnectionSnapshot(state: .stopping, providerID: owned.provider.id)
    let task = Task {
      await owned.oauth?.shutdown()
      async let listener: Void = owned.server.stop()
      async let transport: Void = owned.provider.stop()
      _ = await (listener, transport)
      if owned.store.isEphemeral { try? owned.store.reset() }
    }
    closing = task
    await task.value
    closing = nil
    state = retired ? .stopped : final
  }
}
