import AppKit
import Foundation
import Observation

@MainActor @Observable final class AppModel {
  enum Phase: String { case stopped, preparing, starting, running, stopping, failed }
  var phase: Phase = .stopped
  var activeProject: ApprovedProject?
  var project: URL? { activeProject?.url }
  var publicBaseURL: String
  var tokenDraft = ""
  var tokenSaved = false
  var doctorReports: [ConnectionProviderID: ConnectionDoctorReport] = [:]
  var doctorBusy: ConnectionProviderID?
  @ObservationIgnored private var authorizationStores: [ConnectionProviderID: OAuthStore] = [:]
  var activity: [ActivityEvent] = []
  var currentRunID: UUID?
  var connectionSnapshots: [ConnectionProviderID: ConnectionSnapshot] = [:]
  var connectionBusyProviders: Set<ConnectionProviderID> = []
  var connectionErrors: [ConnectionProviderID: String] = [:]
  var detail = "Choose a project to get started."
  var lastCall: Date?
  var activeJobs = 0
  var errorText: String?
  var connectionSettingsErrors: [ConnectionProviderID: String] = [:]
  let contextDataRoot: URL
  var contextBusy = false
  /// Connection requests waiting for an answer. The first one drives a sheet; the
  /// rest queue behind it so two Hosts cannot race one dialog.
  var pendingApprovals: [PendingAuthorization] = []
  var remoteClients = 0
  @ObservationIgnored private var session: RuntimeCore?
  @ObservationIgnored private var connections: [ConnectionProviderID: ConnectionManager] = [:]
  @ObservationIgnored private var connectionTasks: [ConnectionProviderID: Task<Void, Never>] = [:]
  @ObservationIgnored private var connectionRevisions: [ConnectionProviderID: UUID] = [:]
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var activityFeed: Task<Void, Never>?
  @ObservationIgnored private var teardown: Task<Void, Never>?
  @ObservationIgnored private var cachedTunnelToken: String?
  @ObservationIgnored private var announcedApprovals: Set<UUID> = []
  @ObservationIgnored private var revision = UUID()
  @ObservationIgnored private let defaults: UserDefaults
  private static let selectedFolderKey = "selectedFolder"
  private static let approvedProjectsKey = "approvedProjects"
  private static let activeProjectIDKey = "activeProjectID"
  private static let publicBaseURLKey = "publicBaseURL"
  private static let legacyActiveConnectionProviderKey = "activeConnectionProvider"
  var active: Bool { [.preparing, .starting, .running, .stopping].contains(phase) }
  var savedPublicBaseURL: String { defaults.string(forKey: Self.publicBaseURLKey) ?? "" }
  var hasSavedPublicBaseURL: Bool { !savedPublicBaseURL.isEmpty && publicBaseURL == savedPublicBaseURL }
  var hasUnsavedConnection: Bool { publicBaseURL != savedPublicBaseURL || !tokenDraft.isEmpty }
  var cloudflareConfigured: Bool {
    tokenSaved && !savedPublicBaseURL.isEmpty
      && (try? ConnectionContract.validatePublicBaseURL(savedPublicBaseURL)) != nil
  }
  var availableConnectionProviders: [ConnectionProviderID] {
    cloudflareConfigured ? [.cloudflare] : []
  }
  var cloudflareStatusKey: String {
    let state = providerSnapshot(.cloudflare).state
    if state != .stopped { return "connection.state." + state.rawValue }
    return cloudflareConfigured ? "connection.state.stopped" : "connection.notConfigured"
  }
  var canStart: Bool {
    !active && !contextBusy && activeProject != nil
  }
  init(contextDataRoot: URL = LutiPaths.root, defaults: UserDefaults = .standard) {
    self.contextDataRoot = contextDataRoot
    self.defaults = defaults
    publicBaseURL = defaults.string(forKey: Self.publicBaseURLKey) ?? ""
    if let data = defaults.data(forKey: Self.selectedFolderKey) {
      activeProject = try? JSONDecoder().decode(ApprovedProject.self, from: data)
    } else if let data = defaults.data(forKey: Self.approvedProjectsKey),
              let stored = try? JSONDecoder().decode([ApprovedProject].self, from: data) {
      let storedActive = defaults.string(forKey: Self.activeProjectIDKey)
      activeProject = stored.first(where: { $0.id == storedActive }) ?? stored.first
    }
    defaults.removeObject(forKey: Self.approvedProjectsKey)
    defaults.removeObject(forKey: Self.activeProjectIDKey)

    tokenSaved = KeychainService.exists()
    defaults.removeObject(forKey: "enabledConnectionProviders")
    defaults.removeObject(forKey: Self.legacyActiveConnectionProviderKey)

    persistSelectedFolder()
    reloadStoredActivity()
    LocalLogStore.runtime("info", "Luti app initialized.")
  }

  private func persistSelectedFolder() {
    if let activeProject, let data = try? JSONEncoder().encode(activeProject) {
      defaults.set(data, forKey: Self.selectedFolderKey)
    } else {
      defaults.removeObject(forKey: Self.selectedFolderKey)
    }
  }

  func beginObserving() {
    guard polling == nil else { return }
    polling = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.refresh()
        let delay: Duration = self.active ? .milliseconds(750) : .milliseconds(1500)
        do { try await Task.sleep(for: delay) } catch { return }
      }
    }
  }
  private func bindActivity(_ runtime: RuntimeCore, token: UUID) {
    activityFeed?.cancel()
    currentRunID = runtime.runID
    activityFeed = Task { [weak self] in
      let stream = await runtime.activityUpdates()
      for await events in stream {
        guard !Task.isCancelled else { return }
        guard let self, self.revision == token else { return }
        self.activity = Array(events.prefix(200))
        self.currentRunID = runtime.runID
      }
    }
  }

  func chooseProject() {
    guard !active, !contextBusy, activeProject == nil else { return }
    let panel = NSOpenPanel()
    panel.title = L10n.text("app.chooseProjectsLutiEdit")
    panel.prompt = L10n.text("projects.addProject")
    panel.allowedContentTypes = []
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor [weak self] in
        self?.addProject(url)
      }
    }
  }

  func addProject(_ url: URL) {
    guard !active, !contextBusy, activeProject == nil else { return }
    let project = ApprovedProject(url: url)
    activeProject = project
    persistSelectedFolder()
    errorText = nil
    detail = "Project approved. Start when you are ready."
    reloadStoredActivity()
    LocalLogStore.runtime("info", "Project folder added.")
  }

  func removeProject(_ id: String) {
    guard !active, !contextBusy, activeProject?.id == id else { return }
    activeProject = nil
    persistSelectedFolder()
    errorText = nil
    detail = "Choose a folder to get started."
    reloadStoredActivity()
  }

  private func reloadStoredActivity() {
    guard !active else { return }
    currentRunID = nil
    guard let project else { activity = []; return }
    let directory = LocalLogStore.activityDirectory(for: project, dataRoot: contextDataRoot)
    activity = Array(LocalLogStore.recentActivities(limit: 200, directory: directory).reversed())
  }

  func clearProjectActivity(_ project: ApprovedProject) async throws {
    guard !active, !contextBusy, activeProject == project else {
      throw Failure.invalid("Stop the runtime before clearing the selected folder's activity.")
    }
    contextBusy = true
    defer { contextBusy = false }
    let directory = LocalLogStore.activityDirectory(for: project.url, dataRoot: contextDataRoot)
    try await Task.detached(priority: .utility) {
      try LocalLogStore.clearActivities(directory: directory)
    }.value
    reloadStoredActivity()
  }

  func isConnectionProviderConfigured(_ id: ConnectionProviderID) -> Bool {
    cloudflareConfigured
  }

  func configuredMCPServerURL(_ id: ConnectionProviderID) -> URL? {
    guard isConnectionProviderConfigured(id),
      let origin = try? ConnectionContract.validatePublicBaseURL(savedPublicBaseURL)
    else { return nil }
    return origin.appendingPathComponent("mcp")
  }

  func providerSnapshot(_ id: ConnectionProviderID) -> ConnectionSnapshot {
    connectionSnapshots[id] ?? .stopped
  }

  func providerConnectionError(_ id: ConnectionProviderID) -> String? {
    connectionErrors[id]
  }

  func isProviderConnectionBusy(_ id: ConnectionProviderID) -> Bool {
    connectionBusyProviders.contains(id)
  }

  func canEditConnection(_ id: ConnectionProviderID) -> Bool {
    !isProviderConnectionBusy(id) && !providerSnapshot(id).state.isActive
      && ![.preparing, .starting, .stopping].contains(phase)
  }

  func canConnectProvider(_ id: ConnectionProviderID) -> Bool {
    phase == .running && !isProviderConnectionBusy(id)
      && !providerSnapshot(id).state.isActive
      && isConnectionProviderConfigured(id)
      && !hasUnsavedConnection
  }

  func authorizationStore(for id: ConnectionProviderID) -> OAuthStore {
    if let existing = authorizationStores[id] { return existing }
    let store: OAuthStore
    if contextDataRoot == LutiPaths.root {
      store = .shared
    } else {
      store = OAuthStore(url: contextDataRoot.appendingPathComponent("auth/oauth.json"))
    }
    authorizationStores[id] = store
    return store
  }

  func diagnoseConnection(_ id: ConnectionProviderID) async {
    guard doctorBusy == nil,
      [.ready, .reconnecting].contains(providerSnapshot(id).state),
      let connection = connections[id] else { return }
    let operation = connectionRevisions[id]
    doctorBusy = id
    doctorReports[id] = nil
    let report = await connection.doctor()
    guard operation == connectionRevisions[id] else {
      if doctorBusy == id { doctorBusy = nil }
      return
    }
    doctorBusy = nil
    if [.ready, .reconnecting].contains(providerSnapshot(id).state) {
      doctorReports[id] = report
    }
  }

  @discardableResult
  func saveSettings() -> Bool {
    guard canEditConnection(.cloudflare) else { return false }
    do {
      let base = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let url = try ConnectionContract.validatePublicBaseURL(base)
      let canonical = "https://" + (url.host ?? "")
      if !tokenDraft.isEmpty { try TunnelContract.validateToken(tokenDraft.trimmed) }
      if canonical != savedPublicBaseURL || !tokenDraft.isEmpty {
        try authorizationStore(for: .cloudflare).reset()
      }
      if !tokenDraft.isEmpty {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainService.save(token)
        cachedTunnelToken = token
      }
      guard KeychainService.exists() else {
        throw Failure.invalid(L10n.text("app.enterTunnelTokenSaving"))
      }
      // Store the normalized origin, never the raw text: it becomes the issuer.
      doctorReports[.cloudflare] = nil
      defaults.set(canonical, forKey: Self.publicBaseURLKey)
      publicBaseURL = canonical
      tokenDraft = ""
      tokenSaved = true
      connectionSnapshots[.cloudflare] = nil
      connectionSettingsErrors[.cloudflare] = nil
      connectionErrors[.cloudflare] = nil
      errorText = nil
      if phase == .running {
        connectRemote(.cloudflare)
      }
      return true
    } catch {
      connectionSettingsErrors[.cloudflare] = Failure.safe(error).localizedDescription
      return false
    }
  }

  @discardableResult
  func forgetToken() -> Bool {
    guard canEditConnection(.cloudflare) else { return false }
    do {
      try authorizationStore(for: .cloudflare).reset()
      doctorReports[.cloudflare] = nil
      try KeychainService.remove()
      cachedTunnelToken = nil
      tokenDraft = ""
      tokenSaved = false
      connectionSnapshots[.cloudflare] = nil
      connectionSettingsErrors[.cloudflare] = nil
      return true
    } catch {
      connectionSettingsErrors[.cloudflare] = Failure.safe(error).localizedDescription
      return false
    }
  }

  @discardableResult
  func clearCloudflareConfiguration() -> Bool {
    guard canEditConnection(.cloudflare) else { return false }
    do {
      try authorizationStore(for: .cloudflare).reset()
      doctorReports[.cloudflare] = nil
      try KeychainService.remove()
      cachedTunnelToken = nil
      tokenDraft = ""
      tokenSaved = false
      connectionSnapshots[.cloudflare] = nil
      publicBaseURL = ""
      defaults.removeObject(forKey: Self.publicBaseURLKey)
      connectionSettingsErrors[.cloudflare] = nil
      connectionErrors[.cloudflare] = nil
      return true
    } catch {
      connectionSettingsErrors[.cloudflare] = Failure.safe(error).localizedDescription
      return false
    }
  }
  func requestStart() {
    guard canStart, let selectedProject = activeProject else { return }
    let root = selectedProject.url
    let policy = ProjectExecutionPolicy.fullLocal(localApproval: true)
    errorText = nil
    connectionErrors = [:]
    connectionSnapshots = [:]
    connectionBusyProviders = []
    activityFeed?.cancel()
    activityFeed = nil
    currentRunID = nil
    lastCall = nil
    activeJobs = 0
    phase = .preparing
    detail = "Preparing the local project runtime."
    let token = UUID()
    revision = token
    startup = Task { [weak self] in
      guard let self else { return }
      var owned: RuntimeCore?
      do {
        try Task.checkCancellation()
        guard self.revision == token else { throw CancellationError() }
        let runtime = try RuntimeCore(
          root: root, helper: Self.processHelper, executionPolicy: policy,
          project: selectedProject,
          contextDataRoot: self.contextDataRoot)
        owned = runtime
        self.session = runtime
        self.bindActivity(runtime, token: token)
        self.phase = .starting
        try await runtime.start()
        try Task.checkCancellation()
        guard self.revision == token else { throw CancellationError() }
        self.phase = .running
        self.detail = "Project runtime is running."
        LocalLogStore.runtime(
          "info", "Local folder runtime started.")
        // Every enabled provider is part of the Home launch context. Each owns
        // an independent listener and failure domain while sharing this runtime.
        for provider in self.availableConnectionProviders {
          self.connectRemote(provider)
        }
      } catch {
        if let owned { await owned.stop() }
        guard self.revision == token else { return }
        self.activityFeed?.cancel()
        self.activityFeed = nil
        self.session = nil
        self.connections = [:]
        self.phase = .failed
        self.errorText = error is CancellationError ? nil : Failure.safe(error).localizedDescription
        self.detail = "Local runtime did not start."
      }
      if self.revision == token { self.startup = nil }
    }
  }

  private static var processHelper: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LutiProcessHost")
  }

  func connectRemote(_ id: ConnectionProviderID) {
    guard let runtime = session, canConnectProvider(id) else { return }
    let connection = ConnectionManager(
      router: runtime.router, store: authorizationStore(for: id))
    connections[id] = connection
    let token = revision
    let operation = UUID()
    connectionRevisions[id] = operation
    connectionBusyProviders.insert(id)
    connectionErrors[id] = nil
    doctorReports[id] = nil
    if doctorBusy == id { doctorBusy = nil }
    connectionSnapshots[id] = ConnectionSnapshot(state: .starting, providerID: id)
    connectionTasks[id] = Task { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        guard self.revision == token, self.connectionRevisions[id] == operation else {
          throw CancellationError()
        }
        let origin = try ConnectionContract.validatePublicBaseURL(self.savedPublicBaseURL)
        guard let secret = try self.cachedTunnelToken ?? KeychainService.read() else {
          throw Failure.invalid("No Tunnel Token is saved in Keychain.")
        }
        self.cachedTunnelToken = secret
        let provider = try CloudflareBYOProvider(publicOrigin: origin, tunnelToken: secret,
          helper: Self.processHelper, activity: runtime.activity)
        try await connection.connect(
          provider, authorizationStore: self.authorizationStore(for: id))
      } catch {
        guard self.revision == token else { return }
        guard self.connectionRevisions[id] == operation else { return }
        if !(error is CancellationError) {
          self.connectionErrors[id] = Failure.safe(error).localizedDescription
        }
      }
      let snapshot = await connection.snapshot()
      guard self.revision == token, self.connectionRevisions[id] == operation else { return }
      self.connectionSnapshots[id] = self.connectionErrors[id] != nil
        ? ConnectionSnapshot(
          state: .failed, message: self.connectionErrors[id] ?? "", providerID: id)
        : snapshot
      self.connectionBusyProviders.remove(id)
      self.connectionTasks[id] = nil
    }
  }

  private func allPendingConnectionApprovals() async -> [PendingAuthorization] {
    var approvals: [PendingAuthorization] = []
    let currentConnections = Array(connections.values)
    for connection in currentConnections {
      approvals.append(contentsOf: await connection.pendingApprovals())
    }
    return approvals.sorted { $0.createdAt < $1.createdAt }
  }

  func stopActiveJobs() async {
    guard let owned = session else { return }
    _ = await owned.stopActiveJobs()
    await refresh()
  }
  func stop() async {
    if let teardown {
      await teardown.value
      return
    }
    revision = UUID()
    for id in ConnectionProviderID.allCases { connectionRevisions[id] = UUID() }
    let task = startup
    startup = nil
    task?.cancel()
    let remoteTasks = Array(connectionTasks.values)
    connectionTasks = [:]
    remoteTasks.forEach { $0.cancel() }
    let remotes = Array(connections.values)
    connections = [:]
    let owned = session
    session = nil
    activityFeed?.cancel()
    activityFeed = nil
    phase = .stopping
    for id in Array(connectionSnapshots.keys) {
      connectionSnapshots[id] = ConnectionSnapshot(state: .stopping, providerID: id)
    }
    doctorReports.removeAll()
    doctorBusy = nil
    detail = "Stopping this app’s tools and owned processes…"
    LocalLogStore.runtime("info", "Runtime stopping.")
    let cleanup = Task {
      for remote in remotes { await remote.shutdown() }
      if let owned { await owned.stop() }
      await task?.value
      for remoteTask in remoteTasks { await remoteTask.value }
    }
    teardown = cleanup
    await cleanup.value
    teardown = nil
    phase = .stopped
    connectionSnapshots = [:]
    connectionBusyProviders = []
    connectionErrors = [:]
    activeJobs = 0
    lastCall = nil
    pendingApprovals = []
    announcedApprovals = []
    remoteClients = authorizationStores.values.reduce(0) { $0 + $1.approvedClients.count }
    detail = "Stopped. Project access is revoked."
    LocalLogStore.runtime("info", "Runtime stopped; local handles revoked.")
  }
  /// Answers one request and drops it from the queue immediately, so the sheet
  /// does not linger for the poll interval showing a decision already made.
  func resolveApproval(_ id: UUID, approved: Bool) {
    let owned = Array(connections.values)
    guard !owned.isEmpty else { return }
    pendingApprovals.removeAll { $0.id == id }
    Task {
      for connection in owned {
        await connection.resolveApproval(id, approved: approved)
      }
    }
  }

  func refresh() async {
    guard let owned = session else { return }
    let token = revision
    let connectionTokens = connectionRevisions
    let currentConnections = connections
    let snapshot = await owned.snapshot()
    var remoteSnapshots: [ConnectionProviderID: ConnectionSnapshot] = [:]
    var approvalsByProvider: [ConnectionProviderID: [PendingAuthorization]] = [:]
    for (id, connection) in currentConnections {
      remoteSnapshots[id] = await connection.snapshot()
      approvalsByProvider[id] = await connection.pendingApprovals()
    }
    guard token == revision else { return }
    currentRunID = snapshot.runID
    if activityFeed == nil {
      activity = Array(snapshot.activity.prefix(200))
    }
    for id in currentConnections.keys
    where connectionTokens[id] == connectionRevisions[id] {
      let remote = remoteSnapshots[id] ?? .stopped
      if !isProviderConnectionBusy(id) || remote.state != .stopped {
        // A preflight error may happen before ConnectionManager owns an attempt.
        if !(connectionErrors[id] != nil && remote.state == .stopped
          && providerSnapshot(id).state == .failed)
        {
          connectionSnapshots[id] = remote
        }
      }
      if !providerSnapshot(id).state.isActive {
        doctorReports[id] = nil
      }
    }
    pendingApprovals = approvalsByProvider
      .filter { connectionTokens[$0.key] == connectionRevisions[$0.key] }
      .flatMap(\.value)
      .sorted { $0.createdAt < $1.createdAt }
    lastCall = snapshot.lastCall
    activeJobs = snapshot.activeJobs
    remoteClients = authorizationStores.values.reduce(0) { $0 + $1.approvedClients.count }
    // Whoever started the flow is looking at a browser, which may be on another
    // machine entirely. Raising the window once per request is what makes the
    // on-Mac dialog findable; repeating it on every poll would be a nuisance.
    let unseenConnections = pendingApprovals.map(\.id).filter { !announcedApprovals.contains($0) }
    if !unseenConnections.isEmpty {
      announcedApprovals.formUnion(unseenConnections)
      NSApp.activate(ignoringOtherApps: true)
    }
    announcedApprovals.formIntersection(pendingApprovals.map(\.id))
  }
}
