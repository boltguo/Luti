import Foundation

public enum ExecutionProfile: String, CaseIterable, Sendable {
  case readOnly
  case workspace
  case isolated
  case fullLocal

  public var requiresSandboxBackend: Bool {
    self == .workspace || self == .isolated
  }
}

public enum ExecutionNetworkPolicy: Sendable, Equatable {
  case none
  case allowlist(Set<String>)
  case unrestricted

  public var mode: String {
    switch self {
    case .none: "none"
    case .allowlist: "allowlist"
    case .unrestricted: "unrestricted"
    }
  }

  var hosts: [String] {
    switch self {
    case .allowlist(let hosts): hosts.sorted()
    case .none, .unrestricted: []
    }
  }

  public var json: JSONValue {
    let value: JSONValue = ["mode": .string(mode)]
    return hosts.isEmpty ? value : value.adding("hosts", .array(hosts.map(JSONValue.string)))
  }
}

public enum ExecutionCapability: String, Sendable {
  case workspaceWrite
  case process
  case rawShell
  case codeIntelligence
  case browserAutomation
  case desktopControl
}

public struct PendingOperationApproval: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let tool: String
  public let summary: String
  public let reason: String
  public let projectName: String
  public let projectPath: String
  public let createdAt: Date
  public let expiresAt: Date
}

/// In-memory, one-shot approval for an exact high-risk local action.
///
/// It is deliberately separate from OAuth authorization. A Host may be authorized
/// to use process tools while a particular opaque/destructive/external command still
/// requires the person at the Mac to approve that exact invocation.
public actor OperationApprovalBroker {
  private enum Decision { case approved, denied, expired, stopped }
  private struct Waiting {
    let request: PendingOperationApproval
    let continuation: CheckedContinuation<Decision, Never>
  }

  private let timeoutSeconds: Int
  private var waiting: [UUID: Waiting] = [:]
  private var stopped = false

  public init(timeoutSeconds: Int = 120) {
    self.timeoutSeconds = max(10, min(timeoutSeconds, 600))
  }

  public func request(
    tool: String,
    summary: String,
    reason: String,
    project: ApprovedProject
  ) async throws -> PendingOperationApproval {
    guard !stopped else { throw Failure.stopped }
    let now = Date()
    let request = PendingOperationApproval(
      id: UUID(),
      tool: Budget.prefix(tool, bytes: 32),
      summary: Budget.prefix(summary, bytes: 768),
      reason: Budget.prefix(reason, bytes: 512),
      projectName: Budget.prefix(project.name, bytes: 128),
      projectPath: Budget.prefix(project.path, bytes: 4096),
      createdAt: now,
      expiresAt: now.addingTimeInterval(TimeInterval(timeoutSeconds)))

    let decision = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiting[request.id] = Waiting(request: request, continuation: continuation)
        Task {
          try? await Task.sleep(for: .seconds(timeoutSeconds))
          self.expire(request.id)
        }
      }
    } onCancel: {
      Task { await self.cancel(request.id) }
    }

    switch decision {
    case .approved:
      return request
    case .denied:
      throw Failure(
        "local_action_denied",
        "The local user denied this operation.",
        "Use a project-scoped structured operation, or ask the user to approve a revised command.")
    case .expired:
      throw Failure(
        "local_action_approval_expired",
        "The local approval request expired before execution.",
        "Retry only if the user still wants the operation; no process was started.")
    case .stopped:
      throw Failure.stopped
    }
  }

  public func pendingApprovals() -> [PendingOperationApproval] {
    waiting.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
  }

  public func resolve(_ id: UUID, approved: Bool) {
    finish(id, decision: approved ? .approved : .denied)
  }

  public func stop() {
    stopped = true
    let entries = waiting.values
    waiting.removeAll()
    for entry in entries { entry.continuation.resume(returning: .stopped) }
  }

  private func expire(_ id: UUID) {
    finish(id, decision: .expired)
  }

  private func cancel(_ id: UUID) {
    finish(id, decision: .stopped)
  }

  private func finish(_ id: UUID, decision: Decision) {
    guard let entry = waiting.removeValue(forKey: id) else { return }
    entry.continuation.resume(returning: decision)
  }
}

/// Immutable execution authority captured when a Runtime starts.
///
/// This is deliberately a semantic policy, not an OS sandbox. The current backend
/// can enforce read-only vs full-local capability gates plus bounded environment /
/// executable allowlists. Workspace and isolated process profiles stay fail-closed
/// until an OS-enforced SandboxBackend is connected in P0-5.
public struct ProjectExecutionPolicy: Sendable, Equatable {
  public let profile: ExecutionProfile
  public let localApproval: Bool
  public let network: ExecutionNetworkPolicy
  public let environmentAllowlist: Set<String>?
  public let executableAllowlist: Set<String>?
  public let taskAllowlist: Set<String>?
  public let rawShellAllowed: Bool

  private init(
    profile: ExecutionProfile,
    localApproval: Bool,
    network: ExecutionNetworkPolicy,
    environmentAllowlist: Set<String>?,
    executableAllowlist: Set<String>?,
    taskAllowlist: Set<String>?,
    rawShellAllowed: Bool
  ) {
    self.profile = profile
    self.localApproval = localApproval
    self.network = network
    self.environmentAllowlist = environmentAllowlist
    self.executableAllowlist = executableAllowlist
    self.taskAllowlist = taskAllowlist
    self.rawShellAllowed = rawShellAllowed
  }

  public static let readOnly = ProjectExecutionPolicy(
    profile: .readOnly,
    localApproval: false,
    network: .none,
    environmentAllowlist: [],
    executableAllowlist: [],
    taskAllowlist: [],
    rawShellAllowed: false)

  public static func fullLocal(localApproval: Bool) -> ProjectExecutionPolicy {
    ProjectExecutionPolicy(
      profile: .fullLocal,
      localApproval: localApproval,
      network: .unrestricted,
      environmentAllowlist: nil,
      executableAllowlist: nil,
      taskAllowlist: nil,
      rawShellAllowed: true)
  }

  /// Semantic workspace profile. Project file mutations can be authorized now,
  /// while process/browser execution remains unavailable until SandboxBackend exists.
  public static func workspace(
    localApproval: Bool,
    network: ExecutionNetworkPolicy = .none,
    environmentAllowlist: Set<String> = [],
    executableAllowlist: Set<String> = [],
    taskAllowlist: Set<String> = []
  ) throws -> ProjectExecutionPolicy {
    try restricted(
      profile: .workspace,
      localApproval: localApproval,
      network: network,
      environmentAllowlist: environmentAllowlist,
      executableAllowlist: executableAllowlist,
      taskAllowlist: taskAllowlist,
      rawShellAllowed: false)
  }

  /// Semantic isolated profile. It also stays fail-closed until the later isolated
  /// execution backend can actually enforce filesystem and network boundaries.
  public static func isolated(
    localApproval: Bool,
    network: ExecutionNetworkPolicy = .none,
    environmentAllowlist: Set<String> = [],
    executableAllowlist: Set<String> = [],
    taskAllowlist: Set<String> = []
  ) throws -> ProjectExecutionPolicy {
    try restricted(
      profile: .isolated,
      localApproval: localApproval,
      network: network,
      environmentAllowlist: environmentAllowlist,
      executableAllowlist: executableAllowlist,
      taskAllowlist: taskAllowlist,
      rawShellAllowed: false)
  }

  /// Optional stricter full-local policy for enterprise/local policy adapters.
  /// It does not create a sandbox; it only narrows already-sanitized inputs.
  public static func restrictedFullLocal(
    localApproval: Bool,
    environmentAllowlist: Set<String>,
    executableAllowlist: Set<String>,
    taskAllowlist: Set<String>? = nil,
    rawShellAllowed: Bool = false
  ) throws -> ProjectExecutionPolicy {
    try restricted(
      profile: .fullLocal,
      localApproval: localApproval,
      network: .unrestricted,
      environmentAllowlist: environmentAllowlist,
      executableAllowlist: executableAllowlist,
      taskAllowlist: taskAllowlist,
      rawShellAllowed: rawShellAllowed)
  }

  private static func restricted(
    profile: ExecutionProfile,
    localApproval: Bool,
    network: ExecutionNetworkPolicy,
    environmentAllowlist: Set<String>,
    executableAllowlist: Set<String>,
    taskAllowlist: Set<String>?,
    rawShellAllowed: Bool
  ) throws -> ProjectExecutionPolicy {
    let environment = try validatedEnvironmentKeys(environmentAllowlist)
    let executables = try validatedExecutablePaths(executableAllowlist)
    let tasks = try taskAllowlist.map(validatedTaskIDs)
    return ProjectExecutionPolicy(
      profile: profile,
      localApproval: localApproval,
      network: network,
      environmentAllowlist: environment,
      executableAllowlist: executables,
      taskAllowlist: tasks,
      rawShellAllowed: rawShellAllowed)
  }

  public var workspaceWriteAvailable: Bool {
    localApproval && profile != .readOnly
  }

  public var commandExecutionAvailable: Bool {
    commandExecutionAvailable(sandboxStatus: .unavailable)
  }

  public func commandExecutionAvailable(
    sandboxStatus: SandboxBackendStatus
  ) -> Bool {
    guard localApproval else { return false }
    switch profile {
    case .readOnly:
      return false
    case .workspace, .isolated:
      return sandboxStatus.canEnforceProcess(profile, network: network)
    case .fullLocal:
      return true
    }
  }

  public var browserAutomationAvailable: Bool {
    localApproval && profile == .fullLocal
  }

  public var desktopControlAvailable: Bool {
    localApproval && profile == .fullLocal
  }

  public func authorize(
    _ capability: ExecutionCapability,
    sandboxStatus: SandboxBackendStatus = .unavailable
  ) throws {
    switch capability {
    case .workspaceWrite:
      guard profile != .readOnly else { throw denied(capability) }
      try requireLocalApproval()

    case .process:
      guard profile != .readOnly else { throw denied(capability) }
      try requireLocalApproval()
      if profile.requiresSandboxBackend,
         !sandboxStatus.canEnforceProcess(profile, network: network)
      {
        throw sandboxUnavailable(sandboxStatus)
      }

    case .codeIntelligence:
      guard profile != .readOnly else { throw denied(capability) }
      try requireLocalApproval()
      // The current LSP transport launches providers directly. Until a future
      // sandbox backend owns that transport too, workspace/isolated stay closed.
      if profile.requiresSandboxBackend {
        throw Failure(
          "execution_backend_unavailable",
          "Code intelligence has no sandbox-routed language service transport.",
          "A process backend does not authorize Code Intelligence. Keep this capability disabled until its transport is owned by an enforcing backend.")
      }

    case .rawShell:
      guard profile == .fullLocal else { throw denied(capability) }
      try requireLocalApproval()
      guard rawShellAllowed else { throw denied(capability) }

    case .browserAutomation, .desktopControl:
      guard profile == .fullLocal else { throw denied(capability) }
      try requireLocalApproval()
    }
  }

  public func userEnvironment(
    _ value: JSONValue,
    sandboxStatus: SandboxBackendStatus = .unavailable
  ) throws -> [String: String] {
    try authorize(.process, sandboxStatus: sandboxStatus)
    let sanitized = try ProcessPolicy.userEnvironment(value)
    guard let environmentAllowlist else { return sanitized }
    let rejected = Set(sanitized.keys).subtracting(environmentAllowlist)
    guard rejected.isEmpty else {
      throw Failure(
        "environment_not_allowed",
        "The execution policy does not allow one or more requested environment fields.",
        "Use only locally approved environment keys. Credentials still belong outside model-visible commands.")
    }
    return sanitized
  }

  public func validateExecutable(
    program: String,
    cwd: URL,
    environment: [String: String],
    sandboxStatus: SandboxBackendStatus = .unavailable
  ) throws {
    try authorize(.process, sandboxStatus: sandboxStatus)
    guard let executableAllowlist else { return }
    var effective = ProcessPolicy.baseEnvironment
    effective.merge(environment, uniquingKeysWith: { _, new in new })
    let resolved = try ProcessPolicy.resolve(program, cwd: cwd, environment: effective)
      .standardizedFileURL.resolvingSymlinksInPath().path
    guard executableAllowlist.contains(resolved) else {
      throw Failure(
        "executable_not_allowed",
        "The resolved executable is not allowed by this project's execution policy.",
        "Use an approved executable or change the project policy locally before starting the Runtime.")
    }
  }

  public func authorizeTask(
    _ id: String,
    sandboxStatus: SandboxBackendStatus = .unavailable
  ) throws {
    try authorize(.process, sandboxStatus: sandboxStatus)
    guard !id.isEmpty, id.utf8.count <= 128, !id.contains("\0") else {
      throw Failure.invalid("Task ID must be non-empty and at most 128 bytes.")
    }
    guard let taskAllowlist else { return }
    guard taskAllowlist.contains(id) else {
      throw Failure(
        "task_not_allowed",
        "This task is not allowed by the project's execution policy.",
        "Run an approved discovered task or change the project policy locally.")
    }
  }

  public var statusJSON: JSONValue {
    statusJSON(sandboxStatus: .unavailable)
  }

  public func statusJSON(
    sandboxStatus: SandboxBackendStatus
  ) -> JSONValue {
    let environmentMode = environmentAllowlist == nil ? "sanitized" : "allowlist"
    let executableMode = executableAllowlist == nil ? "developerPath" : "allowlist"
    let taskMode = taskAllowlist == nil ? "notRestricted" : "allowlist"
    let sandboxBlockers = profile.requiresSandboxBackend
      ? sandboxStatus.processBlockers(profile, network: network) : []
    return [
      "profile": .string(profile.rawValue),
      "localApproval": .bool(localApproval),
      "workspace": [
        "read": true,
        "write": .bool(workspaceWriteAvailable),
      ],
      "network": network.json,
      "environment": [
        "mode": .string(environmentMode),
        "allowedKeyCount": .int(environmentAllowlist?.count ?? 0),
      ],
      "executables": [
        "mode": .string(executableMode),
        "allowedPathCount": .int(executableAllowlist?.count ?? 0),
      ],
      "tasks": [
        "mode": .string(taskMode),
        "allowedTaskCount": .int(taskAllowlist?.count ?? 0),
      ],
      "rawShell": .bool(
        rawShellAllowed && profile == .fullLocal && localApproval),
      "browserAutomation": .bool(browserAutomationAvailable),
      "desktopControl": .bool(desktopControlAvailable),
      "sandboxRequired": .bool(profile.requiresSandboxBackend),
      "sandboxEnforced": .bool(
        profile.requiresSandboxBackend
          && sandboxStatus.canEnforceProcess(profile, network: network)),
      "sandboxBlockers": .array(sandboxBlockers.map(JSONValue.string)),
      "sandboxBackend": sandboxStatus.json,
      "scope": .string(scopeDescription(sandboxStatus: sandboxStatus)),
    ]
  }

  public var scopeDescription: String {
    scopeDescription(sandboxStatus: .unavailable)
  }

  public func scopeDescription(
    sandboxStatus: SandboxBackendStatus
  ) -> String {
    switch profile {
    case .readOnly:
      "Project reads only; project mutation and local execution are disabled."
    case .workspace, .isolated:
      if sandboxStatus.canEnforceProcess(profile, network: network) {
        "OS-enforced process backend: \(sandboxStatus.identifier)"
      } else {
        "Process execution requires a supported OS-enforced SandboxBackend and is fail-closed."
      }
    case .fullLocal:
      "macOS user privileges; not sandboxed"
    }
  }

  private func requireLocalApproval() throws {
    guard localApproval else {
      throw Failure(
        "local_consent_required",
        "This execution profile was not approved by the local user.",
        "Ask the user to accept the native execution notice before Start; MCP arguments cannot grant this permission.")
    }
  }

  private func denied(_ capability: ExecutionCapability) -> Failure {
    Failure(
      "execution_policy_denied",
      "The active project execution policy denies \(capability.rawValue).",
      "Use capabilities allowed by the current profile, or stop the Runtime and change policy locally.")
  }

  private func sandboxUnavailable(
    _ status: SandboxBackendStatus
  ) -> Failure {
    let missing = status.processBlockers(profile, network: network).joined(separator: ", ")
    return Failure(
      "execution_backend_unavailable",
      "The execution backend cannot enforce this policy. Missing or mismatched guarantees: \(missing).",
      status.reason
        ?? "Keep workspace/isolated execution disabled until the backend enforces the complete project policy. Changing policy requires local approval.")
  }

  private static func validatedEnvironmentKeys(_ keys: Set<String>) throws -> Set<String> {
    guard keys.count <= 64 else {
      throw Failure.invalid("Execution policy environment allowlist is too large.")
    }
    for key in keys where
      key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#, options: .regularExpression) == nil
    {
      throw Failure.invalid("Execution policy contains an invalid environment key.")
    }
    return keys
  }

  private static func validatedExecutablePaths(_ paths: Set<String>) throws -> Set<String> {
    guard paths.count <= 128 else {
      throw Failure.invalid("Execution policy executable allowlist is too large.")
    }
    var result: Set<String> = []
    for path in paths {
      guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
        throw Failure.invalid("Execution policy executable entries must be bounded absolute paths.")
      }
      result.insert(
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
    }
    return result
  }

  private static func validatedTaskIDs(_ ids: Set<String>) throws -> Set<String> {
    guard ids.count <= 256,
      ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") })
    else {
      throw Failure.invalid("Execution policy task allowlist is malformed or too large.")
    }
    return ids
  }
}
