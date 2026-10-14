import AppKit
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
  @ObservationIgnored private var announcedApprovals: Set<UUID> = []
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
  var statusKey: String {
    if connection.state != .stopped { return "connection.state." + connection.state.rawValue }
    return configured ? "connection.state.stopped" : "connection.notConfigured"
  }

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

  func save() async {
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
      loadAuthorizations()
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
      loadAuthorizations()
    } catch { self.error = Failure.safe(error).localizedDescription }
  }

  /// Also works while stopped or before a project is selected, so approved apps
  /// persist across project changes and can be reviewed or revoked at any time.
  func loadAuthorizations() {
    guard context == nil else { return }
    loading?.cancel()
    generation = UUID()
    let revision = generation
    let old = service
    service = nil
    authorization = OAuthSnapshot()
    announcedApprovals.removeAll()
    guard let origin = try? CloudflareContract.origin(savedDomain) else {
      loading = Task { await old?.shutdown() }
      return
    }
    let dataRoot = self.dataRoot
    loading = Task { [weak self] in
      await old?.shutdown()
      do {
        let service = try await Task.detached(priority: .utility) {
          let file = Self.authorizationFile(dataRoot: dataRoot, origin: origin)
          return try OAuthService(origin: origin, file: file)
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

  private struct ResourceHeader: Decodable {
    let resource: String
  }

  nonisolated private static func authorizationFile(dataRoot: URL, origin: URL) -> URL {
    let dir = dataRoot.appendingPathComponent("cloudflare-authorizations-v2")
    let target = dir.appendingPathComponent(OAuthContract.hash(origin.absoluteString) + ".json")
    if !FileManager.default.fileExists(atPath: target.path) {
      let resource = origin.absoluteString + "/mcp"
      let candidates = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
      )) ?? []
      let matching = candidates
        .filter { $0.pathExtension == "json" && $0.lastPathComponent != target.lastPathComponent }
        .sorted {
          let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
          let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
          return lhs > rhs
        }
      for candidate in matching {
        if let data = try? PrivateFiles.read(candidate, max: 4_194_304),
          let header = try? JSONDecoder().decode(ResourceHeader.self, from: data),
          header.resource == resource
        {
          try? FileManager.default.moveItem(at: candidate, to: target)
          break
        }
      }
    }
    return target
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
    announcedApprovals.removeAll()
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
        let dataRoot = self.dataRoot
        let service = try await Task.detached(priority: .utility) {
          let file = Self.authorizationFile(dataRoot: dataRoot, origin: origin)
          return try OAuthService(origin: origin, file: file)
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
        let failedManager = self.manager
        self.manager = nil
        await failedManager?.shutdown()
        await self.service?.shutdown()
        guard self.generation == revision else { return }
        if !(error is CancellationError) {
          self.error = Failure.safe(error).localizedDescription
          self.retryAllowed = ConnectionContract.isRetryable(error)
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
    let pendingIDs = Set(authorization.pending.map(\.id))
    if !pendingIDs.subtracting(announcedApprovals).isEmpty {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    announcedApprovals = pendingIDs
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
    authorization.pending.removeAll { $0.id == id }
    announcedApprovals.remove(id)
    do { try await service.decide(id, allow: allow) }
    catch { self.error = Failure.safe(error).localizedDescription }
    await refresh()
  }

  func revoke(_ id: UUID) async {
    guard let service else { return }
    do { try await service.revoke(id) }
    catch { self.error = Failure.safe(error).localizedDescription }
    await refresh()
  }

  func stop() async {
    if let closing { await closing.value; return }
    let previousProject = context?.project
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
    announcedApprovals.removeAll()
    if previousProject != nil { error = nil }
    if self.service == nil {
      loadAuthorizations()
    }
  }
}
