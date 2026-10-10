import Foundation

public struct RuntimeSnapshot: Sendable {
  public let activity: [ActivityEvent]
  public let lastCall: Date?
  public let activeJobs: Int
  public let runID: UUID
}

/// One explicit Start owns the project tools and jobs. Cloudflare connections
/// own their ingress listeners; the project runtime opens no separate MCP endpoint.
public actor RuntimeCore {
  nonisolated let router: ToolRouter
  nonisolated let activity: ActivityStore
  public nonisolated let runID: UUID
  private var started = false
  private var closing: Task<Void, Never>?

  public init(
    root: URL, helper: URL, executionPolicy: ProjectExecutionPolicy = .readOnly,
    project: ApprovedProject? = nil,
    contextDataRoot: URL? = nil
  ) throws {
    let redactor = Redactor()
    let activity = ActivityStore(
      redactor: redactor,
      persistenceDirectory: LocalLogStore.activityDirectory(for: root, dataRoot: contextDataRoot ?? LutiPaths.root))
    self.activity = activity
    runID = activity.runID
    router = try ToolRouter(
      workspace: WorkspaceFiles(root: root), jobs: JobManager(helper: helper, redactor: redactor),
      activity: activity,
      executionPolicy: executionPolicy,
      redactor: redactor, project: project, helper: helper, contextDataRoot: contextDataRoot)
  }

  public func start() throws {
    guard !started, closing == nil else { throw Failure.stopped }
    try Task.checkCancellation()
    started = true
  }

  public func snapshot() async -> RuntimeSnapshot {
    let jobs = await router.jobList(refreshValidationInputs: false)
    await activity.reconcileJobs(jobs)
    return RuntimeSnapshot(
      activity: await activity.snapshot(),
      lastCall: await router.lastSuccessfulCall(),
      activeJobs: jobs.filter { $0["terminal"] != true }.count,
      runID: runID)
  }
  public func activityUpdates() async -> AsyncStream<[ActivityEvent]> { await activity.updates() }
  public func stopActiveJobs() async -> Int { await router.stopActiveJobs() }

  public func stop() async {
    if let closing { await closing.value; return }
    let task = Task { [router] in await router.stop() }
    closing = task
    await task.value
  }
}
