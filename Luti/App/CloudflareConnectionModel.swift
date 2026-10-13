import Foundation
import Observation

/// Cloudflare settings and one runtime-bound connection. The app's existing poll
/// drives status and backoff; this model never owns another permanent poll loop.
@MainActor @Observable final class CloudflareConnectionModel {
  var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
  var domain: String
  var tokenDraft = ""
  var tokenSaved: Bool
  var saving = false
  var busy = false
  var connection = ConnectionSnapshot.stopped
  var error: String?
  var authorization = OAuthSnapshot()
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let credentials: KeychainClient
  @ObservationIgnored private let dataRoot: URL
  @ObservationIgnored private let makeProvider: @Sendable (String, URL) throws -> any ConnectionProvider
  @ObservationIgnored private var manager: ConnectionManager?
  @ObservationIgnored private var service: OAuthService?
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var loading: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var context: Context?
  @ObservationIgnored private var retryAt: Date?
  @ObservationIgnored private var failures = 0
  @ObservationIgnored private var retryAllowed = true
  @ObservationIgnored private var closing: Task<Void, Never>?
  private static let domainKey = "connection.cloudflare.v2.domain"
  private static let enabledKey = "connection.cloudflare.v2.enabled"
  private struct Context {
    let router: ToolRouter
    let project: URL
    let helper: URL
  }

  var savedDomain: String { defaults.string(forKey: Self.domainKey) ?? "" }
  var hasUnsavedChanges: Bool { domain.trimmingCharacters(in: .whitespacesAndNewlines) != savedDomain || !tokenDraft.isEmpty }
  var configured: Bool { tokenSaved && (try? CloudflareContract.origin(savedDomain)) != nil }
  var canLaunch: Bool { enabled && configured && !hasUnsavedChanges && !saving }
  var endpoint: String { configured ? savedDomain + "/mcp" : "" }
  var statusKey: String { configured ? "connection.state." + connection.state.rawValue : "connection.notConfigured" }

  init(defaults: UserDefaults, credentials: KeychainClient, dataRoot: URL,
       makeProvider: @escaping @Sendable (String, URL) throws -> any ConnectionProvider = {
         try CloudflareTunnelProvider(token: $0, helper: $1)
       }) {
    self.defaults = defaults
    self.credentials = credentials
    self.dataRoot = dataRoot
    self.makeProvider = makeProvider
    enabled = defaults.bool(forKey: Self.enabledKey)
    domain = defaults.string(forKey: Self.domainKey) ?? ""
    tokenSaved = (try? credentials.exists(CloudflareContract.tokenAccount)) ?? true
  }

  func save(project: URL?) async {
    guard context == nil, !busy, !saving, closing == nil else { return }
    saving = true
    defer { saving = false }
    do {
      let origin = try CloudflareContract.origin(domain.trimmingCharacters(in: .whitespacesAndNewlines))
      let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      if !token.isEmpty {
        try CloudflareContract.validateToken(token)
        let credentials = self.credentials
        try await Task.detached(priority: .userInitiated) {
          try credentials.save(token, CloudflareContract.tokenAccount)
        }.value
      } else if !tokenSaved { throw Failure.invalid("Enter the Cloudflare Tunnel Token.") }
      defaults.set(origin.absoluteString, forKey: Self.domainKey)
      domain = origin.absoluteString
      tokenDraft = ""
      tokenSaved = true
      enabled = true
      error = nil
      loadAuthorizations(project: project)
    } catch { self.error = Failure.safe(error).localizedDescription }
  }

  func clear() async {
    guard context == nil, !busy, !saving, closing == nil else { return }
    saving = true
    defer { saving = false }
    do {
      let credentials = self.credentials
      try await Task.detached(priority: .userInitiated) { try credentials.remove(CloudflareContract.tokenAccount) }.value
      defaults.removeObject(forKey: Self.domainKey)
      domain = ""
      tokenDraft = ""
      tokenSaved = false
      enabled = false
      error = nil
      loadAuthorizations(project: nil)
    } catch { self.error = Failure.safe(error).localizedDescription }
  }

  /// Also works while stopped, so approved apps can be reviewed and revoked
  /// without publishing a listener. Changing projects never reuses another grant.
  func loadAuthorizations(project: URL?) {
    guard context == nil else { return }
    loading?.cancel()
    generation = UUID()
    let revision = generation
    let old = service
    service = nil
    authorization = OAuthSnapshot()
    guard let project, let origin = try? CloudflareContract.origin(savedDomain) else {
      loading = Task { await old?.shutdown() }
      return
    }
    let file = authorizationFile(origin: origin, project: project)
    loading = Task { [weak self] in
      await old?.shutdown()
      do {
        let service = try await Task.detached(priority: .utility) {
          try OAuthService(origin: origin, project: LutiPaths.projectKey(for: project), file: file)
        }.value
        await service.shutdown()
        let snapshot = await service.snapshot()
        guard !Task.isCancelled, let self, self.generation == revision else { return }
        self.service = service
        self.authorization = snapshot
      } catch {
        guard !Task.isCancelled, let self, self.generation == revision else { return }
        self.error = Failure.safe(error).localizedDescription
      }
    }
  }

  private func authorizationFile(origin: URL, project: URL) -> URL {
    let key = OAuthContract.hash(origin.absoluteString + "\n" + LutiPaths.projectKey(for: project))
    return dataRoot.appendingPathComponent("cloudflare-authorizations-v2/" + key + ".json")
  }

  func start(router: ToolRouter, project: URL, helper: URL) {
    guard canLaunch, context == nil, closing == nil else { return }
    context = Context(router: router, project: project, helper: helper)
    failures = 0
    retryAt = nil
    connect(isRetry: false)
  }

  private func connect(isRetry: Bool) {
    guard let context, !busy, operation == nil, closing == nil, canLaunch else { return }
    loading?.cancel()
    loading = nil
    generation = UUID()
    let revision = generation
    let oldService = service
    service = nil
    authorization.pending = []
    busy = true
    error = nil
    retryAllowed = true
    connection = ConnectionSnapshot(state: .starting, providerID: .cloudflare)
    operation = Task { [weak self] in
      guard let self else { return }
      await oldService?.shutdown()
      do {
        let credentials = self.credentials
        let token = try await Task.detached(priority: .userInitiated) {
          try credentials.read(CloudflareContract.tokenAccount, !isRetry)
        }.value
        try Task.checkCancellation()
        guard self.generation == revision else { throw CancellationError() }
        guard let token else {
          self.tokenSaved = false
          throw Failure.invalid("Save a Cloudflare Tunnel Token before connecting.")
        }
        let origin = try CloudflareContract.origin(self.savedDomain)
        let file = self.authorizationFile(origin: origin, project: context.project)
        let service = try await Task.detached(priority: .utility) {
          try OAuthService(origin: origin, project: LutiPaths.projectKey(for: context.project), file: file)
        }.value
        guard !Task.isCancelled, self.generation == revision else { await service.shutdown(); throw CancellationError() }
        self.service = service
        let provider = try self.makeProvider(token, context.helper)
        let manager = ConnectionManager(router: context.router)
        self.manager = manager
        try await manager.connect(provider, oauth: service, port: CloudflareContract.port)
        let snapshot = await manager.snapshot()
        guard self.generation == revision else { return }
        self.connection = snapshot
      } catch {
        guard self.generation == revision else { return }
        await self.service?.shutdown()
        guard self.generation == revision else { return }
        if !(error is CancellationError) {
          self.error = Failure.safe(error).localizedDescription
          self.retryAllowed = (error as? Failure)?.code != "invalid_arguments"
          self.connection = ConnectionSnapshot(state: .failed, message: self.error ?? "", providerID: .cloudflare)
        }
      }
      guard self.generation == revision else { return }
      self.busy = false
      self.operation = nil
    }
  }

  func refresh() async {
    let revision = generation, owned = manager, oauth = service
    let state = busy ? nil : await owned?.snapshot()
    let authorizations = await oauth?.snapshot()
    guard revision == generation else { return }
    if let state, state != connection { connection = state }
    if let authorizations, authorizations != authorization { authorization = authorizations }
    if connection.state == .ready { failures = 0; error = nil }
    guard context != nil, connection.state == .failed, !busy, retryAllowed, canLaunch else { retryAt = nil; return }
    guard let due = retryAt else {
      retryAt = Date().addingTimeInterval(min(5 * pow(2, Double(failures)), 300))
      failures = min(failures + 1, 7)
      return
    }
    guard Date() >= due else { return }
    retryAt = nil
    manager = nil
    connect(isRetry: true)
  }

  func decide(_ id: UUID, allow: Bool) async {
    guard let service else { return }
    do { try await service.decide(id, allow: allow) }
    catch { error = Failure.safe(error).localizedDescription }
    await refresh()
  }

  func revoke(_ id: UUID) async {
    guard let service else { return }
    do { try await service.revoke(id) }
    catch { error = Failure.safe(error).localizedDescription }
    await refresh()
  }

  func stop() async {
    if let closing { await closing.value; return }
    generation = UUID()
    context = nil
    retryAt = nil
    loading?.cancel()
    operation?.cancel()
    let task = operation, load = loading, manager = manager, service = service
    operation = nil
    loading = nil
    self.manager = nil
    busy = true
    let cleanup = Task {
      await service?.shutdown()
      await manager?.shutdown()
      await task?.value
      await load?.value
    }
    closing = cleanup
    await cleanup.value
    closing = nil
    busy = false
    connection = .stopped
    authorization.pending = []
  }
}
