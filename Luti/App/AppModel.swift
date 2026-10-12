import AppKit
import Foundation
import Observation

@MainActor @Observable final class AppModel {
  enum Phase: String { case stopped, preparing, starting, running, stopping, failed }
  var phase: Phase = .stopped
  var activeProject: ApprovedProject?
  var project: URL? { activeProject?.url }
  var tunnelID: String
  var apiKeyDraft = ""
  var apiKeySaved = false
  var activity: [ActivityEvent] = []
  var currentRunID: UUID?
  var connection = ConnectionSnapshot.stopped
  var connectionBusy = false
  var connectionError: String?
  var connectionSettingsError: String?
  var savingConnection = false
  var detail = "Choose a project to get started."
  var lastCall: Date?
  var activeJobs = 0
  var errorText: String?
  let contextDataRoot: URL
  var contextBusy = false
  @ObservationIgnored private var session: RuntimeCore?
  @ObservationIgnored private var remote: ConnectionManager?
  @ObservationIgnored private var connectionTask: Task<Void, Never>?
  @ObservationIgnored private var connectionRevision = UUID()
  @ObservationIgnored private var startup: Task<Void, Never>?
  @ObservationIgnored private var polling: Task<Void, Never>?
  @ObservationIgnored private var activityFeed: Task<Void, Never>?
  @ObservationIgnored private var teardown: Task<Void, Never>?
  @ObservationIgnored private var revision = UUID()
  /// The latest stored-activity load; tests await it.
  @ObservationIgnored private(set) var activityLoad: Task<Void, Never>?
  @ObservationIgnored private let defaults: UserDefaults
  private static let selectedFolderKey = "selectedFolder"
  private static let tunnelIDKey = "connection.openai.tunnelID"
  var active: Bool { [.preparing, .starting, .running, .stopping].contains(phase) }
  var savedTunnelID: String { defaults.string(forKey: Self.tunnelIDKey) ?? "" }
  var hasUnsavedConnection: Bool { tunnelID.trimmed != savedTunnelID || !apiKeyDraft.isEmpty }
  var connectionConfigured: Bool {
    apiKeySaved && (try? ConnectionContract.validateTunnelID(savedTunnelID)) != nil
  }
  var connectionStatusKey: String {
    if connection.state != .stopped { return "connection.state." + connection.state.rawValue }
    return connectionConfigured ? "connection.state.stopped" : "connection.notConfigured"
  }
  /// Save and clear are async Keychain operations; while one runs, nothing may
  /// start, connect or edit against configuration that is about to change.
  var canStart: Bool {
    !active && !contextBusy && !savingConnection && activeProject != nil
  }
  var canEditConnection: Bool {
    !savingConnection && !connectionBusy && !connection.state.isActive
      && ![.preparing, .starting, .stopping].contains(phase)
  }
  var canConnect: Bool {
    phase == .running && !savingConnection && !connectionBusy && !connection.state.isActive
      && connectionConfigured && !hasUnsavedConnection
  }
  init(contextDataRoot: URL = LutiPaths.root, defaults: UserDefaults = .standard) {
    self.contextDataRoot = contextDataRoot
    self.defaults = defaults
    // Test fixtures use their own suites and must never touch the user's Keychain.
    LegacyMigration.run(defaults: defaults, dataRoot: contextDataRoot, keychain: defaults == .standard)
    tunnelID = defaults.string(forKey: Self.tunnelIDKey) ?? ""
    if let data = defaults.data(forKey: Self.selectedFolderKey) {
      activeProject = try? JSONDecoder().decode(ApprovedProject.self, from: data)
    }
    apiKeySaved = KeychainService.exists()
    // Nothing runs yet, so every per-run directory left by a crash or force-quit is stale.
    try? FileManager.default.removeItem(at: contextDataRoot.appendingPathComponent("runs"))
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

  /// Parsing up to 8 MiB of history stays off the main actor; only the newest
  /// request may publish its result, and never over a running session's feed.
  private func reloadStoredActivity() {
    guard !active else { return }
    currentRunID = nil
    activityLoad?.cancel()
    guard let project else { activity = []; activityLoad = nil; return }
    let directory = LocalLogStore.activityDirectory(for: project, dataRoot: contextDataRoot)
    activityLoad = Task { [weak self] in
      let events = await Task.detached(priority: .userInitiated) {
        LocalLogStore.recentActivities(limit: 200, directory: directory)
      }.value
      guard !Task.isCancelled, let self, !self.active else { return }
      self.activity = Array(events.reversed())
    }
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
    await activityLoad?.value
  }

  /// Keychain first, then defaults: a rejected Keychain write leaves the saved
  /// configuration exactly as it was.
  @discardableResult
  func saveConnection() async -> Bool {
    guard canEditConnection else { return false }
    savingConnection = true
    defer { savingConnection = false }
    do {
      let id = tunnelID.trimmed
      try ConnectionContract.validateTunnelID(id)
      let key = apiKeyDraft.trimmed
      if !key.isEmpty {
        try ConnectionContract.validateAPIKey(key)
        try await Self.keychain { try KeychainService.save(key) }
      } else if !apiKeySaved {
        throw Failure.invalid(L10n.text("connection.enterAPIKey"))
      }
      defaults.set(id, forKey: Self.tunnelIDKey)
      tunnelID = id
      apiKeyDraft = ""
      apiKeySaved = true
      connection = .stopped
      connectionSettingsError = nil
      connectionError = nil
      savingConnection = false
      if phase == .running { connectRemote() }
      return true
    } catch {
      connectionSettingsError = Failure.safe(error).localizedDescription
      return false
    }
  }

  @discardableResult
  func clearConnection() async -> Bool {
    guard canEditConnection else { return false }
    savingConnection = true
    defer { savingConnection = false }
    do {
      try await Self.keychain { try KeychainService.remove() }
      defaults.removeObject(forKey: Self.tunnelIDKey)
      tunnelID = ""
      apiKeyDraft = ""
      apiKeySaved = false
      connection = .stopped
      connectionSettingsError = nil
      connectionError = nil
      return true
    } catch {
      connectionSettingsError = Failure.safe(error).localizedDescription
      return false
    }
  }

  func requestStart() {
    guard canStart, let selectedProject = activeProject else { return }
    let root = selectedProject.url
    let policy = ProjectExecutionPolicy.fullLocal(localApproval: true)
    errorText = nil
    connectionError = nil
    connection = .stopped
    connectionBusy = false
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
        // RuntimeCore restores stored activity from disk; build it off the main actor.
        let helper = Self.processHelper, dataRoot = self.contextDataRoot
        let runtime = try await Task.detached(priority: .userInitiated) {
          try RuntimeCore(
            root: root, helper: helper, executionPolicy: policy,
            project: selectedProject, contextDataRoot: dataRoot)
        }.value
        owned = runtime
        try Task.checkCancellation()
        guard self.revision == token else { throw CancellationError() }
        self.session = runtime
        self.bindActivity(runtime, token: token)
        self.phase = .starting
        try await runtime.start()
        try Task.checkCancellation()
        guard self.revision == token else { throw CancellationError() }
        self.phase = .running
        self.detail = "Project runtime is running."
        LocalLogStore.runtime("info", "Local folder runtime started.")
        if self.connectionConfigured { self.connectRemote() }
      } catch {
        if let owned { await owned.stop() }
        guard self.revision == token else { return }
        self.activityFeed?.cancel()
        self.activityFeed = nil
        self.session = nil
        self.remote = nil
        self.phase = .failed
        self.errorText = error is CancellationError ? nil : Failure.safe(error).localizedDescription
        self.detail = "Local runtime did not start."
      }
      if self.revision == token { self.startup = nil }
    }
  }

  /// SecItem calls block and may wait for the user; keep them off the main actor.
  private static func keychain<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try operation() }.value
  }

  private static var processHelper: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LutiProcessHost")
  }

  /// Connects, or reconnects after a failure, without touching the runtime or its jobs.
  func connectRemote() {
    guard let runtime = session, canConnect else { return }
    let manager = ConnectionManager(router: runtime.router)
    remote = manager
    let token = revision
    let operation = UUID()
    connectionRevision = operation
    connectionBusy = true
    connectionError = nil
    connection = ConnectionSnapshot(state: .starting, providerID: .openAI)
    let tunnelID = savedTunnelID
    connectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let key = try await Self.keychain { try KeychainService.read() }
        try Task.checkCancellation()
        guard self.revision == token, self.connectionRevision == operation else {
          throw CancellationError()
        }
        guard let key else { throw Failure.invalid(L10n.text("connection.enterAPIKey")) }
        let provider = try OpenAITunnelProvider(
          tunnelID: tunnelID, apiKey: key, helper: Self.processHelper)
        try await manager.connect(provider)
      } catch {
        guard self.revision == token, self.connectionRevision == operation else { return }
        if !(error is CancellationError) {
          self.connectionError = Failure.safe(error).localizedDescription
        }
      }
      let snapshot = await manager.snapshot()
      guard self.revision == token, self.connectionRevision == operation else { return }
      self.connection = self.connectionError.map {
        ConnectionSnapshot(state: .failed, message: $0, providerID: .openAI)
      } ?? snapshot
      self.connectionBusy = false
      self.connectionTask = nil
    }
  }

  func disconnectRemote() async {
    guard let manager = remote, !connectionBusy else { return }
    connectionRevision = UUID()
    connectionBusy = true
    connection = ConnectionSnapshot(state: .stopping, providerID: .openAI)
    await manager.disconnect()
    if remote === manager { remote = nil }
    connection = .stopped
    connectionError = nil
    connectionBusy = false
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
    connectionRevision = UUID()
    let task = startup
    startup = nil
    task?.cancel()
    let remoteTask = connectionTask
    connectionTask = nil
    remoteTask?.cancel()
    let manager = remote
    remote = nil
    let owned = session
    session = nil
    activityFeed?.cancel()
    activityFeed = nil
    phase = .stopping
    if connection.state != .stopped {
      connection = ConnectionSnapshot(state: .stopping, providerID: .openAI)
    }
    detail = "Stopping this app’s tools and owned processes…"
    LocalLogStore.runtime("info", "Runtime stopping.")
    let cleanup = Task {
      await manager?.shutdown()
      if let owned { await owned.stop() }
      await task?.value
      await remoteTask?.value
    }
    teardown = cleanup
    await cleanup.value
    teardown = nil
    phase = .stopped
    connection = .stopped
    connectionBusy = false
    connectionError = nil
    activeJobs = 0
    lastCall = nil
    detail = "Stopped. Project access is revoked."
    LocalLogStore.runtime("info", "Runtime stopped; local handles revoked.")
  }

  /// Polled state is assigned only when it changes, so an idle window does not
  /// invalidate every observing view on each tick.
  func refresh() async {
    guard let owned = session else { return }
    let token = revision
    let operation = connectionRevision
    let manager = remote
    let snapshot = await owned.snapshot()
    let remoteSnapshot = await manager?.snapshot()
    guard token == revision else { return }
    if currentRunID != snapshot.runID { currentRunID = snapshot.runID }
    if activityFeed == nil { activity = Array(snapshot.activity.prefix(200)) }
    if let remoteSnapshot, operation == connectionRevision, manager === remote, !connectionBusy,
      remoteSnapshot != connection
    {
      connection = remoteSnapshot
    }
    if lastCall != snapshot.lastCall { lastCall = snapshot.lastCall }
    if activeJobs != snapshot.activeJobs { activeJobs = snapshot.activeJobs }
  }
}

private extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
