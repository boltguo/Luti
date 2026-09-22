import Foundation

public struct SandboxBackendStatus: Sendable, Equatable {
  public let identifier: String
  public let enforced: Bool
  public let supportedProfiles: Set<ExecutionProfile>
  public let processExecution: Bool
  public let projectFilesystem: Bool
  public let descendantProcesses: Bool
  /// The exact policy installed by this backend, not merely a supported mode.
  /// In particular, unrestricted networking cannot satisfy a deny/allowlist policy.
  public let networkPolicy: ExecutionNetworkPolicy?
  public let reason: String?

  public init(
    identifier: String,
    enforced: Bool,
    supportedProfiles: Set<ExecutionProfile>,
    processExecution: Bool,
    projectFilesystem: Bool = false,
    descendantProcesses: Bool = false,
    networkPolicy: ExecutionNetworkPolicy? = nil,
    reason: String? = nil
  ) {
    self.identifier = identifier
    self.enforced = enforced
    self.supportedProfiles = supportedProfiles
    self.processExecution = processExecution
    self.projectFilesystem = projectFilesystem
    self.descendantProcesses = descendantProcesses
    self.networkPolicy = networkPolicy
    self.reason = reason
  }

  public func canEnforceProcess(
    _ profile: ExecutionProfile,
    network: ExecutionNetworkPolicy
  ) -> Bool {
    processBlockers(profile, network: network).isEmpty
  }

  /// Completeness checks for the backend contract, not proof of OS enforcement.
  /// A real implementation must establish these guarantees before declaring them
  /// and keep them in force through launch, exec and the lifetime of descendants.
  public func processBlockers(
    _ profile: ExecutionProfile,
    network: ExecutionNetworkPolicy
  ) -> [String] {
    var blockers: [String] = []
    if !profile.requiresSandboxBackend || !supportedProfiles.contains(profile) {
      blockers.append("executionProfile")
    }
    if !enforced { blockers.append("osEnforcement") }
    if !processExecution { blockers.append("processExecution") }
    if !projectFilesystem { blockers.append("projectFilesystem") }
    if !descendantProcesses { blockers.append("descendantProcesses") }
    if networkPolicy != network { blockers.append("networkPolicy") }
    return blockers
  }

  public var json: JSONValue {
    [
      "identifier": .string(identifier),
      "enforced": .bool(enforced),
      "processExecution": .bool(processExecution),
      "projectFilesystem": .bool(projectFilesystem),
      "descendantProcesses": .bool(descendantProcesses),
      "networkPolicy": networkPolicy?.json ?? .null,
      "supportedProfiles": .array(
        supportedProfiles.map { JSONValue.string($0.rawValue) }.sorted {
          ($0.string ?? "") < ($1.string ?? "")
        }),
      "reason": reason.map(JSONValue.string) ?? .null,
    ]
  }

  public static let unavailable = SandboxBackendStatus(
    identifier: "unsupported",
    enforced: false,
    supportedProfiles: [],
    processExecution: false,
    reason:
      "No supported macOS OS-enforced backend is connected. workspace/isolated execution remains fail-closed."
  )
}

/// OS-enforced execution backend boundary.
///
/// A backend that claims `enforced=true` must submit the process through the
/// actual enforcement mechanism in `submitProcess`. Its status must describe the
/// project filesystem boundary, descendants and the exact installed network policy;
/// missing declarations fail closed. Status metadata alone is not OS attestation.
/// ToolRouter validates ProcessPolicy before submission and never falls back to
/// JobManager directly for workspace/isolated profiles.
///
/// The backend must independently bind the request's projectRoot/cwd to its local
/// grant and recheck enforcement at launch. It must integrate owned processes with
/// Jobs, reject unsupported terminal modes, and report launch/violation failures
/// without replaying the request or guessing violations from untrusted stdout.
public protocol ProjectSandboxBackend: Sendable {
  var status: SandboxBackendStatus { get }

  func submitProcess(
    _ request: ProcessRequest,
    policy: ProjectExecutionPolicy,
    jobs: JobManager
  ) async throws -> JSONValue
}

/// Shipping default while no supported macOS mechanism satisfies Luti's project
/// filesystem/network boundary together with arbitrary local developer toolchains.
///
/// This backend is intentionally executable only as a refusal path.
public struct UnsupportedProjectSandboxBackend: ProjectSandboxBackend {
  public init() {}

  public let status = SandboxBackendStatus.unavailable

  public func submitProcess(
    _ request: ProcessRequest,
    policy: ProjectExecutionPolicy,
    jobs: JobManager
  ) async throws -> JSONValue {
    throw Failure(
      "execution_backend_unavailable",
      "The selected execution profile requires a supported OS-enforced sandbox backend.",
      "Use readOnly, or explicitly choose fullLocal when macOS user-level execution is acceptable. workspace/isolated never fall back to unsandboxed execution."
    )
  }
}
