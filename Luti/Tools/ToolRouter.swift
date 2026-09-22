import Foundation

private struct ProjectRuntimeContext: Sendable {
  let project: ApprovedProject
  let generation: Int
  // A fresh opaque identity on each context, including restarts and A → B → A.
  let projectToken = "project_" + UUID().uuidString.lowercased()
  let workspace: WorkspaceFiles
  let jobs: JobManager
  let artifacts: ArtifactStore
  let browser: BrowserProvider
  let code: CodeQueryService
  let store: ProjectContextStore
  let checkpoints: ProjectCheckpointStore

  init(
    project: ApprovedProject, generation: Int, workspace: WorkspaceFiles, jobs: JobManager,
    redactor: Redactor, dataRoot: URL, helper: URL
  ) throws {
    store = try ProjectContextStore(project: project, dataRoot: dataRoot, redactor: redactor)
    checkpoints = try ProjectCheckpointStore(project: project, dataRoot: dataRoot)
    let artifacts = ArtifactStore()
    self.project = project
    self.generation = generation
    self.workspace = workspace
    self.jobs = jobs
    self.artifacts = artifacts
    browser = BrowserProvider(workspace: workspace, artifacts: artifacts, redactor: redactor)
    code = CodeQueryService(workspace: workspace, helper: helper)
  }

  static func make(
    project: ApprovedProject, generation: Int, helper: URL, redactor: Redactor, dataRoot: URL
  ) throws -> ProjectRuntimeContext {
    let workspace = try WorkspaceFiles(root: project.url)
    let jobs = JobManager(helper: helper, redactor: redactor)
    return try ProjectRuntimeContext(
      project: project, generation: generation, workspace: workspace, jobs: jobs, redactor: redactor, dataRoot: dataRoot, helper: helper)
  }

  func shutdown() async {
    async let files: Void = workspace.shutdown()
    async let browsing: Void = browser.stop()
    async let exported: Void = artifacts.stop()
    async let processes: Void = jobs.shutdown()
    async let languageService: Void = code.stop()
    _ = await (files, browsing, exported, processes, languageService)
  }
}

public actor ToolRouter {
  public nonisolated let activity: ActivityStore
  public nonisolated let images: ImageStore
  private let computer: any ComputerBackend
  private let executionPolicy: ProjectExecutionPolicy
  private let sandboxBackend: any ProjectSandboxBackend
  private let operationApprovals: OperationApprovalBroker?
  private let helper: URL
  private let redactor: Redactor
  private let approvedProjects: [ApprovedProject]
  private var enabledProjects: [ApprovedProject] {
    approvedProjects.filter(\.enabled)
  }
  private var context: ProjectRuntimeContext
  private var accepting = true
  var switching = false
  var projectCallsInFlight = 0
  private var lastSuccess: Date?
  private let contextDataRoot: URL
  private var visitedStores: [String: ProjectContextStore]
  private var contextPersistenceWarning: String?

  var memoryStore: ProjectContextStore { context.store }
  func memorySource(_ grant: ToolGrant) -> MemorySource { .model(runID: activity.runID, grant: grant, redactor: redactor) }

  var workspace: WorkspaceFiles { context.workspace }
  var jobs: JobManager { context.jobs }
  var artifacts: ArtifactStore { context.artifacts }
  var browser: BrowserProvider { context.browser }
  var code: CodeQueryService { context.code }
  var checkpoints: ProjectCheckpointStore { context.checkpoints }
  var projectToken: String { context.projectToken }

  public init(
    workspace: WorkspaceFiles, jobs: JobManager, images: ImageStore, computer: any ComputerBackend,
    activity: ActivityStore, executionPolicy: ProjectExecutionPolicy = .readOnly,
    sandboxBackend: any ProjectSandboxBackend = UnsupportedProjectSandboxBackend(),
    operationApprovals: OperationApprovalBroker? = nil,
    redactor: Redactor = Redactor(),
    approvedProjects: [ApprovedProject]? = nil, activeProjectID: String? = nil,
    helper: URL = JobManager.defaultHelper, contextDataRoot: URL? = nil
  ) throws {
    let fallback = ApprovedProject(
      id: activeProjectID ?? "runtime-project", url: workspace.root)
    let records = (approvedProjects?.isEmpty == false) ? approvedProjects! : [fallback]
    let enabled = records.filter(\.enabled)
    guard !enabled.isEmpty else {
      throw Failure(
        "project_not_enabled", "No locally enabled project is available for this runtime.",
        "Enable a project in Luti before starting the runtime.")
    }
    let selected =
      enabled.first(where: { $0.id == activeProjectID })
      ?? enabled.first(where: { $0.path == workspace.root.path })
      ?? enabled[0]

    self.images = images
    self.computer = computer
    self.activity = activity
    self.executionPolicy = executionPolicy
    self.sandboxBackend = sandboxBackend
    self.operationApprovals = operationApprovals
    self.helper = helper
    self.redactor = redactor
    self.approvedProjects = records
    let dataRoot = contextDataRoot ?? LutiPaths.root
    self.contextDataRoot = dataRoot
    let initial = try ProjectRuntimeContext(
      project: selected, generation: 1, workspace: workspace, jobs: jobs, redactor: redactor, dataRoot: dataRoot, helper: helper)
    try initial.store.startSession(activity.runID)
    context = initial
    visitedStores = [initial.store.projectKey: initial.store]
  }

  public func lastSuccessfulCall() -> Date? { lastSuccess }

  public func pendingOperationApprovals() async -> [PendingOperationApproval] {
    await operationApprovals?.pendingApprovals() ?? []
  }

  public func resolveOperationApproval(_ id: UUID, approved: Bool) async {
    await operationApprovals?.resolve(id, approved: approved)
  }

  public func jobList(refreshValidationInputs: Bool = true) async -> [JSONValue] {
    let owner = context
    let result = await owner.jobs.list(refreshInputs: refreshValidationInputs)
    if accepting, owner.generation == context.generation {
      journalWrite { try owner.store.reconcileSessionJobs(result, runID: activity.runID) }
    }
    return result
  }

  private func journalWrite(_ body: () throws -> Void) {
    do { try body() }
    catch {
      contextPersistenceWarning = "Session journal persistence failed; tool effects are not rolled back. Inspect local storage before relying on history."
      LocalLogStore.runtime("warning", "Session journal persistence failed.")
    }
  }
  public func stopActiveJobs() async -> Int { await context.jobs.stopActive() }
  public func activeProjectState() -> (id: String, name: String, generation: Int) {
    (context.project.id, context.project.name, context.generation)
  }

  private var callsInFlight = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var stopFinished = false

  private func finishTrackedCall() {
    callsInFlight -= 1
    if callsInFlight == 0 {
      let waiters = drainWaiters
      drainWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private struct ActivityDescriptor {
    let action: String?
    let targetType: String?
    let target: String
  }

  /// `grant` defaults to `.local` because that is what an in-process caller is:
  /// the session the Mac's owner started. A call that arrived over the tunnel
  /// always passes its own grant, and only that path is scope-checked.
  public func call(_ name: String, arguments value: JSONValue, grant: ToolGrant = .local) async
    -> ToolOutput
  {
    // Once Stop has returned, even an in-process caller cannot recreate cleared
    // history. Track every admitted call until its final journal write finishes.
    guard accepting else { return .failure(.stopped) }
    callsInFlight += 1
    defer { finishTrackedCall() }
    let started = Date()
    let owner = context
    let admitted = accepting && !switching
    let isSwitch = name == "projects" && value["action"].string == "switch"
    // Reserve the namespace before the first actor hop. Desktop calls also produce
    // project context and must not straddle an untracked workspace switch.
    let tracksProject = admitted && !isSwitch
    if tracksProject { projectCallsInFlight += 1 }
    defer { if tracksProject { projectCallsInFlight -= 1 } }
    let descriptor = activityDescriptor(name, value)
    let source = grant.context.map { ActivitySource(transport: $0.transport, clientID: $0.clientID,
      clientName: Budget.prefix(redactor.clean($0.clientName), bytes: 64), authorizationID: $0.authorizationID) }
    let activityID = await activity.begin(
      tool: name, action: descriptor.action, targetType: descriptor.targetType,
      target: descriptor.target, cwd: value["cwd"].string, source: source,
      persistenceDirectory: owner.store.activityDirectory)
    journalWrite {
      try owner.store.recordCallStarted(runID: activity.runID, id: activityID, tool: name,
        action: descriptor.action.map { Budget.prefix(redactor.clean($0), bytes: 64) }, startedAt: started, source: source)
    }
    let output: ToolOutput
    let event: ActivityEvent
    do {
      guard accepting else { throw Failure.stopped }
      try grant.authorize(tool: name, arguments: value)
      guard admitted, !switching, owner.generation == context.generation else {
        throw Failure("project_switch_in_progress", "The active project is being switched.",
                      "Observe the current project after the switch before retrying.")
      }
      try validateProjectBinding(name, arguments: value)
      try Task.checkCancellation()
      let arguments = ProjectBindingContract.acceptsToken(name) ? value.removing(["projectToken"]) : value
      output = try await dispatch(name, arguments, grant: grant)
      if !output.isError { lastSuccess = Date() }
      let failure = output.data["failure"]
      event = await activity.finish(
        id: activityID, status: output.isError ? "failed" : "ok", started: started,
        summary: activitySummary(name, output), cwd: value["cwd"].string,
        jobID: output.data["jobId"].string,
        artifactURI: output.data["artifact"]["resource"].string ?? output.data["resource"].string,
        checkpointID: output.data["checkpoint"]["id"].string,
        effect: activityEffect(name, output), operationState: activityOperationState(name, output),
        errorCode: failure["error"].string ?? output.data["error"].string,
        recovery: failure["recovery"].string ?? output.data["recovery"].string)
    } catch {
      let failure = Failure.safe(error)
      let effect = failure.effect
        ?? (["outcome_unknown", "browser_outcome_unknown", "browser_transport_unknown"].contains(failure.code) ? "possible" : "none")
      if ["project_binding_required", "project_binding_mismatch"].contains(failure.code) {
        output = ToolOutput(failure.json.adding("currentProject", [
          "projectId": .string(context.project.id), "generation": .int(context.generation),
        ]), isError: true)
      } else {
        output = .failure(failure)
      }
      event = await activity.finish(id: activityID, status: "failed", started: started,
        summary: failure.message, cwd: value["cwd"].string, effect: effect,
        errorCode: failure.code, recovery: failure.recovery)
    }
    journalWrite {
      try owner.store.recordCallFinished(runID: activity.runID, event: event, arguments: value, output: output)
    }
    if let contextPersistenceWarning {
      return ToolOutput(output.data.adding("contextPersistenceWarning", .string(contextPersistenceWarning)),
                        content: output.extraContent, isError: output.isError)
    }
    return output
  }

  private func validateProjectBinding(_ name: String, arguments: JSONValue) throws {
    guard ProjectBindingContract.acceptsToken(name) else { return }
    // Stop is addressed by a non-reusable owned Job ID, so stale project context
    // must not prevent emergency termination. Normal Job authorization still applies.
    if name == "job_action", arguments["action"] == "stop" { return }
    guard let supplied = arguments.object?["projectToken"] else {
      if ProjectBindingContract.requiresToken(name, arguments: arguments) {
        throw Failure("project_binding_required", "This operation requires the observed projectToken.",
                      "Read projects(action=current), project_info or memory(action=recent), confirm the intended project, then submit the operation with that projectToken.")
      }
      return
    }
    guard let token = supplied.string, token.utf8.count <= 80, token == context.projectToken else {
      throw Failure("project_binding_mismatch", "The operation targets a stale or different project context.",
                    "Read projects(action=current), project_info or memory(action=recent) and confirm the intended project before deciding what to do. No requested operation was executed.")
    }
  }
  private func activityDescriptor(_ name: String, _ value: JSONValue) -> ActivityDescriptor {
    let action = value["action"].string

    func browserOrigin() -> String {
      guard let raw = value["url"].string, let url = URL(string: raw),
        let scheme = url.scheme, let host = url.host
      else { return "browser" }
      let port = url.port.map { ":\($0)" } ?? ""
      return "\(scheme)://\(host)\(port)"
    }

    switch name {
    case "memory":
      return ActivityDescriptor(action: action, targetType: "projectContext", target: "project memory")
    case "projects":
      return ActivityDescriptor(
        action: action, targetType: "project",
        target: value["projectId"].string ?? "approved projects")
    case "project_info":
      return ActivityDescriptor(action: nil, targetType: "project", target: ".")
    case "runtime_status":
      return ActivityDescriptor(action: nil, targetType: "runtime", target: "runtime")
    case "read_files":
      let paths = (value["paths"].array ?? []).compactMap(\.string)
      return ActivityDescriptor(
        action: nil, targetType: paths.count == 1 ? "file" : "files",
        target: paths.count <= 3 ? paths.joined(separator: ", ") : "\(paths.count) files")
    case "search_project":
      return ActivityDescriptor(
        action: value["mode"].string ?? "literal", targetType: "query",
        target: "project search")
    case "list_directory":
      return ActivityDescriptor(
        action: nil, targetType: "directory", target: value["path"].string ?? ".")
    case "read_image":
      return ActivityDescriptor(
        action: nil, targetType: "file", target: value["path"].string ?? "image")
    case "import_artifact":
      return ActivityDescriptor(action: "import", targetType: "file", target: value["path"].string ?? "file")
    case "edit_files":
      return ActivityDescriptor(
        action: action, targetType: action == "patch" ? "project" : "file",
        target: action == "patch" ? "unified patch" : (value["path"].string ?? "file"))
    case "path_action":
      let target: String
      if ["copy", "move"].contains(action ?? "") {
        target = [value["source"].string, value["destination"].string]
          .compactMap { $0 }.joined(separator: " → ")
      } else {
        target = value["path"].string ?? "path"
      }
      return ActivityDescriptor(action: action, targetType: "path", target: target)
    case "inspect_project":
      return ActivityDescriptor(
        action: nil, targetType: "project", target: value["path"].string ?? ".")
    case "code_query":
      return ActivityDescriptor(
        action: action, targetType: "file", target: value["path"].string ?? "source")
    case "skills":
      return ActivityDescriptor(
        action: action, targetType: "skill",
        target: value["path"].string ?? "project skills")
    case "export_artifact":
      if value["paths"].array != nil {
        return ActivityDescriptor(
          action: "archive", targetType: "artifact",
          target: value["name"].string ?? "luti-export.zip")
      }
      return ActivityDescriptor(
        action: "file", targetType: "file", target: value["path"].string ?? "artifact")
    case "run_process":
      return ActivityDescriptor(
        action: value["taskId"].string == nil ? nil : "task",
        targetType: value["taskId"].string == nil ? "process" : "task",
        target: value["taskId"].string ?? value["program"].string ?? "process")
    case "run_shell":
      return ActivityDescriptor(action: nil, targetType: "shell", target: "shell command")
    case "job_query", "job_action":
      return ActivityDescriptor(
        action: action, targetType: "job",
        target: value["jobId"].string ?? "jobs")
    case "git_query":
      return ActivityDescriptor(
        action: action, targetType: "repository", target: value["path"].string ?? ".")
    case "browser_session":
      if action == "open" {
        return ActivityDescriptor(action: action, targetType: "origin", target: browserOrigin())
      }
      return ActivityDescriptor(
        action: action, targetType: "tab", target: value["tabId"].string ?? "tab")
    case "browser_observe":
      return ActivityDescriptor(
        action: action, targetType: action == "tabs" ? "browser" : "tab",
        target: action == "tabs" ? "owned tabs" : (value["tabId"].string ?? "tab"))
    case "browser_action", "browser_transfer", "browser_inspect", "browser_dialog":
      return ActivityDescriptor(
        action: action, targetType: "tab", target: value["tabId"].string ?? "tab")
    case "browser_evaluate":
      return ActivityDescriptor(
        action: nil, targetType: "tab", target: value["tabId"].string ?? "tab")
    case "computer_observe":
      if let display = value["displayId"].string ?? value["displayId"].int.map(String.init) {
        return ActivityDescriptor(action: nil, targetType: "display", target: display)
      }
      return ActivityDescriptor(
        action: nil, targetType: "window", target: value["window"].string ?? "frontmost")
    case "computer_wait":
      return ActivityDescriptor(
        action: nil, targetType: "condition", target: value["condition"].string ?? "desktop")
    case "computer_action":
      let target =
        value["window"].string ?? value["elementId"].string ?? value["bundleId"].string ?? "desktop"
      let type =
        value["elementId"].string != nil ? "element"
          : (value["bundleId"].string != nil ? "application" : "window")
      return ActivityDescriptor(action: action, targetType: type, target: target)
    default:
      return ActivityDescriptor(
        action: action, targetType: nil,
        target: value["path"].string ?? value["jobId"].string ?? value["tabId"].string
          ?? value["window"].string ?? name)
    }
  }
  private func activitySummary(_ name: String, _ output: ToolOutput) -> String {
    if name == "memory" {
      return output.isError ? "Project memory operation failed." : "Project memory operation completed."
    }
    if let summary = output.data["summary"].string, !summary.isEmpty { return summary }
    if output.data["testSummary"] != .null {
      let tests = output.data["testSummary"]
      let passed = tests["passed"].int ?? 0
      let failed = tests["failed"].int ?? 0
      let skipped = tests["skipped"].int ?? 0
      var text = "Tests: \(passed) passed, \(failed) failed"
      if skipped > 0 { text += ", \(skipped) skipped" }
      return text + "."
    }

    switch name {
    case "projects":
      switch output.data["action"].string {
      case "list":
        return "\(output.data["projects"].array?.count ?? 0) enabled project(s)."
      case "current":
        return "Current project inspected."
      case "switch":
        return output.data["changed"] == true
          ? "Active project switched; old project handles were revoked."
          : "Requested project was already active."
      default:
        return "Project context updated."
      }
    case "job_query":
      switch output.data["action"].string {
      case "list":
        let jobs = output.data["jobs"].array ?? []
        let active = jobs.filter { $0["terminal"] != true }.count
        return "\(jobs.count) job(s), \(active) active."
      case "logs":
        if let state = output.data["status"].string {
          return "Job logs observed; job " + state.replacingOccurrences(of: "_", with: " ") + "."
        }
        return "Job logs observed."
      default:
        if let state = output.data["status"].string {
          return "Job " + state.replacingOccurrences(of: "_", with: " ") + "."
        }
        return "Job status observed."
      }
    case "job_action":
      switch output.data["action"].string {
      case "stop": return "Job stop requested."
      case "input": return "Job input submitted."
      default: return "Job action submitted."
      }
    case "git_query":
      switch output.data["action"].string {
      case "status":
        return "\(output.data["entries"].array?.count ?? 0) changed path(s)."
      case "log":
        return "\(output.data["commits"].array?.count ?? 0) commit(s) returned."
      case "blame":
        return "\(output.data["lines"].array?.count ?? 0) line(s) annotated."
      case "show":
        return "Commit details returned."
      case "diff":
        return "Git diff returned."
      default:
        return "Git query completed."
      }
    case "browser_observe":
      switch output.data["action"].string {
      case "tabs":
        return "\(output.data["tabs"].array?.count ?? 0) owned tab(s)."
      case "wait":
        return "Browser wait completed."
      case "screenshot":
        if let width = output.data["width"].int, let height = output.data["height"].int {
          return "Browser screenshot \(width)×\(height)."
        }
        return "Browser screenshot captured."
      default:
        return "Semantic browser snapshot captured."
      }
    case "browser_action":
      if output.data["postConditionSatisfied"] == true {
        return "Browser action confirmed by post-condition."
      }
      return output.data["effect"] == "submitted"
        ? "Browser action submitted; observe before retrying."
        : "Browser action completed."
    case "browser_session":
      switch output.data["action"].string {
      case "open": return "Browser tab opened."
      case "navigate": return "Browser navigation submitted."
      case "close": return "Browser tab closed."
      default: return "Browser session updated."
      }
    case "read_files":
      return "\(output.data["files"].array?.count ?? 0) file result(s)."
    case "search_project":
      let count = output.data["matches"].array?.count ?? 0
      return "\(count) match(es)." + (output.data["truncated"] == true ? " Result truncated." : "")
    case "list_directory":
      let count = output.data["entries"].array?.count ?? 0
      return "\(count) entr\(count == 1 ? "y" : "ies")." + (output.data["truncated"] == true ? " Result truncated." : "")
    case "computer_observe":
      return "Desktop observation captured."
    case "computer_action":
      return output.data["method"].string ?? "Desktop action submitted."
    default:
      if let state = activityOperationState(name, output) {
        return "Job " + state.replacingOccurrences(of: "_", with: " ") + "."
      }
      return ""
    }
  }

  private func activityOperationState(_ name: String, _ output: ToolOutput) -> String? {
    // job_query/job_action observe or mutate an already-owned Job. Their Activity
    // represents this tool call, not the target Job lifecycle, so it must finish
    // when the call returns. The observed Job state remains visible in summary/data.
    guard !["job_query", "job_action"].contains(name),
          output.data["jobId"].string != nil
    else { return nil }
    return output.data["status"].string
  }

  private func activityEffect(_ name: String, _ output: ToolOutput) -> String {
    if let effect = output.data["effect"].string,
       ["none", "submitted", "confirmed", "possible", "partial"].contains(effect) {
      return effect
    }
    if let effect = output.data["failure"]["effect"].string,
       ["none", "submitted", "confirmed", "possible", "partial"].contains(effect) {
      return effect
    }
    if output.data["submitted"] == true || output.data["observeAgain"] == true {
      return "submitted"
    }
    if name == "projects" || name == "memory" {
      return output.data["changed"] == true ? "confirmed" : "none"
    }
    let mutations: Set<String> = [
      "edit_files", "path_action", "import_artifact", "run_process", "run_shell", "job_action",
      "browser_session", "browser_action", "browser_transfer",
      "browser_dialog", "browser_evaluate", "computer_action",
    ]
    if ["run_process", "run_shell", "job_action", "browser_evaluate"].contains(name) {
      return "submitted"
    }
    return mutations.contains(name) ? "confirmed" : "none"
  }

  private func projectJSON(_ project: ApprovedProject) -> JSONValue {
    [
      "id": .string(project.id),
      "name": .string(project.name),
      "path": .string(project.path),
      "permissionMode": .string(project.permissionMode.rawValue),
      "active": .bool(project.id == context.project.id),
    ]
  }

  private func projectTool(_ value: JSONValue, grant: ToolGrant) async throws -> ToolOutput {
    let root = try ActionContracts.arguments("projects", value)
    let action = try root.string("action", max: 16)
    switch action {
    case "list":
      return ToolOutput([
        "action": "list",
        "activeProjectId": .string(context.project.id),
        "generation": .int(context.generation),
        "projectToken": .string(context.projectToken),
        "projects": .array(enabledProjects.map(projectJSON)),
      ])

    case "current":
      let project: JSONValue = grant.scopes.map { !$0.contains(.projectRead) } == true
        ? ["id": .string(context.project.id)] : projectJSON(context.project)
      return ToolOutput([
        "action": "current",
        "generation": .int(context.generation),
        "projectToken": .string(context.projectToken),
        "project": project,
      ])

    case "switch":
      let a = root
      let id = try a.string("projectId", max: 80)
      guard let target = approvedProjects.first(where: { $0.id == id }) else {
        throw Failure(
          "project_not_approved", "That project is not in the locally approved project list.",
          "Call projects(action=list) and switch using an exact returned projectId.")
      }
      guard target.enabled else {
        throw Failure(
          "project_not_enabled", "This project is not enabled on this Mac.",
          "Use projects(action=list) and switch to one of its project IDs. The Mac owner can enable other approved projects locally while the runtime is stopped.")
      }
      if target.id == context.project.id {
        return ToolOutput([
          "action": "switch",
          "changed": false,
          "generation": .int(context.generation),
          "projectToken": .string(context.projectToken),
          "project": projectJSON(context.project),
        ])
      }
      guard projectCallsInFlight == 0 else {
        throw Failure(
          "project_busy", "Another tool call is still using the active project.",
          "Wait for the existing call to finish, then retry the project switch.")
      }

      switching = true
      defer { switching = false }

      let activeJobs = await context.jobs.activeCount()
      // Stop can enter the actor while activeCount is suspended.
      guard accepting else { throw Failure.stopped }
      guard activeJobs == 0 else {
        throw Failure(
          "project_busy", "\(activeJobs) project job(s) are still active.",
          "Stop the active jobs before switching projects.")
      }

      let previous = context
      let nextGeneration = previous.generation + 1
      let next = try ProjectRuntimeContext.make(
        project: target, generation: nextGeneration, helper: helper, redactor: redactor, dataRoot: contextDataRoot)
      try next.store.startSession(activity.runID)
      journalWrite { try previous.store.pauseSession(activity.runID) }
      visitedStores[next.store.projectKey] = next.store
      context = next
      await activity.setPersistenceDirectory(next.store.activityDirectory)
      await previous.shutdown()

      return ToolOutput([
        "action": "switch",
        "changed": true,
        "previousProjectId": .string(previous.project.id),
        "previousProjectName": .string(previous.project.name),
        "generation": .int(nextGeneration),
        "projectToken": .string(context.projectToken),
        "project": projectJSON(target),
        "invalidated": .array([
          "workspaceHandles", "jobs", "browserSessions", "artifacts"
        ].map(JSONValue.string)),
      ])

    default:
      throw Failure.invalid("projects action must be list, current or switch.")
    }
  }

  func requireExecution(_ capability: ExecutionCapability) throws {
    try executionPolicy.authorize(
      capability, sandboxStatus: sandboxBackend.status)
  }

  func validateExecutionExecutable(_ executable: URL, cwd: URL) throws {
    try executionPolicy.validateExecutable(
      program: executable.path,
      cwd: cwd,
      environment: [:],
      sandboxStatus: sandboxBackend.status)
  }

  private func checkpointedEdit(
    action: String,
    paths: [String],
    dryRun: Bool,
    operation: () async throws -> JSONValue
  ) async throws -> JSONValue {
    if dryRun { return try await operation() }

    let before = try await workspace.checkpointFiles(paths)
    let prepared = try checkpoints.prepare(
      runID: activity.runID, tool: "edit_files", reason: action, before: before)
    do {
      let result = try await operation()
      guard result["applied"] == true else {
        try? checkpoints.discard(prepared.id)
        return result
      }

      do {
        let after = try await workspace.checkpointFiles(paths)
        let finalized = try checkpoints.finalize(id: prepared.id, after: after)
        return result.adding(
          "checkpoint", ProjectCheckpointStore.summaryJSON(finalized))
      } catch {
        // The primary file mutation has already committed. A recovery-metadata
        // failure must not make the Host believe the edit itself failed and replay it.
        LocalLogStore.runtime(
          "warning", "Checkpoint finalization failed after a confirmed edit.")
        return result
          .adding("checkpoint", ProjectCheckpointStore.summaryJSON(prepared))
          .adding(
            "checkpointWarning",
            "The edit succeeded but its checkpoint could not be finalized. Do not treat this warning as an edit failure.")
      }
    } catch {
      // If an operation reports failure after producing an observable file change,
      // retain the before-image but mark it uncertain. Uncertain checkpoints are
      // intentionally not eligible for automatic restore.
      if let after = try? await workspace.checkpointFiles(paths), after != before {
        _ = try? checkpoints.finalize(id: prepared.id, after: after, uncertain: true)
      } else {
        try? checkpoints.discard(prepared.id)
      }
      throw error
    }
  }
  private func dispatch(_ name: String, _ value: JSONValue, grant: ToolGrant) async throws -> ToolOutput {
    if name == "memory" { return try await memoryTool(value, grant: grant) }
    if name == "projects" { return try await projectTool(value, grant: grant) }
    if let output = try await extendedTool(name, value, grant: grant) { return output }
    switch name {
    case "project_info":
      _ = try Arguments(value, allowed: [])
      let info = try await workspace.projectInfo()
      return ToolOutput(
        info
          .adding("projectId", .string(context.project.id))
          .adding("generation", .int(context.generation))
          .adding("projectToken", .string(context.projectToken))
          .adding("approvedProjectCount", .int(approvedProjects.count))
          .adding("enabledProjectCount", .int(enabledProjects.count))
          .adding("context", ["projectKey": .string(context.store.projectKey),
                              "discovery": "Use memory(action=recent) for a bounded summary, then recall relevant facts."]))
    case "runtime_status":
      _ = try Arguments(value, allowed: [])
      let permissions = await computer.permissions()
      return ToolOutput([
        "name": "Luti", "version": .string(Identity.version), "running": .bool(accepting),
        "executionEnabled": .bool(
          executionPolicy.commandExecutionAvailable(
            sandboxStatus: sandboxBackend.status)),
        "executionPolicy": executionPolicy.statusJSON(
          sandboxStatus: sandboxBackend.status)
          .adding("permissionMode", .string(context.project.permissionMode.rawValue)),
        "permissions": permissions.json,
        "activeProject": [
          "id": .string(context.project.id), "name": .string(context.project.name),
          "path": .string(context.project.path),
          "permissionMode": .string(context.project.permissionMode.rawValue),
          "generation": .int(context.generation),
        ],
        "approvedProjectCount": .int(approvedProjects.count),
        "enabledProjectCount": .int(enabledProjects.count),
        "contextPersistenceWarning": contextPersistenceWarning.map(JSONValue.string) ?? .null,
        "jobs": .array(await jobs.list().map { $0.removing(["stdoutTail", "stderrTail", "stdoutHead", "stderrHead"]) }),
        "capabilities": [
          "projectFiles": true,
          "projectWrite": .bool(executionPolicy.workspaceWriteAvailable),
          "commandExecution": .bool(
            executionPolicy.commandExecutionAvailable(
              sandboxStatus: sandboxBackend.status)),
          "rawShell": executionPolicy.statusJSON(
            sandboxStatus: sandboxBackend.status)["rawShell"],
          "executionScope": .string(
            executionPolicy.scopeDescription(
              sandboxStatus: sandboxBackend.status)),
          "browserInstalled": .bool(BrowserInstallation.installed),
          "chromeAvailable": .bool(BrowserInstallation.chromeAvailable),
        ],
        "lastSuccessfulToolCall": lastSuccess.map {
          .string(ISO8601DateFormatter().string(from: $0))
        } ?? .null,
      ])
    case "read_files":
      let a = try Arguments(value, allowed: ["paths", "startLine", "endLine", "byteOffset"])
      let result = try await workspace.readFiles(
        paths: a.strings("paths", maxCount: 8, maxBytes: 4096),
        startLine: a.integer("startLine", default: 1, range: 1...1_000_000),
        endLine: a.has("endLine") ? a.integer("endLine", default: 1, range: 1...1_000_000) : nil,
        byteOffset: a.integer("byteOffset", default: 0, range: 0...1_048_576))
      let failed = result["files"].array?.allSatisfy { $0["failure"] != .null } ?? false
      return ToolOutput(result, isError: failed)
    case "search_project":
      let a = try Arguments(
        value,
        allowed: [
          "query", "mode", "glob", "maxResults", "caseSensitive", "contextBefore", "contextAfter",
        ])
      return ToolOutput(
        try await workspace.search(
          query: a.string("query", max: 1024), glob: a.string("glob", default: "*", max: 256),
          maxResults: a.integer("maxResults", default: 50, range: 1...200),
          caseSensitive: a.flag("caseSensitive", default: false),
          mode: a.string("mode", default: "literal", max: 16),
          contextBefore: a.integer("contextBefore", default: 0, range: 0...5),
          contextAfter: a.integer("contextAfter", default: 0, range: 0...5)))
    case "edit_files":
      try executionPolicy.authorize(.workspaceWrite)
      let root = try Arguments(
        value,
        allowed: [
          "action", "path", "expectedSHA256", "edits", "content", "patch", "dryRun",
        ])
      let action = try root.string("action", max: 16)
      switch action {
      case "create":
        let a = try Arguments(value, allowed: ["action", "path", "content", "dryRun"])
        let path = try a.string("path")
        let content = try a.string("content", max: 1_048_576)
        let dryRun = try a.flag("dryRun", default: false)
        let result = try await checkpointedEdit(
          action: "create", paths: [path], dryRun: dryRun
        ) {
          try await workspace.create(path: path, content: content, dryRun: dryRun)
        }
        return ToolOutput(result)
      case "edit":
        let a = try Arguments(
          value, allowed: ["action", "path", "expectedSHA256", "edits", "dryRun"])
        guard let rows = a["edits"].array else {
          throw Failure.invalid("edit_files action=edit requires edits and expectedSHA256.")
        }
        let edits = try rows.map { row in
          let e = try Arguments(row, allowed: ["oldText", "newText"])
          return try TextEdit(
            oldText: e.string("oldText", max: 1_048_576),
            newText: e.string("newText", max: 1_048_576))
        }
        let path = try a.string("path")
        let expectedSHA = try a.string("expectedSHA256", max: 64)
        let dryRun = try a.flag("dryRun", default: false)
        let result = try await checkpointedEdit(
          action: "edit", paths: [path], dryRun: dryRun
        ) {
          try await workspace.edit(
            path: path, expectedSHA: expectedSHA, edits: edits, dryRun: dryRun)
        }
        return ToolOutput(result)
      case "patch":
        let a = try Arguments(value, allowed: ["action", "patch", "dryRun"])
        let patch = try a.string("patch", max: 1_048_576)
        let dryRun = try a.flag("dryRun", default: false)
        let paths = try UnifiedPatch.parse(patch).map(\.path)
        let result = try await checkpointedEdit(
          action: "patch", paths: paths, dryRun: dryRun
        ) {
          try await workspace.applyPatch(patch, dryRun: dryRun)
        }
        return ToolOutput(result)
      default:
        throw Failure.invalid("edit_files action must be edit, create or patch.")
      }
    case "run_process", "run_shell":
      try requireExecution(name == "run_shell" ? .rawShell : .process)
      let fields: Set<String> = [
        "cwd", "environment", "timeout", "syncWait", "stdin", "interactive", "terminalMode",
        "idempotencyKey", "reportPath",
      ]
      let a = try Arguments(
        value,
        allowed: fields.union(
          name == "run_shell" ? ["command"] : ["taskId", "program", "args"]))
      let program: String
      let args: [String]
      let discoveredTask: ProjectTask?
      let discoveredScript: String?
      if name == "run_shell" {
        let command = try a.string("command", max: 8192)
        try ProcessPolicy.validateShell(command)
        #if os(macOS)
          program = "/bin/zsh"
          args = ["-f", "-c", command]
        #else
          program = "/bin/bash"
          args = ["--noprofile", "--norc", "-c", command]
        #endif
        discoveredTask = nil
        discoveredScript = command
      } else if a.has("taskId") {
        guard !a.has("program"), !a.has("args"), !a.has("cwd"), !a.has("environment") else {
          throw Failure.invalid(
            "taskId cannot be combined with program, args, cwd or environment.")
        }
        let taskID = try a.string("taskId", max: 128)
        let graph = try await ProjectInspector(workspace: workspace).graph()
        let task = try ProjectTaskRegistry(graph: graph).task(taskID)
        try executionPolicy.authorizeTask(
          task.id, sandboxStatus: sandboxBackend.status)
        program = task.program
        args = task.args
        discoveredTask = task
        discoveredScript = task.provider == "node" ? graph.scripts[task.kind] : nil
      } else {
        guard a.has("program") else {
          throw Failure.invalid("run_process requires exactly one of taskId or program.")
        }
        program = try a.string("program")
        args = try a.strings("args")
        discoveredTask = nil
        discoveredScript = nil
      }
      let workingPath: String
      if let discoveredTask {
        workingPath = discoveredTask.cwd
      } else {
        workingPath = try a.string("cwd", default: ".")
      }
      let cwd = try await workspace.workingDirectory(workingPath)
      let environment = discoveredTask == nil && a.has("environment")
        ? try executionPolicy.userEnvironment(
            a["environment"], sandboxStatus: sandboxBackend.status)
        : [:]
      try executionPolicy.validateExecutable(
        program: program,
        cwd: cwd,
        environment: environment,
        sandboxStatus: sandboxBackend.status)
      guard accepting else { throw Failure.stopped }
      let request = try ProcessRequest(
        program: program, args: args, cwd: cwd, projectRoot: workspace.root,
        environment: environment,
        input: a.has("stdin") ? a.string("stdin", max: 65_536) : nil,
        interactive: a.flag("interactive", default: false),
        terminalMode: a.string("terminalMode", default: "pipe", max: 8),
        timeout: a.integer("timeout", default: 120, range: 1...86_400),
        syncWait: a.integer("syncWait", default: 2, range: 0...3),
        idempotencyKey: a.has("idempotencyKey") ? a.string("idempotencyKey", max: 128) : nil)
      // Hard deny and Project scope are mode-independent. Permission Mode only
      // decides whether an already project-scoped sensitive operation asks first.
      try ProcessPolicy.validate(request)
      try ProcessPolicy.validateProjectScope(request)
      if let discoveredScript {
        try ProcessPolicy.validateProjectScriptScope(
          discoveredScript, cwd: cwd, projectRoot: workspace.root)
      }

      let requestRequirement = ProcessPolicy.approvalRequirement(
        request, rawShell: name == "run_shell")
      let scriptRequirement = try discoveredScript.flatMap {
        try ProcessPolicy.projectScriptApprovalRequirement($0)
      }
      var localOperationApproval: PendingOperationApproval?
      if executionPolicy.profile == .fullLocal,
        context.project.permissionMode.asksForSensitiveProjectOperations,
        let requirement = requestRequirement ?? scriptRequirement
      {
        guard let operationApprovals else {
          throw Failure(
            "local_action_approval_required",
            "This command requires one-time local approval: \(requirement.reason)",
            "Run it from the Luti app Runtime so the Mac user can approve the exact operation.")
        }
        let visibleCommand = Budget.prefix(
          redactor.clean(([request.program] + request.args).joined(separator: " ")),
          bytes: 768)
        let approvalGeneration = context.generation
        localOperationApproval = try await operationApprovals.request(
          tool: name,
          summary: visibleCommand,
          reason: requirement.reason,
          project: context.project)
        // Approval is one-shot for this exact suspended call. Never use it as a
        // durable permission, and never launch after Stop or a context change.
        guard accepting, approvalGeneration == context.generation else {
          throw Failure.stopped
        }
      }

      var result: JSONValue
      if executionPolicy.profile.requiresSandboxBackend {
        // Recheck after asynchronous discovery/cwd resolution. The backend must
        // also verify its project grant and enforcement when it actually launches.
        try executionPolicy.authorize(.process, sandboxStatus: sandboxBackend.status)
        result = try await sandboxBackend.submitProcess(
          request, policy: executionPolicy, jobs: jobs)
      } else {
        let graph = try? await ProjectInspector(workspace: workspace).graph(path: workingPath)
        let touched = (try? memoryStore.session(activity.runID).touchedFiles) ?? []
        let scope = ValidationScopeRequest(
          files: workspace, paths: touched + (graph?.manifests.map(\.path) ?? []),
          taskID: discoveredTask?.id, purpose: discoveredTask?.kind,
          reportPath: a.has("reportPath") ? try a.string("reportPath") : nil)
        result = try await jobs.submit(request, validation: scope)
      }
      if let discoveredTask {
        result = result.adding("task", discoveredTask.json)
      }
      if let localOperationApproval {
        result = result.adding("localApproval", [
          "id": .string(localOperationApproval.id.uuidString.lowercased()),
          "scope": "oneShot",
          "approvedAt": .string(ISO8601DateFormatter().string(from: Date())),
        ])
      }
      return ToolOutput(result, isError: result["failure"] != .null)
    case "job_query":
      let root = try ActionContracts.arguments("job_query", value)
      let action = try root.string("action", max: 16)
      switch action {
      case "list":
        return ToolOutput([
          "action": "list",
          "jobs": .array(
            await jobs.list().map {
              $0.removing(["stdoutTail", "stderrTail", "stdoutHead", "stderrHead"])
            }),
        ])
      case "status":
        let a = root
        let id = try a.string("jobId", max: 80)
        let known = a.has("knownStatus") ? try a.string("knownStatus", max: 16) : nil
        if let known,
           !["running", "stopping", "completed", "failed", "timed_out", "stopped"].contains(known)
        {
          throw Failure.invalid("knownStatus is not a valid Job state.")
        }
        let result = try await jobs.status(
          id,
          waitMilliseconds: a.integer("waitMs", default: 0, range: 0...20_000),
          knownStatus: known)
          .adding("action", "status")
        return ToolOutput(result)
      case "logs":
        let a = root
        let id = try a.string("jobId", max: 80)
        let hasStdout = a.has("stdoutOffset")
        var result: JSONValue
        if hasStdout {
          result = try await jobs.logs(
            id,
            stdoutOffset: a.integer("stdoutOffset", default: 0, range: 0...2_147_483_647),
            stderrOffset: a.integer("stderrOffset", default: 0, range: 0...2_147_483_647),
            maxBytes: a.integer("maxBytes", default: 32_768, range: 1...65_536))
        } else {
          result = try await jobs.status(id)
        }
        result = result
          .adding("action", "logs")
          .adding("nextStdoutOffset", result["stdoutBytes"])
          .adding("nextStderrOffset", result["stderrBytes"])
        if try a.flag("exportFull", default: false), let bytes = try await jobs.fullLog(id) {
          let artifact = try await artifacts.insert(
            bytes, name: "job-log.txt", mimeType: "text/plain", source: .process)
          return ToolOutput(
            result.adding("artifact", artifact.metadata), content: [artifact.link])
        }
        return ToolOutput(result)
      default:
        throw Failure.invalid("job_query action must be list, status or logs.")
      }

    case "job_action":
      let root = try ActionContracts.arguments("job_action", value)
      let action = try root.string("action", max: 16)
      switch action {
      case "stop":
        let a = root
        let result = try await jobs.stop(a.string("jobId", max: 80))
          .adding("action", "stop")
          .adding("effect", "submitted")
        return ToolOutput(result, isError: result["failure"] != .null)
      case "input":
        try requireExecution(.process)
        let a = root
        let text = try a.string("text", default: "", max: 16_384)
        let close = try a.flag("close", default: false)
        guard !text.isEmpty || close else {
          throw Failure.invalid("job_action input requires text and/or close=true.")
        }
        let result = try await jobs.input(
          a.string("jobId", max: 80), text: text, close: close)
          .adding("action", "input")
          .adding("effect", "submitted")
        return ToolOutput(result, isError: result["failure"] != .null)
      default:
        throw Failure.invalid("job_action action must be stop or input.")
      }

    case "git_query":
      let root = try Arguments(
        value,
        allowed: [
          "action", "path", "staged", "maxCount", "revision", "file", "startLine", "endLine",
        ])
      let action = try root.string("action", max: 16)
      let service = GitService(workspace: workspace, jobs: jobs)
      let result: JSONValue
      switch action {
      case "status":
        let a = try Arguments(value, allowed: ["action", "path"])
        result = try await service.run(
          diff: false, staged: false, path: a.string("path", default: "."))
      case "diff":
        let a = try Arguments(value, allowed: ["action", "path", "staged"])
        result = try await service.run(
          diff: true, staged: a.flag("staged", default: false),
          path: a.string("path", default: "."))
      case "log":
        let a = try Arguments(value, allowed: ["action", "path", "maxCount"])
        result = try await service.log(
          path: a.string("path", default: "."),
          maxCount: a.integer("maxCount", default: 20, range: 1...100))
      case "show":
        let a = try Arguments(value, allowed: ["action", "path", "revision"])
        result = try await service.show(
          path: a.string("path", default: "."),
          revision: a.string("revision", max: 200))
      case "blame":
        let a = try Arguments(
          value, allowed: ["action", "path", "file", "startLine", "endLine"])
        result = try await service.blame(
          path: a.string("path", default: "."),
          file: a.string("file", max: 4096),
          startLine: a.integer("startLine", default: 1, range: 1...1_000_000),
          endLine: a.integer("endLine", default: 1, range: 1...1_000_000))
      default:
        throw Failure.invalid("git_query action must be status, diff, log, show or blame.")
      }
      let tagged = result.adding("action", .string(action))
      return ToolOutput(tagged, isError: tagged["failure"] != .null)
    case "computer_observe":
      try requireExecution(.desktopControl)
      return try await computer.observe(value)
    case "computer_wait":
      try requireExecution(.desktopControl)
      return try await computer.wait(value)
    case "computer_action":
      try requireExecution(.desktopControl)
      return try await computer.action(value)
    default: throw Failure.invalid("Unknown tool.")
    }
  }
  public func stop() async {
    if !accepting {
      if !stopFinished { await withCheckedContinuation { stopWaiters.append($0) } }
      return
    }
    accepting = false
    switching = true
    await operationApprovals?.stop()
    let owned = context
    async let project: Void = owned.shutdown()
    async let desktop: Void = computer.stop()
    async let screenshots: Void = images.stop()
    _ = await (project, desktop, screenshots)
    // Providers are closed first so blocked calls can finish. Only then finalize
    // durable sessions and allow AppModel to expose the stopped/clearable state.
    if callsInFlight > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    let finalJobs = await owned.jobs.list()
    journalWrite { try owned.store.reconcileSessionJobs(finalJobs, runID: activity.runID) }
    for store in visitedStores.values { journalWrite { try store.finishSession(activity.runID) } }
    stopFinished = true
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
