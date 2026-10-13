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
  public init(state: ConnectionState, message: String = "", providerID: ConnectionProviderID? = nil) {
    self.state = state
    self.message = message
    self.providerID = providerID
  }
  public static let stopped = ConnectionSnapshot(state: .stopped)
}

/// Internal transport contract, not a plugin API. A provider owns only transport
/// resources, never the project's router, jobs, files or local credentials.
public protocol ConnectionProvider: Sendable {
  var id: ConnectionProviderID { get }
  /// A fresh per-connection credential the transport presents to the private listener.
  var privateCredential: String { get }
  func start(endpoint: URL) async throws
  func stop() async
  func snapshot() async -> ConnectionSnapshot
}

/// One remote connection: a private loopback listener plus the transport that
/// forwards to it. It shares the runtime's router; disconnecting never stops jobs.
public actor ConnectionManager {
  private struct Attempt {
    let id: UUID
    let server: MCPServer
    let provider: any ConnectionProvider
  }
  private let router: ToolRouter
  private var attempt: Attempt?
  private var state = ConnectionSnapshot.stopped
  private var closing: Task<Void, Never>?
  private var retired = false

  init(router: ToolRouter) {
    self.router = router
  }

  public func connect(_ provider: any ConnectionProvider, oauth: OAuthService? = nil, port: Int = 0) async throws {
    guard !retired else { throw Failure.stopped }
    guard attempt == nil, closing == nil else {
      throw Failure.invalid("A remote connection is already starting, running or stopping.")
    }
    let owned = Attempt(id: UUID(), server: MCPServer(), provider: provider)
    attempt = owned
    state = ConnectionSnapshot(state: .starting, providerID: provider.id)
    do {
      guard oauth != nil || provider.privateCredential.utf8.count >= 32 else {
        throw Failure.invalid("The private tunnel requires a fresh ingress credential.")
      }
      let context = RequestContext(
        transport: provider.id.transport, clientID: provider.id.rawValue + "-tunnel",
        clientName: provider.id.title, authorizationID: owned.id)
      guard (provider.id == .cloudflare) == (oauth != nil) else {
        throw Failure.invalid("Public ingress requires local OAuth authorization.")
      }
      let authentication: MCPAuthentication = oauth.map(MCPAuthentication.oauth)
        ?? .delegated(bearer: provider.privateCredential, context: context)
      let endpoint = try await owned.server.start(router: router, authentication: authentication, port: port)
      try check(owned.id)
      try await provider.start(endpoint: endpoint)
      try check(owned.id)
      let result = await provider.snapshot()
      try check(owned.id)
      guard [.ready, .reconnecting].contains(result.state) else {
        throw Failure("connection_not_ready", "The remote provider did not confirm readiness.",
                      "Inspect the connection settings and reconnect explicitly. Project tasks keep running.")
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

  private func decorate(_ result: ConnectionSnapshot) -> ConnectionSnapshot {
    ConnectionSnapshot(state: result.state, message: result.message, providerID: attempt?.provider.id)
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
          message: result.message.isEmpty ? "Remote connection stopped. Project tasks keep running." : result.message,
          providerID: owned.provider.id))
      } else {
        state = decorate(result)
      }
    }
    return state
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
      async let listener: Void = owned.server.stop()
      async let transport: Void = owned.provider.stop()
      _ = await (listener, transport)
    }
    closing = task
    await task.value
    closing = nil
    state = retired ? .stopped : final
  }
}
