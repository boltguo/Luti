import Foundation

public enum ExecutionProfile: String, Sendable {
  case readOnly, fullLocal
}

public enum ExecutionCapability: String, Sendable {
  case workspaceWrite, process, rawShell, codeIntelligence, browserAutomation
}

public struct PendingOperationApproval: Sendable, Identifiable, Equatable {
  public let id: UUID
  public let tool: String
  public let summary: String
  public let code: String
  public let reason: String
  public let projectName: String
  public let projectPath: String
  public let createdAt: Date
  public let expiresAt: Date
}

/// In-memory, one-shot approval for an exact high-risk local action.
///
/// It is deliberately separate from connection authorization. A connected AI may
/// use process tools while a destructive or opaque operation in safe mode still
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
    requirement: ProcessApprovalRequirement,
    project: ApprovedProject
  ) async throws -> PendingOperationApproval {
    guard !stopped else { throw Failure.stopped }
    let now = Date()
    let request = PendingOperationApproval(
      id: UUID(),
      tool: Budget.prefix(tool, bytes: 32),
      summary: Budget.prefix(summary, bytes: 768),
      code: requirement.code,
      reason: Budget.prefix(requirement.reason, bytes: 512),
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
        "Nothing was executed. Do not retry the same operation unless the user asks for it.")
    case .expired:
      throw Failure(
        "local_action_approval_expired",
        "The local approval request expired before execution.",
        "Nothing was executed. Retry only if the user still wants the operation.")
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

/// Immutable authority captured for one Runtime. File and process scope checks
/// remain independent of this capability gate.
public struct ProjectExecutionPolicy: Sendable, Equatable {
  public let profile: ExecutionProfile
  public let localApproval: Bool

  public static let readOnly = ProjectExecutionPolicy(profile: .readOnly, localApproval: false)

  public static func fullLocal(localApproval: Bool) -> ProjectExecutionPolicy {
    ProjectExecutionPolicy(profile: .fullLocal, localApproval: localApproval)
  }

  public var workspaceWriteAvailable: Bool { profile == .fullLocal && localApproval }
  public var commandExecutionAvailable: Bool { workspaceWriteAvailable }
  public var browserAutomationAvailable: Bool { workspaceWriteAvailable }

  public func authorize(_ capability: ExecutionCapability) throws {
    guard profile == .fullLocal else {
      throw Failure("execution_policy_denied", "This runtime does not enable \(capability.rawValue).",
                    "Start Luti locally to enable execution in the selected folder.")
    }
    guard localApproval else {
      throw Failure("local_consent_required", "Local execution has not been enabled for this runtime.",
                    "Start Luti locally; MCP arguments cannot enable execution.")
    }
  }

  public func userEnvironment(_ value: JSONValue) throws -> [String: String] {
    try authorize(.process)
    return try ProcessPolicy.userEnvironment(value)
  }

  public var scopeDescription: String {
    profile == .fullLocal ? "Current user privileges; not sandboxed"
      : "Project reads only; project mutation and local execution are disabled."
  }

  public var statusJSON: JSONValue {
    [
      "profile": .string(profile.rawValue),
      "localApproval": .bool(localApproval),
      "workspace": ["read": true, "write": .bool(workspaceWriteAvailable)],
      "network": ["mode": .string(commandExecutionAvailable ? "unrestricted" : "none")],
      "environment": ["mode": "sanitized"],
      "rawShell": .bool(commandExecutionAvailable),
      "browserAutomation": .bool(browserAutomationAvailable),
      "scope": .string(scopeDescription),
    ]
  }
}
