import Foundation

public enum ExecutionProfile: String, Sendable {
  case readOnly, fullLocal
}

public enum ExecutionCapability: String, Sendable {
  case workspaceWrite, process, rawShell, codeIntelligence, browserAutomation
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
