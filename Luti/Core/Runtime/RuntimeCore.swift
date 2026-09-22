import Foundation

public struct RuntimeSnapshot: Sendable {
  public let activity: [ActivityEvent]
  public let localEndpoint: URL?
  public let lastCall: Date?
  public let activeJobs: Int
  public let activeProjectID: String
  public let activeProjectName: String
  public let projectGeneration: Int
  public let runID: UUID
}

/// One explicit Start owns one local runtime. No account, tunnel configuration,
/// installer or remote connection is needed to construct or start this object.
public actor RuntimeCore {
  private let server = MCPServer()
  nonisolated let router: ToolRouter
  nonisolated let activity: ActivityStore
  public nonisolated let runID: UUID
  private let bearer: String
  private var endpoint: URL?
  private var started = false
  private var closing: Task<Void, Never>?

  public init(
    root: URL, helper: URL, executionPolicy: ProjectExecutionPolicy = .readOnly,
    approvedProjects: [ApprovedProject]? = nil, activeProjectID: String? = nil,
    contextDataRoot: URL? = nil
  ) throws {
    bearer = Budget.token()
    let redactor = Redactor(known: [bearer])
    let activity = ActivityStore(
      redactor: redactor,
      persistenceDirectory: (contextDataRoot ?? LutiPaths.root).appendingPathComponent("projects")
        .appendingPathComponent(LutiPaths.projectKey(for: root)).appendingPathComponent("activity"))
    self.activity = activity
    runID = activity.runID
    let images = ImageStore()
    let operationApprovals = OperationApprovalBroker()
    router = try ToolRouter(
      workspace: WorkspaceFiles(root: root), jobs: JobManager(helper: helper, redactor: redactor),
      images: images, computer: ComputerService(images: images), activity: activity,
      executionPolicy: executionPolicy, operationApprovals: operationApprovals,
      redactor: redactor, approvedProjects: approvedProjects,
      activeProjectID: activeProjectID, helper: helper, contextDataRoot: contextDataRoot)
  }

  @discardableResult
  public func start() async throws -> URL {
    guard !started, closing == nil else { throw Failure.stopped }
    started = true
    do {
      let url = try await server.start(router: router, authentication: .local(bearer: bearer))
      try Task.checkCancellation()
      guard closing == nil else { throw Failure.stopped }
      endpoint = url
      return url
    } catch {
      await stop()
      throw error
    }
  }

  /// Only the native Copy action uses this in-process API. It is deliberately not
  /// part of RuntimeSnapshot, Activity, Session, or the public MCP tool surface.
  func localConnectionConfiguration() throws -> String {
    guard closing == nil, let endpoint else { throw Failure.stopped }
    let setup: JSONValue = [
      "url": .string(endpoint.absoluteString),
      "headers": ["Authorization": .string("Bearer " + bearer)],
    ]
    return String(decoding: try setup.data(), as: UTF8.self)
  }

  public func snapshot() async -> RuntimeSnapshot {
    let jobs = await router.jobList()
    let project = await router.activeProjectState()
    await activity.reconcileJobs(jobs)
    return RuntimeSnapshot(
      activity: await activity.snapshot(), localEndpoint: endpoint,
      lastCall: await router.lastSuccessfulCall(),
      activeJobs: jobs.filter { $0["terminal"] != true }.count,
      activeProjectID: project.id, activeProjectName: project.name,
      projectGeneration: project.generation, runID: runID)
  }
  public func activityUpdates() async -> AsyncStream<[ActivityEvent]> { await activity.updates() }
  public func stopActiveJobs() async -> Int { await router.stopActiveJobs() }

  public func stop() async {
    if let closing { await closing.value; return }
    endpoint = nil
    let task = Task { [server, router] in
      async let listener: Void = server.stop()
      async let tools: Void = router.stop()
      _ = await (listener, tools)
    }
    closing = task
    await task.value
  }
}
