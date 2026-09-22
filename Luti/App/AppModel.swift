import AppKit
import Foundation
import Observation

enum NativeApprovalPresentation: Identifiable {
  case connection(PendingAuthorization)
  case operation(PendingOperationApproval)

  var id: String {
    switch self {
    case .connection(let request): "connection:" + request.id.uuidString
    case .operation(let request): "operation:" + request.id.uuidString
    }
  }
}

@MainActor @Observable final class AppModel {
  enum Phase: String { case stopped, preparing, starting, running, stopping, failed }
  var phase: Phase = .stopped
  var approvedProjects: [ApprovedProject] = []
  var activeProjectID: String?
  var enabledProjects: [ApprovedProject] { approvedProjects.filter(\.enabled) }
  var project: URL? { activeProject?.url }
  var activeProject: ApprovedProject? {
    guard let activeProjectID else { return nil }
    return approvedProjects.first { $0.id == activeProjectID }
  }
  var enabledConnectionProviders: Set<ConnectionProviderID> = []
  var publicBaseURL: String
  var tokenDraft = ""
  var tokenSaved = false
  var otherProviderCredentials: Set<ConnectionProviderID> = []
  private var providerSettingsRevision = UUID()
  var doctorReports: [ConnectionProviderID: ConnectionDoctorReport] = [:]
  var doctorBusy: ConnectionProviderID?
  @ObservationIgnored private var authorizationStores: [ConnectionProviderID: OAuthStore] = [:]
  var permissions = PermissionState(screen: false, accessibility: false)
  var defaultFullProjectAccess = false
  var executionPolicy = ProjectExecutionPolicy.readOnly
  var activity: [ActivityEvent] = []
  var currentRunID: UUID?
  var connectionSnapshots: [ConnectionProviderID: ConnectionSnapshot] = [:]
  var localEndpoint: URL?
  var connectionBusyProviders: Set<ConnectionProviderID> = []
  var connectionErrors: [ConnectionProviderID: String] = [:]
  var detail = "Choose a project to get started."
  var lastCall: Date?
  var activeJobs = 0
  var errorText: String?
  var showConsent = false
  var settingsMessage = ""
  let contextDataRoot: URL
  var contextBusy = false
  /// Connection requests waiting for an answer. The first one drives a sheet; the
  /// rest queue behind it so two Hosts cannot race one dialog.
  var pendingApprovals: [PendingAuthorization] = []
  var pendingOperationApprovals: [PendingOperationApproval] = []
  var nextNativeApproval: NativeApprovalPresentation? {
    let connection = pendingApprovals.first
    let operation = pendingOperationApprovals.first
    switch (connection, operation) {
    case (.some(let connection), .some(let operation)):
      return connection.createdAt <= operation.createdAt
        ? .connection(connection) : .operation(operation)
    case (.some(let connection), .none): return .connection(connection)
    case (.none, .some(let operation)): return .operation(operation)
    case (.none, .none): return nil
    }
  }
  var remoteClients = 0
  @ObservationIgnored private var session: RuntimeCore?
  @ObservationIgnored private var connections: [ConnectionProviderID: ConnectionManager] = [:]
  @ObservationIgnored private var connectionTasks: [ConnectionProviderID: Task<Void, Never>] = [:]
  @ObservationIgnored private var connectionRevisions: [ConnectionProviderID: UUID] = [:]
  @ObservationIgnored private let clipboard = ConnectionClipboard()
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var activityFeed: Task<Void, Never>?
  @ObservationIgnored private var teardown: Task<Void, Never>?
  @ObservationIgnored private var cachedTunnelToken: String?
  @ObservationIgnored private var announcedApprovals: Set<UUID> = []
  @ObservationIgnored private var announcedOperationApprovals: Set<UUID> = []
  @ObservationIgnored private var revision = UUID()
  @ObservationIgnored private let defaults: UserDefaults
  private static let approvedProjectsKey = "approvedProjects"
  private static let activeProjectIDKey = "activeProjectID"
  private static let publicBaseURLKey = "publicBaseURL"
  private static let defaultFullProjectAccessKey = "defaultFullProjectAccess"
  private static let enabledConnectionProvidersKey = "enabledConnectionProviders"
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
    ConnectionProviderID.allCases.filter {
      enabledConnectionProviders.contains($0) && isConnectionProviderConfigured($0)
    }
  }
  var canStart: Bool {
    !active && !contextBusy && activeProject?.enabled == true
  }
  var readyRemoteConnectionCount: Int {
    availableConnectionProviders.filter { providerSnapshot($0).state == .ready }.count
  }
  init(contextDataRoot: URL = LutiPaths.root, defaults: UserDefaults = .standard) {
    self.contextDataRoot = contextDataRoot
    self.defaults = defaults
    publicBaseURL = defaults.string(forKey: Self.publicBaseURLKey) ?? ""
    defaultFullProjectAccess = defaults.bool(forKey: Self.defaultFullProjectAccessKey)

    if let data = defaults.data(forKey: Self.approvedProjectsKey),
       let stored = try? JSONDecoder().decode([ApprovedProject].self, from: data),
       !stored.isEmpty
    {
      approvedProjects = stored
    }
    let storedActive = defaults.string(forKey: Self.activeProjectIDKey)
    activeProjectID =
      approvedProjects.contains(where: { $0.id == storedActive })
      ? storedActive : approvedProjects.first?.id
    normalizeActiveProject(preferredActiveID: storedActive)

    tokenSaved = KeychainService.exists()
    for id in [ConnectionProviderID.openAI, .ngrok] where KeychainService.exists(account: credentialAccount(id)) {
      otherProviderCredentials.insert(id)
    }
    if let data = defaults.data(forKey: Self.enabledConnectionProvidersKey),
       let stored = try? JSONDecoder().decode(Set<ConnectionProviderID>.self, from: data)
    {
      enabledConnectionProviders = stored
    } else if cloudflareConfigured {
      // Migration from the pre-P1.1 single-provider model: a complete existing
      // Cloudflare setup remains available instead of disappearing from Home.
      enabledConnectionProviders = [.cloudflare]
    }
    defaults.removeObject(forKey: Self.legacyActiveConnectionProviderKey)

    permissions = PermissionManager.state()
    persistProjects()
    persistConnectionSelection()
    reloadStoredActivity()
    LocalLogStore.runtime("info", "Luti app initialized.")
  }

  private func persistProjects() {
    if let data = try? JSONEncoder().encode(approvedProjects) {
      defaults.set(data, forKey: Self.approvedProjectsKey)
    }
    if let activeProject {
      defaults.set(activeProject.id, forKey: Self.activeProjectIDKey)
    } else {
      defaults.removeObject(forKey: Self.activeProjectIDKey)
    }
  }

  private func normalizeActiveProject(preferredActiveID: String?) {
    if let preferredActiveID,
       approvedProjects.contains(where: { $0.id == preferredActiveID && $0.enabled })
    {
      activeProjectID = preferredActiveID
      return
    }
    if let activeProjectID,
       approvedProjects.contains(where: { $0.id == activeProjectID && $0.enabled })
    {
      return
    }
    activeProjectID = enabledProjects.first?.id
  }

  private func persistConnectionSelection() {
    if let data = try? JSONEncoder().encode(enabledConnectionProviders) {
      defaults.set(data, forKey: Self.enabledConnectionProvidersKey)
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
    guard !active, !contextBusy else { return }
    let panel = NSOpenPanel()
    panel.title = L10n.text("app.chooseProjectsLutiEdit")
    panel.prompt = L10n.text("projects.addProject")
    panel.allowedContentTypes = []
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.directoryURL = project
    panel.begin { [weak self] response in
      guard response == .OK, !panel.urls.isEmpty else { return }
      Task { @MainActor [weak self] in
        self?.addApprovedProjects(panel.urls)
      }
    }
  }

  func addApprovedProjects(_ urls: [URL]) {
    guard !active, !contextBusy, !urls.isEmpty else { return }
    for raw in urls {
      let url = raw.standardizedFileURL.resolvingSymlinksInPath()
      if approvedProjects.contains(where: { $0.path == url.path }) { continue }
      let project = ApprovedProject(
        url: url,
        enabled: true,
        permissionMode: defaultFullProjectAccess ? .fullProjectAccess : .ask)
      approvedProjects.append(project)
      if activeProjectID == nil && project.enabled { activeProjectID = project.id }
    }
    persistProjects()
    errorText = nil
    detail = "Project approved. Start when you are ready."
    reloadStoredActivity()
    LocalLogStore.runtime(
      "info", "Approved project list updated; \(approvedProjects.count) project(s).")
  }

  func setActiveProject(_ id: String) {
    guard !active, !contextBusy, enabledProjects.contains(where: { $0.id == id }) else { return }
    activeProjectID = id
    persistProjects()
    errorText = nil
    detail = "Active project selected. Start when you are ready."
    reloadStoredActivity()
  }

  func setDefaultFullProjectAccess(_ enabled: Bool) {
    defaultFullProjectAccess = enabled
    defaults.set(enabled, forKey: Self.defaultFullProjectAccessKey)
  }

  func setProjectPermissionMode(_ id: String, mode: ProjectPermissionMode) {
    guard !active, !contextBusy,
      let index = approvedProjects.firstIndex(where: { $0.id == id })
    else { return }
    let current = approvedProjects[index]
    guard current.permissionMode != mode else { return }
    approvedProjects[index] = current.withPermissionMode(mode)
    persistProjects()
    errorText = nil
  }

  func setProjectEnabled(_ id: String, enabled: Bool) {
    guard !active, !contextBusy,
      let index = approvedProjects.firstIndex(where: { $0.id == id })
    else { return }
    let current = approvedProjects[index]
    guard current.enabled != enabled else { return }
    approvedProjects[index] = current.withEnabled(enabled)
    if enabled {
      if activeProjectID == nil { activeProjectID = id }
    } else if activeProjectID == id {
      activeProjectID = enabledProjects.first?.id
    }
    persistProjects()
    errorText = nil
    reloadStoredActivity()
  }

  func clearActiveProject() {
    guard !active, !contextBusy else { return }
    activeProjectID = nil
    persistProjects()
    errorText = nil
    detail = "Choose a project to get started."
    reloadStoredActivity()
  }

  func removeProject(_ id: String) {
    guard !active, !contextBusy, let index = approvedProjects.firstIndex(where: { $0.id == id }) else { return }
    let wasActive = activeProjectID == id
    approvedProjects.remove(at: index)
    if wasActive { activeProjectID = enabledProjects.first?.id }
    persistProjects()
    errorText = nil
    reloadStoredActivity()
  }
  private func reloadStoredActivity() {
    guard !active else { return }
    currentRunID = nil
    guard let project else { activity = []; return }
    let directory = contextDataRoot.appendingPathComponent("projects")
      .appendingPathComponent(LutiPaths.projectKey(for: project)).appendingPathComponent("activity")
    activity = Array(LocalLogStore.recentActivities(limit: 200, directory: directory).reversed())
  }

  func clearProjectContext(_ project: ApprovedProject, selection: ProjectContextSelection) async throws {
    guard !active, !contextBusy, approvedProjects.contains(where: { $0.id == project.id && $0.path == project.path }) else {
      throw Failure.invalid("Stop the runtime before clearing an approved project's context.")
    }
    // Block Start until the confirmed local filesystem operation has finished.
    contextBusy = true
    defer { contextBusy = false }
    let root = contextDataRoot
    try await Task.detached(priority: .utility) {
      try ProjectContextStore(project: project, dataRoot: root, validateMemory: false).clear(selection)
    }.value
    if activeProjectID == project.id { reloadStoredActivity() }
  }

  func projectCheckpoints(_ project: ApprovedProject) async throws
    -> [ProjectCheckpointManifest]
  {
    guard approvedProjects.contains(where: { $0.id == project.id && $0.path == project.path }) else {
      throw Failure.invalid("Checkpoint browsing requires a locally approved project.")
    }
    let root = contextDataRoot
    return try await Task.detached(priority: .utility) {
      try ProjectCheckpointStore(project: project, dataRoot: root).recent()
    }.value
  }

  func checkpointPreview(
    _ checkpointID: String, project: ApprovedProject
  ) async throws -> JSONValue {
    guard !active, !contextBusy,
      approvedProjects.contains(where: { $0.id == project.id && $0.path == project.path })
    else {
      throw Failure.invalid("Stop the runtime before reviewing an approved project's checkpoint.")
    }
    let dataRoot = contextDataRoot
    return try await Task.detached(priority: .utility) {
      let store = try ProjectCheckpointStore(project: project, dataRoot: dataRoot)
      let pathPlan = try store.pathActionRestorePlan(id: checkpointID)
      let workspace = try WorkspaceFiles(root: project.url)
      do {
        let output: JSONValue
        if let pathPlan {
          output = try await workspace.previewPathActionCheckpoint(pathPlan)
        } else {
          let plan = try store.restorePlan(id: checkpointID)
          output = try await workspace.previewCheckpointFiles(plan.1)
        }
        await workspace.shutdown()
        return output
      } catch {
        await workspace.shutdown()
        throw error
      }
    }.value
  }

  func restoreCheckpoint(
    _ checkpointID: String, project: ApprovedProject, paths: [String]? = nil
  ) async throws -> JSONValue {
    guard !active, !contextBusy,
      approvedProjects.contains(where: { $0.id == project.id && $0.path == project.path })
    else {
      throw Failure.invalid("Stop the runtime before restoring an approved project's checkpoint.")
    }
    contextBusy = true
    defer { contextBusy = false }
    let dataRoot = contextDataRoot
    let result = try await Task.detached(priority: .userInitiated) {
      let store = try ProjectCheckpointStore(project: project, dataRoot: dataRoot)
      let pathPlan = try store.pathActionRestorePlan(id: checkpointID)
      if pathPlan != nil, paths != nil {
        throw Failure.invalid(
          "Directory/path-action checkpoints restore as one verified tree and do not support partial file selection.")
      }
      let workspace = try WorkspaceFiles(root: project.url)
      do {
        let output: JSONValue
        if let pathPlan {
          output = try await workspace.restorePathActionCheckpoint(pathPlan)
        } else {
          let plan = try store.restorePlan(id: checkpointID, paths: paths)
          output = try await workspace.restoreCheckpointFiles(plan.1)
        }
        await workspace.shutdown()
        _ = try store.markRestored(checkpointID)
        return output
      } catch {
        await workspace.shutdown()
        throw error
      }
    }.value
    LocalLogStore.runtime("info", "A project checkpoint was restored by the local user.")
    return result
  }

  func isConnectionProviderConfigured(_ id: ConnectionProviderID) -> Bool {
    switch id {
    case .cloudflare: return cloudflareConfigured
    case .openAI:
      return otherProviderCredentials.contains(id)
        && (try? ConnectionContract.validateTunnelID(savedProviderAddress(id))) != nil
    case .ngrok:
      return otherProviderCredentials.contains(id)
        && (try? ConnectionContract.validatePublicBaseURL(savedProviderAddress(id))) != nil
    }
  }

  func savedProviderAddress(_ id: ConnectionProviderID) -> String {
    _ = providerSettingsRevision
    switch id {
    case .cloudflare: return savedPublicBaseURL
    case .openAI, .ngrok: return defaults.string(forKey: "connection." + id.rawValue + ".address") ?? ""
    }
  }

  func configuredMCPServerURL(_ id: ConnectionProviderID) -> URL? {
    guard id != .openAI, isConnectionProviderConfigured(id),
      let origin = try? ConnectionContract.validatePublicBaseURL(savedProviderAddress(id))
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

  func isProviderEnabled(_ id: ConnectionProviderID) -> Bool {
    enabledConnectionProviders.contains(id)
  }

  func requestProviderConnection(_ id: ConnectionProviderID) {
    guard canConnectProvider(id) else { return }
    connectRemote(id)
  }

  func canConnectProvider(_ id: ConnectionProviderID) -> Bool {
    phase == .running && !isProviderConnectionBusy(id)
      && !providerSnapshot(id).state.isActive
      && enabledConnectionProviders.contains(id)
      && isConnectionProviderConfigured(id)
      && (id != .cloudflare || !hasUnsavedConnection)
  }

  func authorizationStore(for id: ConnectionProviderID) -> OAuthStore {
    if let existing = authorizationStores[id] { return existing }
    let store: OAuthStore
    if !id.usesOAuth {
      store = OAuthStore(url: nil)
    } else if id == .cloudflare && contextDataRoot == LutiPaths.root {
      store = .shared
    } else {
      let filename = id == .cloudflare ? "oauth.json" : "oauth-" + id.rawValue + ".json"
      store = OAuthStore(url: contextDataRoot.appendingPathComponent("auth").appendingPathComponent(filename))
    }
    authorizationStores[id] = store
    return store
  }

  private func credentialAccount(_ id: ConnectionProviderID) -> String {
    "connection-" + id.rawValue + "-credential"
  }

  @discardableResult
  func saveProviderSettings(_ id: ConnectionProviderID, address: String, credential: String) -> Bool {
    guard canEditConnection(id), id == .openAI || id == .ngrok else { return false }
    do {
      let normalized: String
      if id == .openAI {
        normalized = address.trimmed
        try ConnectionContract.validateTunnelID(normalized)
      } else {
        let url = try ConnectionContract.validatePublicBaseURL(address.trimmed)
        normalized = "https://" + url.host!
      }
      let secret = credential.trimmed
      if !secret.isEmpty { try ConnectionContract.validateCredential(secret, provider: id) }
      guard !secret.isEmpty || KeychainService.exists(account: credentialAccount(id)) else {
        throw Failure.invalid(L10n.text("provider.credentialRequired"))
      }
      if normalized != savedProviderAddress(id) || !secret.isEmpty {
        try authorizationStore(for: id).reset()
      }
      if !secret.isEmpty { try KeychainService.save(secret, account: credentialAccount(id)) }
      defaults.set(normalized, forKey: "connection." + id.rawValue + ".address")
      otherProviderCredentials.insert(id)
      providerSettingsRevision = UUID()
      doctorReports[id] = nil
      settingsMessage = ""
      connectionErrors[id] = nil
      if enabledConnectionProviders.contains(id), phase == .running {
        connectRemote(id)
      }
      return true
    } catch {
      settingsMessage = Failure.safe(error).localizedDescription
      return false
    }
  }

  @discardableResult
  func clearProviderSettings(_ id: ConnectionProviderID) -> Bool {
    guard canEditConnection(id), id == .openAI || id == .ngrok else { return false }
    do {
      try authorizationStore(for: id).reset()
      try KeychainService.remove(account: credentialAccount(id))
      defaults.removeObject(forKey: "connection." + id.rawValue + ".address")
      otherProviderCredentials.remove(id)
      providerSettingsRevision = UUID()
      doctorReports[id] = nil
      _ = setConnectionProviderEnabled(id, enabled: false)
      settingsMessage = ""
      connectionErrors[id] = nil
      return true
    } catch {
      settingsMessage = Failure.safe(error).localizedDescription
      return false
    }
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
  func setConnectionProviderEnabled(_ id: ConnectionProviderID, enabled: Bool) -> Bool {
    if enabled {
      guard isConnectionProviderConfigured(id) else { return false }
      enabledConnectionProviders.insert(id)
    } else {
      enabledConnectionProviders.remove(id)
    }
    persistConnectionSelection()

    if enabled, phase == .running {
      connectRemote(id)
    } else if !enabled,
      connections[id] != nil || providerSnapshot(id).state != .stopped
        || isProviderConnectionBusy(id)
    {
      Task { await disconnectRemote(id) }
    }
    return true
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
      settingsMessage = ""
      connectionErrors[.cloudflare] = nil
      errorText = nil
      if enabledConnectionProviders.contains(.cloudflare), phase == .running {
        connectRemote(.cloudflare)
      }
      return true
    } catch {
      settingsMessage = Failure.safe(error).localizedDescription
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
      _ = setConnectionProviderEnabled(.cloudflare, enabled: false)
      settingsMessage = ""
      return true
    } catch {
      settingsMessage = Failure.safe(error).localizedDescription
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
      publicBaseURL = ""
      defaults.removeObject(forKey: Self.publicBaseURLKey)
      _ = setConnectionProviderEnabled(.cloudflare, enabled: false)
      settingsMessage = ""
      connectionErrors[.cloudflare] = nil
      return true
    } catch {
      settingsMessage = Failure.safe(error).localizedDescription
      return false
    }
  }
  func requestStart() {
    guard canStart else { return }
    showConsent = true
  }
  func startWithLocalConsent() {
    guard canStart, let selectedProject = activeProject else { return }
    let root = selectedProject.url
    let approved = approvedProjects
    let selectedPermissionMode = selectedProject.permissionMode
    let policy = ProjectExecutionPolicy.fullLocal(localApproval: true)
    showConsent = false
    errorText = nil
    connectionErrors = [:]
    connectionSnapshots = [:]
    connectionBusyProviders = []
    localEndpoint = nil
    activityFeed?.cancel()
    activityFeed = nil
    currentRunID = nil
    lastCall = nil
    activeJobs = 0
    executionPolicy = policy
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
          approvedProjects: approved, activeProjectID: selectedProject.id,
          contextDataRoot: self.contextDataRoot)
        owned = runtime
        self.session = runtime
        self.bindActivity(runtime, token: token)
        self.phase = .starting
        let endpoint = try await runtime.start()
        try Task.checkCancellation()
        guard self.revision == token else { throw CancellationError() }
        self.localEndpoint = endpoint
        self.phase = .running
        self.detail = "Local MCP is running. Permission mode: \(selectedPermissionMode.rawValue)."
        LocalLogStore.runtime(
          "info", "Local project runtime started with permission mode \(selectedPermissionMode.rawValue).")
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
        self.executionPolicy = .readOnly
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
    guard canConnectProvider(id), let runtime = session else { return }
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
        let provider: any ConnectionProvider
        switch id {
        case .cloudflare:
          let origin = try ConnectionContract.validatePublicBaseURL(self.savedPublicBaseURL)
          guard let secret = try self.cachedTunnelToken ?? KeychainService.read() else {
            throw Failure.invalid("No Tunnel Token is saved in Keychain.")
          }
          self.cachedTunnelToken = secret
          provider = try CloudflareBYOProvider(publicOrigin: origin, tunnelToken: secret,
            helper: Self.processHelper, activity: runtime.activity)
        case .openAI, .ngrok:
          guard let secret = try KeychainService.read(account: self.credentialAccount(id)) else {
            throw Failure.invalid(L10n.text("provider.credentialRequired"))
          }
          if id == .openAI {
            provider = try OpenAITunnelProvider(tunnelID: self.savedProviderAddress(id), apiKey: secret,
                                               helper: Self.processHelper)
          } else {
            let origin = try ConnectionContract.validatePublicBaseURL(self.savedProviderAddress(id))
            provider = try NgrokProvider(publicOrigin: origin, authtoken: secret, helper: Self.processHelper)
          }
        }
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

  func disconnectRemote(_ id: ConnectionProviderID) async {
    guard let connection = connections[id], providerSnapshot(id).state != .stopping else {
      return
    }
    connectionRevisions[id] = UUID()
    let token = revision
    let task = connectionTasks[id]
    task?.cancel()
    connectionBusyProviders.insert(id)
    doctorReports[id] = nil
    if doctorBusy == id { doctorBusy = nil }
    connectionSnapshots[id] = ConnectionSnapshot(state: .stopping, providerID: id)
    await connection.disconnect()
    await task?.value
    guard revision == token else { return }
    connections[id] = nil
    connectionTasks[id] = nil
    connectionBusyProviders.remove(id)
    connectionSnapshots[id] = nil
    connectionErrors[id] = nil
    pendingApprovals = await allPendingConnectionApprovals()
    remoteClients = authorizationStores.values.reduce(0) { $0 + $1.approvedClients.count }
    if enabledConnectionProviders.contains(id), phase == .running {
      connectRemote(id)
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

  func copyLocalConfiguration() async -> Bool {
    guard phase == .running, let owned = session else { return false }
    let token = revision
    do {
      let configuration = try await owned.localConnectionConfiguration()
      guard token == revision, phase == .running else { return false }
      return clipboard.copy(configuration)
    } catch { return false }
  }
  func stopActiveJobs() async {
    guard let owned = session else { return }
    _ = await owned.stopActiveJobs()
    await refresh()
  }
  func stop() async {
    showConsent = false
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
    localEndpoint = nil
    clipboard.clearIfOwned()
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
    executionPolicy = .readOnly
    connectionSnapshots = [:]
    connectionBusyProviders = []
    connectionErrors = [:]
    activeJobs = 0
    lastCall = nil
    pendingApprovals = []
    pendingOperationApprovals = []
    announcedApprovals = []
    announcedOperationApprovals = []
    remoteClients = authorizationStores.values.reduce(0) { $0 + $1.approvedClients.count }
    detail = "Stopped. Project access and desktop handles are revoked."
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

  func resolveOperationApproval(_ id: UUID, approved: Bool) {
    guard let owned = session else { return }
    pendingOperationApprovals.removeAll { $0.id == id }
    Task { await owned.router.resolveOperationApproval(id, approved: approved) }
  }

  func refresh() async {
    permissions = PermissionManager.state()
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
    let operationApprovals = await owned.router.pendingOperationApprovals()
    guard token == revision else { return }
    currentRunID = snapshot.runID
    if activityFeed == nil {
      activity = Array(snapshot.activity.prefix(200))
    }
    localEndpoint = snapshot.localEndpoint
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
    pendingOperationApprovals = operationApprovals
    lastCall = snapshot.lastCall
    activeJobs = snapshot.activeJobs
    remoteClients = authorizationStores.values.reduce(0) { $0 + $1.approvedClients.count }
    // Whoever started the flow is looking at a browser, which may be on another
    // machine entirely. Raising the window once per request is what makes the
    // on-Mac dialog findable; repeating it on every poll would be a nuisance.
    let unseenConnections = pendingApprovals.map(\.id).filter { !announcedApprovals.contains($0) }
    let unseenOperations = pendingOperationApprovals.map(\.id)
      .filter { !announcedOperationApprovals.contains($0) }
    if !unseenConnections.isEmpty || !unseenOperations.isEmpty {
      announcedApprovals.formUnion(unseenConnections)
      announcedOperationApprovals.formUnion(unseenOperations)
      NSApp.activate(ignoringOtherApps: true)
    }
    announcedApprovals.formIntersection(pendingApprovals.map(\.id))
    announcedOperationApprovals.formIntersection(pendingOperationApprovals.map(\.id))
    if activeProjectID != snapshot.activeProjectID,
       approvedProjects.contains(where: { $0.id == snapshot.activeProjectID })
    {
      activeProjectID = snapshot.activeProjectID
      persistProjects()
      LocalLogStore.runtime(
        "info", "Active project switched remotely to \(snapshot.activeProjectName).")
    }
  }
}
