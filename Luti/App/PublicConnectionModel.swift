import AppKit
import Foundation
import Observation

/// Public HTTPS settings and one runtime-bound connection. The app's existing poll
/// drives status and backoff; this model never owns another permanent poll loop.
@MainActor @Observable final class PublicConnectionModel {
  var enabled: Bool { didSet { defaults.set(enabled, forKey: enabledKey) } }
  var domain: String
  var tokenDraft = ""
  var tokenSaved: Bool
  let providerID: ConnectionProviderID
  var vpsHost: String
  var vpsPort: String
  var vpsHostKey: String
  var vpsKeyReady: Bool
  var saving = false
  var busy = false
  var connection = ConnectionSnapshot.stopped
  var error: String?
  var authorization = OAuthSnapshot()
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let credentials: KeychainClient
  @ObservationIgnored private let dataRoot: URL
  @ObservationIgnored private let makeProvider: @Sendable (String, URL) throws -> any ConnectionProvider
  @ObservationIgnored private let makeVPSProvider: @Sendable (VPSConfiguration, URL, URL, URL) throws -> any ConnectionProvider
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
  @ObservationIgnored private let domainKey: String
  @ObservationIgnored private let enabledKey: String
  private static let vpsKey = "connection.vps.configuration"
  private struct Context {
    let router: ToolRouter
    let project: URL
    let helper: URL
  }

  var savedDomain: String { defaults.string(forKey: domainKey) ?? "" }
  private var savedVPS: VPSConfiguration? {
    guard let data = defaults.data(forKey: Self.vpsKey), let value = try? JSONDecoder().decode(VPSConfiguration.self, from: data) else { return nil }
    return try? VPSConfiguration(host: value.host, port: String(value.port), hostKey: value.hostKey)
  }
  var hasUnsavedChanges: Bool {
    if domain.trimmingCharacters(in: .whitespacesAndNewlines) != savedDomain { return true }
    if providerID == .cloudflare { return !tokenDraft.isEmpty }
    return vpsHost.trimmingCharacters(in: .whitespacesAndNewlines) != (savedVPS?.host ?? "")
      || vpsPort != String(savedVPS?.port ?? 22) || vpsHostKey.trimmingCharacters(in: .whitespacesAndNewlines) != (savedVPS?.hostKey ?? "")
  }
  var configured: Bool {
    (try? PublicConnectionContract.origin(savedDomain)) != nil
      && (providerID == .cloudflare ? tokenSaved : savedVPS != nil && vpsKeyReady)
  }
  var canLaunch: Bool { enabled && configured && !hasUnsavedChanges && !saving }
  var endpoint: String { configured ? savedDomain + "/mcp" : "" }
  var statusKey: String {
    if connection.state != .stopped { return "connection.state." + connection.state.rawValue }
    return configured ? "connection.state.stopped" : "connection.notConfigured"
  }

  init(defaults: UserDefaults, credentials: KeychainClient, dataRoot: URL, providerID: ConnectionProviderID = .cloudflare,
       makeProvider: @escaping @Sendable (String, URL) throws -> any ConnectionProvider = {
         try CloudflareTunnelProvider(token: $0, helper: $1)
       }, makeVPSProvider: @escaping @Sendable (VPSConfiguration, URL, URL, URL) throws -> any ConnectionProvider = {
         try VPSTunnelProvider(configuration: $0, origin: $1, identity: $2, helper: $3)
       }) {
    precondition(providerID.requiresOAuth)
    self.providerID = providerID
    let domainKey = providerID == .vps ? "connection.vps.domain" : "connection.cloudflare.v2.domain"
    let enabledKey = providerID == .vps ? "connection.vps.enabled" : "connection.cloudflare.v2.enabled"
    self.domainKey = domainKey
    self.enabledKey = enabledKey
    self.defaults = defaults
    self.credentials = credentials
    self.dataRoot = dataRoot
    self.makeProvider = makeProvider
    self.makeVPSProvider = makeVPSProvider
    enabled = defaults.bool(forKey: enabledKey)
    domain = defaults.string(forKey: domainKey) ?? ""
    tokenSaved = providerID == .cloudflare ? ((try? credentials.exists(CloudflareContract.tokenAccount)) ?? true) : false
    let saved = defaults.data(forKey: Self.vpsKey).flatMap { try? JSONDecoder().decode(VPSConfiguration.self, from: $0) }
    vpsHost = saved?.host ?? ""
    vpsPort = String(saved?.port ?? 22)
    vpsHostKey = saved?.hostKey ?? ""
    vpsKeyReady = FileManager.default.fileExists(atPath: VPSIdentity.key(in: dataRoot).path)
  }

  func save() async {
    guard context == nil, !busy, !saving, closing == nil else { return }
    saving = true
    defer { saving = false }
    do {
      let origin = try PublicConnectionContract.origin(domain.trimmingCharacters(in: .whitespacesAndNewlines))
      let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      if providerID == .vps {
        let value = try VPSConfiguration(host: vpsHost, port: vpsPort, hostKey: vpsHostKey)
        let root = dataRoot
        _ = try await Task.detached(priority: .userInitiated) { try VPSIdentity.prepare(in: root) }.value
        defaults.set(try JSONEncoder().encode(value), forKey: Self.vpsKey)
        vpsHost = value.host
        vpsPort = String(value.port)
        vpsHostKey = value.hostKey
        vpsKeyReady = true
      } else if !token.isEmpty {
        try CloudflareContract.validateToken(token)
        let credentials = self.credentials
        try await Task.detached(priority: .userInitiated) {
          try credentials.save(token, CloudflareContract.tokenAccount)
        }.value
      } else if !tokenSaved { throw Failure.invalid("Enter the Cloudflare Tunnel Token.") }
      defaults.set(origin.absoluteString, forKey: domainKey)
      domain = origin.absoluteString
      tokenDraft = ""
      if providerID == .cloudflare { tokenSaved = true }
      enabled = true
      error = nil
      loadAuthorizations()
    } catch { self.error = Failure.safe(error).localizedDescription }
  }

  func vpsSetupScript() async -> String? {
    guard context == nil, !busy, !saving, closing == nil else { return nil }
    saving = true
    defer { saving = false }
    do {
      _ = try VPSConfiguration.validateHost(vpsHost)
      let origin = try PublicConnectionContract.origin(domain.trimmingCharacters(in: .whitespacesAndNewlines))
      let root = dataRoot
      let script = try await Task.detached(priority: .userInitiated) { try VPSIdentity.setupScript(origin: origin, root: root) }.value
      vpsKeyReady = true
      error = nil
      return script
    } catch { self.error = Failure.safe(error).localizedDescription; return nil }
  }

  func clear() async {
    guard context == nil, !busy, !saving, closing == nil else { return }
    saving = true
    defer { saving = false }
    do {
      let credentials = self.credentials
      if providerID == .cloudflare {
        try await Task.detached(priority: .userInitiated) { try credentials.remove(CloudflareContract.tokenAccount) }.value
        tokenSaved = false
      }
      defaults.removeObject(forKey: domainKey)
      domain = ""
      tokenDraft = ""
      if providerID == .vps { defaults.removeObject(forKey: Self.vpsKey) }
      vpsHost = ""
      vpsPort = "22"
      vpsHostKey = ""
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
    guard let origin = try? PublicConnectionContract.origin(savedDomain) else {
      loading = Task { await old?.shutdown() }
      return
    }
    let dataRoot = self.dataRoot
    let transport = providerID.transport
    loading = Task { [weak self] in
      await old?.shutdown()
      do {
        let service = try await Task.detached(priority: .utility) {
          let file = Self.authorizationFile(dataRoot: dataRoot, origin: origin, transport: transport)
          return try OAuthService(origin: origin, file: file, transport: transport)
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

  nonisolated private static func authorizationFile(dataRoot: URL, origin: URL, transport: TransportProviderID) -> URL {
    let dir = dataRoot.appendingPathComponent(transport == .vps ? "vps-authorizations-v1" : "cloudflare-authorizations-v2")
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
    connection = ConnectionSnapshot(state: .starting, providerID: providerID)
    operation = Task { [weak self] in
      guard let self else { return }
      await oldService?.shutdown()
      do {
        let origin = try PublicConnectionContract.origin(self.savedDomain)
        let dataRoot = self.dataRoot
        let transport = self.providerID.transport
        let provider: any ConnectionProvider
        if self.providerID == .vps {
          guard let configuration = self.savedVPS else { throw Failure.invalid("Save the VPS configuration before connecting.") }
          let identity = try await Task.detached(priority: .userInitiated) { try VPSIdentity.prepare(in: dataRoot) }.value
          provider = try self.makeVPSProvider(configuration, origin, identity, context.helper)
        } else {
          let credentials = self.credentials
          let token = try await Task.detached(priority: .userInitiated) {
            try credentials.read(CloudflareContract.tokenAccount, !isRetry)
          }.value
          guard let token else {
            self.tokenSaved = false
            throw Failure.invalid("Save a Cloudflare Tunnel Token before connecting.")
          }
          provider = try self.makeProvider(token, context.helper)
        }
        try Task.checkCancellation()
        guard self.generation == revision else { throw CancellationError() }
        let service = try await Task.detached(priority: .utility) {
          let file = Self.authorizationFile(dataRoot: dataRoot, origin: origin, transport: transport)
          return try OAuthService(origin: origin, file: file, transport: transport)
        }.value
        guard !Task.isCancelled, self.generation == revision else { await service.shutdown(); throw CancellationError() }
        self.service = service
        let manager = ConnectionManager(router: context.router)
        self.manager = manager
        try await manager.connect(provider, oauth: service, port: PublicConnectionContract.port(for: self.providerID))
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
          self.connection = ConnectionSnapshot(state: .failed, message: self.error ?? "", providerID: self.providerID)
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
