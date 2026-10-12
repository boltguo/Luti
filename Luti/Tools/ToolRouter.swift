import Foundation

private struct ProjectRuntimeContext: Sendable {
  let project: ApprovedProject
  let projectToken = "project_" + UUID().uuidString.lowercased()
  let workspace: WorkspaceFiles
  let jobs: JobManager
  let artifacts: ArtifactStore
  let browser: BrowserProvider
  let code: CodeQueryService
  let activityDirectory: URL

  init(project: ApprovedProject, workspace: WorkspaceFiles, jobs: JobManager,
       redactor: Redactor, dataRoot: URL, helper: URL) {
    self.project = project
    self.workspace = workspace
    self.jobs = jobs
    let artifacts = ArtifactStore()
    self.artifacts = artifacts
    browser = BrowserProvider(workspace: workspace, artifacts: artifacts, redactor: redactor)
    code = CodeQueryService(workspace: workspace, helper: helper)
    activityDirectory = LocalLogStore.activityDirectory(for: project.url, dataRoot: dataRoot)
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
  private let executionPolicy: ProjectExecutionPolicy
  private let redactor: Redactor
  private let context: ProjectRuntimeContext
  private var accepting = true
  private var lastSuccess: Date?
  // Bounded, current-run validation inputs. No session journal is persisted.
  private var touchedFiles: [String] = []

  var workspace: WorkspaceFiles { context.workspace }
  var jobs: JobManager { context.jobs }
  var artifacts: ArtifactStore { context.artifacts }
  var browser: BrowserProvider { context.browser }
  var code: CodeQueryService { context.code }
  var projectToken: String { context.projectToken }

  public init(
    workspace: WorkspaceFiles, jobs: JobManager,
    activity: ActivityStore, executionPolicy: ProjectExecutionPolicy = .readOnly,
    redactor: Redactor = Redactor(), project: ApprovedProject? = nil,
    helper: URL = JobManager.defaultHelper, contextDataRoot: URL? = nil
  ) throws {
    let selected = project ?? ApprovedProject(id: "runtime-project", url: workspace.root)
    guard selected.url.standardizedFileURL.resolvingSymlinksInPath() == workspace.root else {
      throw Failure.invalid("The selected folder must match this runtime's workspace.")
    }
    self.activity = activity
    self.executionPolicy = executionPolicy
    self.redactor = redactor
    context = ProjectRuntimeContext(
      project: selected, workspace: workspace, jobs: jobs, redactor: redactor,
      dataRoot: contextDataRoot ?? LutiPaths.root, helper: helper)
  }

  public func lastSuccessfulCall() -> Date? { lastSuccess }

  public func jobList() async -> [JSONValue] { await jobs.list() }
  public func jobLifecycles() async -> [JSONValue] { await jobs.lifecycles() }

  public func stopActiveJobs() async -> Int { await context.jobs.stopActive() }

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
  /// passes its own grant so Activity can attribute it.
  public func call(_ name: String, arguments value: JSONValue, grant: ToolGrant = .local) async
    -> ToolOutput
  {
    // Once Stop has returned, even an in-process caller cannot recreate cleared
    // history. Track every admitted call until its final activity write finishes.
    guard accepting else { return .failure(.stopped) }
    guard ToolCatalog.names.contains(name) else { return .failure(.invalid("Unknown tool.")) }
    callsInFlight += 1
    defer { finishTrackedCall() }
    let started = Date()
    let owner = context
    let descriptor = activityDescriptor(name, value)
    let source = grant.context.map { ActivitySource(transport: $0.transport, clientID: $0.clientID,
      clientName: Budget.prefix(redactor.clean($0.clientName), bytes: 64), authorizationID: $0.authorizationID) }
    let activityID = await activity.begin(
      tool: name, action: descriptor.action, targetType: descriptor.targetType,
      target: descriptor.target, cwd: value["cwd"].string, source: source,
      persistenceDirectory: owner.activityDirectory)
    let output: ToolOutput
    do {
      guard accepting else { throw Failure.stopped }
      try validateProjectBinding(name, arguments: value)
      try Task.checkCancellation()
      let arguments = ProjectBindingContract.acceptsToken(name) ? value.removing(["projectToken"]) : value
      output = try await dispatch(name, arguments)
      if !output.isError {
        lastSuccess = Date()
        recordTouchedFiles(tool: name, result: output.data)
      }
      let failure = output.data["failure"]
      await activity.finish(
        id: activityID, status: output.isError ? "failed" : "ok", started: started,
        summary: activitySummary(name, output), cwd: value["cwd"].string,
        jobID: output.data["jobId"].string,
        artifactURI: output.data["artifact"]["resource"].string ?? output.data["resource"].string,
        effect: activityEffect(name, output), operationState: activityOperationState(name, output),
        errorCode: failure["error"].string ?? output.data["error"].string,
        recovery: failure["recovery"].string ?? output.data["recovery"].string)
    } catch {
      let failure = Failure.safe(error)
      let effect = failure.effect
        ?? (["outcome_unknown", "browser_outcome_unknown", "browser_transport_unknown"].contains(failure.code) ? "possible" : "none")
      if ["project_binding_required", "project_binding_mismatch"].contains(failure.code) {
        output = ToolOutput(failure.json.adding("currentProject", [
          "projectId": .string(context.project.id), "generation": .int(1),
        ]), isError: true)
      } else {
        output = .failure(failure)
      }
      await activity.finish(id: activityID, status: "failed", started: started,
        summary: failure.message, cwd: value["cwd"].string, effect: effect,
        errorCode: failure.code, recovery: failure.recovery)
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
                      "Read project_info, confirm the intended workspace, then submit the operation with that projectToken.")
      }
      return
    }
    guard let token = supplied.string, token.utf8.count <= 80, token == context.projectToken else {
      throw Failure("project_binding_mismatch", "The operation targets a stale or different project context.",
                    "Read project_info and confirm the intended workspace before deciding what to do. No requested operation was executed.")
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
    case "project_info":
      return ActivityDescriptor(action: nil, targetType: "project", target: "")
    case "runtime_status":
      return ActivityDescriptor(action: nil, targetType: "runtime", target: "")
    case "read_files":
      let paths = (value["paths"].array ?? []).compactMap(\.string)
      return ActivityDescriptor(
        action: nil, targetType: paths.count == 1 ? "file" : "files",
        target: paths.count <= 3 ? paths.joined(separator: ", ") : "\(paths.count) files")
    case "search_project":
      return ActivityDescriptor(
        action: value["mode"].string ?? "literal", targetType: "query",
        target: value["query"].string ?? "")
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
        target: action == "patch" ? "" : (value["path"].string ?? ""))
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
        target: value["taskId"].string
          ?? ([value["program"].string ?? ""] + (value["args"].array ?? []).compactMap(\.string))
            .joined(separator: " "))
    case "run_shell":
      return ActivityDescriptor(action: nil, targetType: "shell", target: value["command"].string ?? "")
    case "job_query", "job_action":
      return ActivityDescriptor(
        action: action, targetType: "job",
        target: value["jobId"].string ?? "")
    case "git_query":
      return ActivityDescriptor(
        action: action, targetType: "repository", target: value["path"].string ?? ".")
    case "browser_session":
      if action == "open" {
        return ActivityDescriptor(action: action, targetType: "origin", target: browserOrigin())
      }
      return ActivityDescriptor(
        action: action, targetType: "tab", target: value["tabId"].string ?? "")
    case "browser_observe":
      return ActivityDescriptor(
        action: action, targetType: action == "tabs" ? "browser" : "tab",
        target: action == "tabs" ? "" : (value["tabId"].string ?? ""))
    case "browser_action", "browser_transfer", "browser_inspect", "browser_dialog":
      return ActivityDescriptor(
        action: action, targetType: "tab", target: value["tabId"].string ?? "")
    case "browser_evaluate":
      return ActivityDescriptor(
        action: nil, targetType: "tab", target: value["tabId"].string ?? "")
    default:
      return ActivityDescriptor(
        action: action, targetType: nil,
        target: value["path"].string ?? value["jobId"].string ?? value["tabId"].string
          ?? value["window"].string ?? name)
    }
  }
  private func activitySummary(_ name: String, _ output: ToolOutput) -> String {
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
    let mutations: Set<String> = [
      "edit_files", "path_action", "import_artifact", "run_process", "run_shell", "job_action",
      "browser_session", "browser_action", "browser_transfer",
      "browser_dialog", "browser_evaluate",
    ]
    if ["run_process", "run_shell", "job_action", "browser_evaluate"].contains(name) {
      return "submitted"
    }
    return mutations.contains(name) ? "confirmed" : "none"
  }

  private func recordTouchedFiles(tool: String, result: JSONValue) {
    var paths: [JSONValue] = []
    if ["edit_files", "import_artifact"].contains(tool), result["applied"] == true,
       result["dryRun"] != true {
      paths = (result["files"].array ?? []).filter { $0["wouldChange"] == true }.map { $0["path"] }
        + [result["path"]]
    } else if tool == "path_action", result["effect"] == "confirmed" {
      paths = [result["path"], result["source"], result["destination"]]
    }
    for value in paths {
      guard let path = value.string, (try? WorkspaceFiles.components(path)) != nil else { continue }
      touchedFiles.removeAll { $0 == path }
      touchedFiles.append(path)
    }
    if touchedFiles.count > 512 { touchedFiles.removeFirst(touchedFiles.count - 512) }
  }

  func requireExecution(_ capability: ExecutionCapability) throws {
    try executionPolicy.authorize(capability)
  }

  private func dispatch(_ name: String, _ value: JSONValue) async throws -> ToolOutput {
    if let output = try await extendedTool(name, value) { return output }
    switch name {
    case "project_info":
      _ = try Arguments(value, allowed: [])
      let info = try await workspace.projectInfo()
      return ToolOutput(
        info
          .adding("projectId", .string(context.project.id))
          .adding("generation", .int(1))
          .adding("projectToken", .string(context.projectToken)))
    case "runtime_status":
      _ = try Arguments(value, allowed: [])
      return ToolOutput([
        "name": "Luti", "version": .string(Identity.version), "running": .bool(accepting),
        "executionEnabled": .bool(
          executionPolicy.commandExecutionAvailable),
        "executionPolicy": executionPolicy.statusJSON,
        "activeProject": [
          "id": .string(context.project.id), "name": .string(context.project.name),
          "path": .string(context.project.path),
          "generation": .int(1),
        ],
        "jobs": .array(await jobs.list().map { $0.removing(["stdoutTail", "stderrTail", "stdoutHead", "stderrHead"]) }),
        "capabilities": [
          "projectFiles": true,
          "projectWrite": .bool(executionPolicy.workspaceWriteAvailable),
          "commandExecution": .bool(
            executionPolicy.commandExecutionAvailable),
          "rawShell": executionPolicy.statusJSON["rawShell"],
          "executionScope": .string(
            executionPolicy.scopeDescription),
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
        return ToolOutput(try await workspace.create(
          path: path, content: content, dryRun: dryRun))
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
        return ToolOutput(try await workspace.edit(
          path: path, expectedSHA: expectedSHA, edits: edits, dryRun: dryRun))
      case "patch":
        let a = try Arguments(value, allowed: ["action", "patch", "dryRun"])
        let patch = try a.string("patch", max: 1_048_576)
        let dryRun = try a.flag("dryRun", default: false)
        return ToolOutput(try await workspace.applyPatch(patch, dryRun: dryRun))
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
            a["environment"])
        : [:]
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
      // Full access retains explicit command denies and project scope checks.
      try ProcessPolicy.validate(request)
      try ProcessPolicy.validateProjectScope(request)
      if let discoveredScript {
        try ProcessPolicy.validateProjectScriptScope(
          discoveredScript, cwd: cwd, projectRoot: workspace.root)
      }

      let graph = try? await ProjectInspector(workspace: workspace).graph(path: workingPath)
      let scope = ValidationScopeRequest(
        files: workspace, paths: touchedFiles + (graph?.manifests.map(\.path) ?? []),
        taskID: discoveredTask?.id, purpose: discoveredTask?.kind,
        reportPath: a.has("reportPath") ? try a.string("reportPath") : nil)
      var result = try await jobs.submit(request, validation: scope)
      if let discoveredTask {
        result = result.adding("task", discoveredTask.json)
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
        // A paged read continues where this page ended; a snapshot continues at the end.
        result = result
          .adding("action", "logs")
          .adding("nextStdoutOffset", hasStdout ? result["delta"]["stdout"]["nextOffset"] : result["stdoutBytes"])
          .adding("nextStderrOffset", hasStdout ? result["delta"]["stderr"]["nextOffset"] : result["stderrBytes"])
        if try a.flag("exportFull", default: false), let bytes = try await jobs.fullLog(id) {
          let artifact = try await artifacts.insert(
            bytes, name: "job-log.txt", mimeType: "text/plain")
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
    default: throw Failure.invalid("Unknown tool.")
    }
  }
  public func stop() async {
    if !accepting {
      if !stopFinished { await withCheckedContinuation { stopWaiters.append($0) } }
      return
    }
    accepting = false
    let owned = context
    await owned.shutdown()
    // Close providers first to release blocked calls, then wait for final
    // activity writes before exposing the stopped/clearable state.
    if callsInFlight > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    await activity.reconcileJobs(await owned.jobs.lifecycles())
    touchedFiles.removeAll()
    stopFinished = true
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
}
