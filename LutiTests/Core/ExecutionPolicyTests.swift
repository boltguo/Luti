import XCTest
import Darwin

@testable import Luti

private actor SandboxSubmissionProbe {
  private var programs: [String] = []

  func record(_ request: ProcessRequest) {
    programs.append(request.program)
  }

  func snapshot() -> [String] { programs }
}

/// A submission spy only: these tests verify routing, never actual OS isolation.
private struct TestEnforcedSandboxBackend: ProjectSandboxBackend {
  let probe: SandboxSubmissionProbe
  let status: SandboxBackendStatus
  let submissionFailure: Failure?
  let failureResult: JSONValue?

  init(
    probe: SandboxSubmissionProbe,
    status: SandboxBackendStatus = TestEnforcedSandboxBackend.declaredStatus(),
    submissionFailure: Failure? = nil,
    failureResult: JSONValue? = nil
  ) {
    self.probe = probe
    self.status = status
    self.submissionFailure = submissionFailure
    self.failureResult = failureResult
  }

  static func declaredStatus(
    enforced: Bool = true,
    profiles: Set<ExecutionProfile> = [.workspace, .isolated],
    processExecution: Bool = true,
    projectFilesystem: Bool = true,
    descendants: Bool = true,
    network: ExecutionNetworkPolicy? = .some(.none)
  ) -> SandboxBackendStatus {
    SandboxBackendStatus(
      identifier: "test-enforced-backend",
      enforced: enforced,
      supportedProfiles: profiles,
      processExecution: processExecution,
      projectFilesystem: projectFilesystem,
      descendantProcesses: descendants,
      networkPolicy: network)
  }

  func submitProcess(
    _ request: ProcessRequest,
    policy: ProjectExecutionPolicy,
    jobs: JobManager
  ) async throws -> JSONValue {
    await probe.record(request)
    if let submissionFailure { throw submissionFailure }
    if let failureResult { return failureResult }
    return [
      "jobId": "sandbox_test",
      "status": "completed",
      "terminal": true,
      "exitCode": 0,
      "durationSeconds": .number(0),
      "sandboxBackend": .string(status.identifier),
    ]
  }
}

@MainActor final class ExecutionPolicyTests: XCTestCase {
  private func sandboxRouter(
    _ fixture: Fixture,
    policy: ProjectExecutionPolicy,
    backend: TestEnforcedSandboxBackend
  ) throws -> (ToolRouter, JobManager) {
    let jobs = JobManager(helper: Fixture.helper)
    let router = try ToolRouter(
      workspace: fixture.files, jobs: jobs, images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: policy, sandboxBackend: backend,
      contextDataRoot: fixture.contextDataRoot)
    addTeardownBlock { await router.stop() }
    return (router, jobs)
  }

  func testReadOnlyPolicyAllowsProjectReadsButBlocksMutationAndExecution() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "hello")
    let router = try f.router()
    addTeardownBlock { await router.stop() }

    let read = await router.callInCurrentProject("read_files", arguments: ["paths": ["source.txt"]])
    XCTAssertFalse(read.isError)
    XCTAssertEqual(read.data["files"].array?.first?["content"], "hello")

    let create = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "new.txt", "content": "blocked"])
    XCTAssertTrue(create.isError)
    XCTAssertEqual(create.data["error"], "execution_policy_denied")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))

    let directory = await router.callInCurrentProject(
      "path_action", arguments: ["action": "createDirectory", "path": "blocked"])
    XCTAssertTrue(directory.isError)
    XCTAssertEqual(directory.data["error"], "execution_policy_denied")

    let process = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertTrue(process.isError)
    XCTAssertEqual(process.data["error"], "execution_policy_denied")

    let code = await router.callInCurrentProject(
      "code_query", arguments: ["action": "documentSymbols", "path": "source.txt"])
    XCTAssertTrue(code.isError)
    XCTAssertEqual(code.data["error"], "execution_policy_denied")

    let browser = await router.callInCurrentProject(
      "browser_session", arguments: ["action": "open", "url": "https://example.com"])
    XCTAssertTrue(browser.isError)
    XCTAssertEqual(browser.data["error"], "execution_policy_denied")

    let desktop = await router.callInCurrentProject("computer_observe", arguments: [:])
    XCTAssertTrue(desktop.isError)
    XCTAssertEqual(desktop.data["error"], "execution_policy_denied")
  }

  func testFullLocalPolicyStillRequiresNativeApproval() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try ToolRouter(
      workspace: f.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: false), contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let process = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertEqual(process.data["error"], "local_consent_required")

    let write = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "new.txt", "content": "blocked"])
    XCTAssertEqual(write.data["error"], "local_consent_required")
  }

  func testApprovedFullLocalPreservesCurrentRuntimeBehavior() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let create = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "created.txt", "content": "ok"])
    XCTAssertFalse(create.isError)

    let process = await router.callInCurrentProject(
      "run_process",
      arguments: ["program": "/usr/bin/true", "syncWait": 3, "timeout": 10])
    XCTAssertFalse(process.isError)
    XCTAssertEqual(process.data["exitCode"], 0)

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["profile"], "fullLocal")
    XCTAssertEqual(status.data["executionPolicy"]["localApproval"], true)
    XCTAssertEqual(status.data["executionPolicy"]["permissionMode"], "fullProjectAccess")
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], false)
    XCTAssertEqual(status.data["capabilities"]["projectWrite"], true)
    XCTAssertEqual(status.data["capabilities"]["commandExecution"], true)
    XCTAssertEqual(status.data["capabilities"]["rawShell"], true)
  }

  func testWorkspaceProfileFailsClosedUntilSandboxBackendExists() async throws {
    let f = try Fixture(); defer { f.remove() }
    let policy = try ProjectExecutionPolicy.workspace(
      localApproval: true, network: .allowlist(["registry.npmjs.org"]))
    let router = try ToolRouter(
      workspace: f.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(), executionPolicy: policy,
      contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let create = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "create", "path": "workspace.txt", "content": "allowed"])
    XCTAssertFalse(create.isError)

    let process = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertTrue(process.isError)
    XCTAssertEqual(process.data["error"], "execution_backend_unavailable")

    let browser = await router.callInCurrentProject(
      "browser_session", arguments: ["action": "open", "url": "https://example.com"])
    XCTAssertTrue(browser.isError)
    XCTAssertEqual(browser.data["error"], "execution_policy_denied")

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["profile"], "workspace")
    XCTAssertEqual(status.data["executionPolicy"]["network"]["mode"], "allowlist")
    XCTAssertEqual(
      status.data["executionPolicy"]["network"]["hosts"].array?.compactMap(\.string),
      ["registry.npmjs.org"])
    XCTAssertEqual(status.data["executionPolicy"]["sandboxRequired"], true)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], false)
    XCTAssertEqual(
      status.data["executionPolicy"]["sandboxBackend"]["identifier"],
      "unsupported")
    XCTAssertEqual(
      status.data["executionPolicy"]["sandboxBackend"]["processExecution"],
      false)
    XCTAssertEqual(status.data["executionEnabled"], false)
  }

  func testWorkspaceProcessMustBeSubmittedByEnforcingBackend() async throws {
    let f = try Fixture(); defer { f.remove() }
    let policy = try ProjectExecutionPolicy.workspace(
      localApproval: true,
      executableAllowlist: ["/usr/bin/true"])
    let jobs = JobManager(helper: Fixture.helper)
    let probe = SandboxSubmissionProbe()
    let backend = TestEnforcedSandboxBackend(probe: probe)
    let router = try ToolRouter(
      workspace: f.files,
      jobs: jobs,
      images: ImageStore(),
      computer: NoComputerBackend(),
      activity: ActivityStore(),
      executionPolicy: policy,
      sandboxBackend: backend,
      contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let result = await router.callInCurrentProject(
      "run_process",
      arguments: [
        "program": "/usr/bin/true",
        "syncWait": 3,
        "timeout": 10,
      ])
    XCTAssertFalse(result.isError)
    XCTAssertEqual(result.data["jobId"], "sandbox_test")
    XCTAssertEqual(result.data["sandboxBackend"], "test-enforced-backend")
    let submittedPrograms = await probe.snapshot()
    XCTAssertEqual(submittedPrograms, ["/usr/bin/true"])

    // The ordinary JobManager must stay empty: workspace execution cannot first
    // pass a boolean gate and then accidentally launch through the unsandboxed path.
    let ordinaryJobs = await jobs.list()
    XCTAssertTrue(ordinaryJobs.isEmpty)

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionEnabled"], true)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], true)
    XCTAssertEqual(
      status.data["executionPolicy"]["sandboxBackend"]["identifier"],
      "test-enforced-backend")

    try f.write("source.swift", "let value = 1")
    let code = await router.callInCurrentProject(
      "code_query",
      arguments: [
        "path": "source.swift",
        "action": "documentSymbols",
      ])
    XCTAssertTrue(code.isError)
    XCTAssertEqual(code.data["error"], "execution_backend_unavailable")

    let shell = await router.callInCurrentProject(
      "run_shell",
      arguments: ["command": "echo should-not-run"])
    XCTAssertTrue(shell.isError)
    XCTAssertEqual(shell.data["error"], "execution_policy_denied")
  }

  func testLegacyBackendDeclarationFailsClosed() throws {
    let status = SandboxBackendStatus(
      identifier: "legacy", enforced: true,
      supportedProfiles: [.workspace, .isolated], processExecution: true)
    XCTAssertEqual(
      status.processBlockers(.workspace, network: .none),
      ["projectFilesystem", "descendantProcesses", "networkPolicy"])
    XCTAssertEqual(status.json["networkPolicy"], .null)
    for policy in [
      try ProjectExecutionPolicy.workspace(localApproval: true),
      try ProjectExecutionPolicy.isolated(localApproval: true),
    ] {
      XCTAssertFalse(policy.commandExecutionAvailable(sandboxStatus: status))
      XCTAssertThrowsError(try policy.authorize(.process, sandboxStatus: status)) { error in
        XCTAssertEqual((error as? Failure)?.code, "execution_backend_unavailable")
      }
    }
  }

  func testEverySandboxGuaranteeIsRequired() throws {
    let cases: [(SandboxBackendStatus, String)] = [
      (TestEnforcedSandboxBackend.declaredStatus(enforced: false), "osEnforcement"),
      (TestEnforcedSandboxBackend.declaredStatus(profiles: []), "executionProfile"),
      (TestEnforcedSandboxBackend.declaredStatus(processExecution: false), "processExecution"),
      (TestEnforcedSandboxBackend.declaredStatus(projectFilesystem: false), "projectFilesystem"),
      (TestEnforcedSandboxBackend.declaredStatus(descendants: false), "descendantProcesses"),
      (TestEnforcedSandboxBackend.declaredStatus(network: nil), "networkPolicy"),
    ]
    for policy in [
      try ProjectExecutionPolicy.workspace(localApproval: true),
      try ProjectExecutionPolicy.isolated(localApproval: true),
    ] {
      for (status, missing) in cases {
        XCTAssertEqual(status.processBlockers(policy.profile, network: .none), [missing])
        XCTAssertFalse(policy.commandExecutionAvailable(sandboxStatus: status), missing)
        let json = policy.statusJSON(sandboxStatus: status)
        XCTAssertEqual(json["sandboxEnforced"], false)
        XCTAssertEqual(json["sandboxBlockers"], .array([.string(missing)]))
        XCTAssertThrowsError(try policy.authorize(.process, sandboxStatus: status)) { error in
          XCTAssertEqual((error as? Failure)?.code, "execution_backend_unavailable")
          XCTAssertTrue((error as? Failure)?.message.contains(missing) == true)
        }
        // File tools have their own descriptor boundary and local consent gate.
        XCTAssertNoThrow(try policy.authorize(.workspaceWrite, sandboxStatus: status))
      }
    }
  }

  func testSandboxNetworkPolicyMustMatchModeAndExactHosts() throws {
    let networks: [ExecutionNetworkPolicy] = [
      .none, .unrestricted, .allowlist([]),
      .allowlist(["registry.npmjs.org"]),
      .allowlist(["registry.npmjs.org", "pypi.org"]),
      .allowlist(["other.example"]),
    ]
    for expected in networks {
      for policy in [
        try ProjectExecutionPolicy.workspace(localApproval: true, network: expected),
        try ProjectExecutionPolicy.isolated(localApproval: true, network: expected),
      ] {
        for installed in networks {
          let status = TestEnforcedSandboxBackend.declaredStatus(network: installed)
          let matches = expected == installed
          XCTAssertEqual(policy.commandExecutionAvailable(sandboxStatus: status), matches)
          XCTAssertEqual(policy.statusJSON(sandboxStatus: status)["sandboxEnforced"], .bool(matches))
          if matches {
            XCTAssertNoThrow(try policy.authorize(.process, sandboxStatus: status))
          } else {
            XCTAssertEqual(status.processBlockers(policy.profile, network: expected), ["networkPolicy"])
            XCTAssertThrowsError(try policy.authorize(.process, sandboxStatus: status))
          }
        }
      }
    }
    let status = TestEnforcedSandboxBackend.declaredStatus(
      network: .allowlist(["pypi.org", "registry.npmjs.org"]))
    XCTAssertTrue(status.canEnforceProcess(
      .workspace, network: .allowlist(["registry.npmjs.org", "pypi.org"])))
    XCTAssertEqual(
      status.json["networkPolicy"]["hosts"], ["pypi.org", "registry.npmjs.org"])
    XCTAssertEqual(ExecutionNetworkPolicy.none.json, ["mode": "none"])
  }

  func testSandboxProfileClaimsCannotUpgradeOtherProfiles() throws {
    let status = TestEnforcedSandboxBackend.declaredStatus(
      profiles: Set(ExecutionProfile.allCases))
    XCTAssertFalse(status.canEnforceProcess(.readOnly, network: .none))
    XCTAssertFalse(status.canEnforceProcess(.fullLocal, network: .none))
    XCTAssertEqual(ProjectExecutionPolicy.readOnly.statusJSON(sandboxStatus: status)["sandboxEnforced"], false)
    let fullLocal = ProjectExecutionPolicy.fullLocal(localApproval: true)
    XCTAssertEqual(fullLocal.statusJSON(sandboxStatus: status)["sandboxEnforced"], false)
    XCTAssertEqual(fullLocal.statusJSON(sandboxStatus: status)["sandboxBlockers"], [])
    let workspaceOnly = TestEnforcedSandboxBackend.declaredStatus(profiles: [.workspace])
    let isolated = try ProjectExecutionPolicy.isolated(localApproval: true)
    XCTAssertThrowsError(try isolated.authorize(.process, sandboxStatus: workspaceOnly))
  }

  func testCompleteSandboxStillRequiresLocalConsentAndCapabilityRouting() throws {
    let status = TestEnforcedSandboxBackend.declaredStatus()
    for approved in [false, true] {
      for policy in [
        try ProjectExecutionPolicy.workspace(localApproval: approved),
        try ProjectExecutionPolicy.isolated(localApproval: approved),
      ] {
        XCTAssertEqual(policy.commandExecutionAvailable(sandboxStatus: status), approved)
        if !approved {
          for capability: ExecutionCapability in [.process, .workspaceWrite, .codeIntelligence] {
            XCTAssertThrowsError(try policy.authorize(capability, sandboxStatus: status)) { error in
              XCTAssertEqual((error as? Failure)?.code, "local_consent_required")
            }
          }
        } else {
          XCTAssertNoThrow(try policy.authorize(.process, sandboxStatus: status))
          XCTAssertThrowsError(try policy.authorize(.codeIntelligence, sandboxStatus: status)) { error in
            XCTAssertEqual((error as? Failure)?.code, "execution_backend_unavailable")
          }
        }
        for capability: ExecutionCapability in [.rawShell, .browserAutomation, .desktopControl] {
          XCTAssertThrowsError(try policy.authorize(capability, sandboxStatus: status)) { error in
            XCTAssertEqual((error as? Failure)?.code, "execution_policy_denied")
          }
        }
      }
    }
  }

  func testNetworkMismatchRejectsBeforeSubmissionAndMatchesRuntimeStatus() async throws {
    let f = try Fixture(); defer { f.remove() }
    let probe = SandboxSubmissionProbe()
    let policy = try ProjectExecutionPolicy.workspace(
      localApproval: true, network: .allowlist(["registry.npmjs.org"]),
      executableAllowlist: ["/usr/bin/true"])
    let backend = TestEnforcedSandboxBackend(
      probe: probe, status: TestEnforcedSandboxBackend.declaredStatus(network: .unrestricted))
    let (router, jobs) = try sandboxRouter(f, policy: policy, backend: backend)
    let result = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "execution_backend_unavailable")
    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionEnabled"], false)
    XCTAssertEqual(status.data["capabilities"]["commandExecution"], false)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxBlockers"], ["networkPolicy"])
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], false)
    let submitted = await probe.snapshot()
    let ordinary = await jobs.list()
    XCTAssertTrue(submitted.isEmpty)
    XCTAssertTrue(ordinary.isEmpty)
  }

  func testSandboxSubmissionStillRunsSharedProcessValidation() async throws {
    let f = try Fixture(); defer { f.remove() }
    let probe = SandboxSubmissionProbe()
    // Approval of an executable never overrides the low-level safety checks.
    let policy = try ProjectExecutionPolicy.workspace(
      localApproval: true, executableAllowlist: ["/usr/bin/true", "/usr/bin/sudo"])
    let (router, jobs) = try sandboxRouter(
      f, policy: policy, backend: TestEnforcedSandboxBackend(probe: probe))
    let requests: [(JSONValue, String)] = [
      (["program": "/usr/bin/true", "terminalMode": "pty"], "invalid_arguments"),
      (["program": "/usr/bin/true", "terminalMode": "unknown"], "invalid_arguments"),
      (["program": "/usr/bin/true", "stdin": "contains\0nul"], "invalid_arguments"),
      (["program": "/usr/bin/true", "args": .array(
        Array(repeating: .string(String(repeating: "x", count: 8192)), count: 9))], "invalid_arguments"),
      (["program": "/usr/bin/sudo", "args": ["-V"]], "dangerous_command_denied"),
    ]
    for (arguments, code) in requests {
      let result = await router.callInCurrentProject("run_process", arguments: arguments)
      XCTAssertTrue(result.isError)
      XCTAssertEqual(result.data["error"], .string(code))
    }
    let submitted = await probe.snapshot()
    let ordinary = await jobs.list()
    XCTAssertTrue(submitted.isEmpty, "Malformed requests must not reach an enforcing backend.")
    XCTAssertTrue(ordinary.isEmpty)
  }

  func testBackendUnknownOutcomeIsReturnedOnceWithoutFallback() async throws {
    let f = try Fixture(); defer { f.remove() }
    let probe = SandboxSubmissionProbe()
    let policy = try ProjectExecutionPolicy.workspace(
      localApproval: true, executableAllowlist: ["/usr/bin/touch"])
    let failure = Failure(
      "sandbox_transport_unknown", "Submission outcome is unknown.",
      "Observe the owned job before deciding whether another action is safe.", effect: "unknown")
    let (router, jobs) = try sandboxRouter(
      f, policy: policy,
      backend: TestEnforcedSandboxBackend(probe: probe, submissionFailure: failure))
    let result = await router.callInCurrentProject(
      "run_process", arguments: ["program": "/usr/bin/touch", "args": ["must-not-exist"]])
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "sandbox_transport_unknown")
    XCTAssertEqual(result.data["effect"], "unknown")
    let submitted = await probe.snapshot()
    let ordinary = await jobs.list()
    XCTAssertEqual(submitted, ["/usr/bin/touch"])
    XCTAssertTrue(ordinary.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-exist").path))
  }

  func testStructuredBackendFailureDoesNotBecomeSuccessOrRetry() async throws {
    let f = try Fixture(); defer { f.remove() }
    let probe = SandboxSubmissionProbe()
    let policy = try ProjectExecutionPolicy.isolated(
      localApproval: true, executableAllowlist: ["/usr/bin/true"])
    let failure: JSONValue = [
      "jobId": "sandbox_failed", "status": "failed", "terminal": true,
      "failure": ["error": "sandbox_network_denied", "effect": "none"],
    ]
    let (router, jobs) = try sandboxRouter(
      f, policy: policy,
      backend: TestEnforcedSandboxBackend(probe: probe, failureResult: failure))
    let result = await router.callInCurrentProject("run_process", arguments: ["program": "/usr/bin/true"])
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["failure"]["error"], "sandbox_network_denied")
    let submitted = await probe.snapshot()
    let ordinary = await jobs.list()
    XCTAssertEqual(submitted, ["/usr/bin/true"])
    XCTAssertTrue(ordinary.isEmpty)
  }

  func testUnsupportedBackendCannotLaunchEvenWhenCalledDirectly() async throws {
    let f = try Fixture(); defer { f.remove() }
    let jobs = JobManager(helper: Fixture.helper)
    let backend = UnsupportedProjectSandboxBackend()
    do {
      _ = try await backend.submitProcess(
        ProcessRequest(program: "/usr/bin/true", cwd: f.root, projectRoot: f.root),
        policy: .fullLocal(localApproval: true), jobs: jobs)
      XCTFail("The unavailable backend must always refuse submission.")
    } catch {
      XCTAssertEqual((error as? Failure)?.code, "execution_backend_unavailable")
    }
    let ordinary = await jobs.list()
    XCTAssertTrue(ordinary.isEmpty)
    XCTAssertEqual(backend.status.json["enforced"], false)
  }

  func testProcessScopeAndAskSensitivityAreSeparate() throws {
    let f = try Fixture(); defer { f.remove() }
    let inside = f.root.appendingPathComponent("build/output.txt").path
    let outside = f.root.deletingLastPathComponent()
      .appendingPathComponent("luti-outside-" + UUID().uuidString).path

    let ordinary = ProcessRequest(
      program: "/bin/echo", args: ["src/main.swift"], cwd: f.root, projectRoot: f.root)
    XCTAssertNoThrow(try ProcessPolicy.validateProjectScope(ordinary))
    XCTAssertNil(ProcessPolicy.approvalRequirement(ordinary))

    let insideAbsolute = ProcessRequest(
      program: "/usr/bin/touch", args: [inside], cwd: f.root, projectRoot: f.root)
    XCTAssertNoThrow(try ProcessPolicy.validateProjectScope(insideAbsolute))
    XCTAssertNil(ProcessPolicy.approvalRequirement(insideAbsolute))

    let external = ProcessRequest(
      program: "/usr/bin/touch", args: [outside], cwd: f.root, projectRoot: f.root)
    XCTAssertThrowsError(try ProcessPolicy.validateProjectScope(external)) { error in
      XCTAssertEqual((error as? Failure)?.code, "project_scope_denied")
    }

    let escape = f.root.appendingPathComponent("escape")
    try FileManager.default.createSymbolicLink(
      at: escape, withDestinationURL: f.root.deletingLastPathComponent())
    let symlinkEscape = ProcessRequest(
      program: "/usr/bin/touch", args: ["escape/new.txt"], cwd: f.root, projectRoot: f.root)
    XCTAssertThrowsError(try ProcessPolicy.validateProjectScope(symlinkEscape)) { error in
      XCTAssertEqual((error as? Failure)?.code, "project_scope_denied")
    }

    XCTAssertEqual(
      ProcessPolicy.approvalRequirement(
        ProcessRequest(
          program: "/bin/rm", args: ["generated.txt"], cwd: f.root, projectRoot: f.root))?.code,
      "destructive_command")
    XCTAssertEqual(
      ProcessPolicy.approvalRequirement(
        ProcessRequest(
          program: "/bin/sh", args: ["-c", "echo ok"], cwd: f.root, projectRoot: f.root))?.code,
      "opaque_shell")
    XCTAssertEqual(
      ProcessPolicy.approvalRequirement(
        ProcessRequest(
          program: "/usr/bin/python3", args: ["-c", "print('ok')"],
          cwd: f.root, projectRoot: f.root))?.code,
      "inline_code")
  }

  func testExternalPathIsDeniedInAskAndFullWithoutApprovalEscape() async throws {
    for mode in [ProjectPermissionMode.ask, .fullProjectAccess] {
      let f = try Fixture()
      let approvals = OperationApprovalBroker()
      let router = try f.router(
        execution: true, permissionMode: mode, operationApprovals: approvals)
      let target = f.root.deletingLastPathComponent()
        .appendingPathComponent("luti-scope-denied-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: target); f.remove() }

      let result = await router.callInCurrentProject(
        "run_process",
        arguments: [
          "program": "/usr/bin/touch",
          "args": .array([.string(target.path)]),
          "syncWait": 3,
        ])
      XCTAssertTrue(result.isError)
      XCTAssertEqual(result.data["error"], "project_scope_denied", mode.rawValue)
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      let pendingApprovals = await approvals.pendingApprovals()
      XCTAssertTrue(pendingApprovals.isEmpty)
      await router.stop()
    }
  }

  func testAskApprovesSensitiveProjectOperationButFullDoesNotAsk() async throws {
    let askFixture = try Fixture(); defer { askFixture.remove() }
    let askApprovals = OperationApprovalBroker()
    let askRouter = try askFixture.router(
      execution: true, permissionMode: .ask, operationApprovals: askApprovals)
    addTeardownBlock { await askRouter.stop() }

    let askCall = Task {
      await askRouter.callInCurrentProject(
        "run_shell",
        arguments: ["command": "printf ask > permission-mode.txt", "syncWait": 3])
    }
    var pending: PendingOperationApproval?
    for _ in 0..<100 where pending == nil {
      pending = await askApprovals.pendingApprovals().first
      if pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let approval = try XCTUnwrap(pending)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: askFixture.root.appendingPathComponent("permission-mode.txt").path))
    await askApprovals.resolve(approval.id, approved: true)
    let askResult = await askCall.value
    XCTAssertFalse(askResult.isError)
    XCTAssertEqual(askResult.data["localApproval"]["scope"], "oneShot")
    XCTAssertEqual(
      try String(contentsOf: askFixture.root.appendingPathComponent("permission-mode.txt"), encoding: .utf8),
      "ask")

    let fullFixture = try Fixture(); defer { fullFixture.remove() }
    let fullApprovals = OperationApprovalBroker()
    let fullRouter = try fullFixture.router(
      execution: true, permissionMode: .fullProjectAccess, operationApprovals: fullApprovals)
    addTeardownBlock { await fullRouter.stop() }
    let fullResult = await fullRouter.callInCurrentProject(
      "run_shell",
      arguments: ["command": "printf full > permission-mode.txt", "syncWait": 3])
    XCTAssertFalse(fullResult.isError)
    XCTAssertEqual(fullResult.data["localApproval"], .null)
    let fullPendingApprovals = await fullApprovals.pendingApprovals()
    XCTAssertTrue(fullPendingApprovals.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: fullFixture.root.appendingPathComponent("permission-mode.txt"), encoding: .utf8),
      "full")
  }

  func testExternalFileToolsStayDeniedWithoutApprovalEscape() async throws {
    let f = try Fixture(); defer { f.remove() }
    let approvals = OperationApprovalBroker()
    let router = try f.router(execution: true, operationApprovals: approvals)
    addTeardownBlock { await router.stop() }

    let read = await router.callInCurrentProject("read_files", arguments: ["paths": ["../outside.txt"]])
    XCTAssertTrue(read.isError)
    XCTAssertEqual(
      read.data["files"].array?.first?["failure"]["error"],
      "path_outside_workspace")

    let edit = await router.callInCurrentProject(
      "edit_files",
      arguments: [
        "action": "create",
        "path": "../outside.txt",
        "content": "blocked",
      ])
    XCTAssertTrue(edit.isError)
    XCTAssertEqual(edit.data["error"], "path_outside_workspace")
    let pending = await approvals.pendingApprovals()
    XCTAssertTrue(pending.isEmpty)
  }

  func testBrowserAndComputerRemainIndependentOfProjectPermissionMode() throws {
    let policy = ProjectExecutionPolicy.fullLocal(localApproval: true)
    XCTAssertNoThrow(try policy.authorize(.browserAutomation))
    XCTAssertNoThrow(try policy.authorize(.desktopControl))
  }

  func testDiscoveredNodeTaskRespectsScopeAndPermissionMode() async throws {
    let outsideFixture = try Fixture(); defer { outsideFixture.remove() }
    try outsideFixture.write(
      "package.json", #"{"scripts":{"test":"rm ../must-not-be-removed"}}"#)
    for mode in [ProjectPermissionMode.ask, .fullProjectAccess] {
      let approvals = OperationApprovalBroker()
      let project = ApprovedProject(url: outsideFixture.root, permissionMode: mode)
      let router = try ToolRouter(
        workspace: try WorkspaceFiles(root: outsideFixture.root),
        jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
        computer: NoComputerBackend(), activity: ActivityStore(),
        executionPolicy: .fullLocal(localApproval: true),
        operationApprovals: approvals,
        approvedProjects: [project], activeProjectID: project.id,
        contextDataRoot: outsideFixture.contextDataRoot)
      let result = await router.callInCurrentProject(
        "run_process", arguments: ["taskId": "task:test", "syncWait": 3])
      XCTAssertEqual(result.data["error"], "project_scope_denied", mode.rawValue)
      let pendingApprovals = await approvals.pendingApprovals()
      XCTAssertTrue(pendingApprovals.isEmpty)
      await router.stop()
    }

    let askFixture = try Fixture(); defer { askFixture.remove() }
    try askFixture.write("generated.txt", "remove me")
    try askFixture.write("package.json", #"{"scripts":{"test":"rm generated.txt"}}"#)
    let askApprovals = OperationApprovalBroker()
    let askRouter = try askFixture.router(
      execution: true, permissionMode: .ask, operationApprovals: askApprovals)
    addTeardownBlock { await askRouter.stop() }
    let askCall = Task {
      await askRouter.callInCurrentProject("run_process", arguments: ["taskId": "task:test", "syncWait": 3])
    }
    var pending: PendingOperationApproval?
    for _ in 0..<100 where pending == nil {
      pending = await askApprovals.pendingApprovals().first
      if pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let askApproval = try XCTUnwrap(pending)
    await askApprovals.resolve(askApproval.id, approved: false)
    let askResult = await askCall.value
    XCTAssertEqual(askResult.data["error"], "local_action_denied")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: askFixture.root.appendingPathComponent("generated.txt").path))

    let fullFixture = try Fixture(); defer { fullFixture.remove() }
    try fullFixture.write("generated.txt", "remove me")
    try fullFixture.write("package.json", #"{"scripts":{"test":"rm generated.txt"}}"#)
    let fullApprovals = OperationApprovalBroker()
    let fullRouter = try fullFixture.router(
      execution: true, permissionMode: .fullProjectAccess, operationApprovals: fullApprovals)
    addTeardownBlock { await fullRouter.stop() }
    let fullResult = await fullRouter.callInCurrentProject(
      "run_process", arguments: ["taskId": "task:test", "syncWait": 3])
    XCTAssertFalse(fullResult.isError)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fullFixture.root.appendingPathComponent("generated.txt").path))
    let fullPendingApprovals = await fullApprovals.pendingApprovals()
    XCTAssertTrue(fullPendingApprovals.isEmpty)
  }

  func testProjectSwitchUsesTargetProjectsPersistedPermissionMode() async throws {
    let askFixture = try Fixture(); defer { askFixture.remove() }
    let fullFixture = try Fixture(); defer { fullFixture.remove() }
    let askProject = ApprovedProject(url: askFixture.root, permissionMode: .ask)
    let fullProject = ApprovedProject(url: fullFixture.root, permissionMode: .fullProjectAccess)
    let approvals = OperationApprovalBroker()
    let router = try ToolRouter(
      workspace: askFixture.files,
      jobs: JobManager(helper: Fixture.helper),
      images: ImageStore(),
      computer: NoComputerBackend(),
      activity: ActivityStore(),
      executionPolicy: .fullLocal(localApproval: true),
      operationApprovals: approvals,
      approvedProjects: [askProject, fullProject],
      activeProjectID: askProject.id,
      contextDataRoot: askFixture.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let askCall = Task {
      await router.callInCurrentProject(
        "run_shell",
        arguments: ["command": "printf ask > ask.txt", "syncWait": 3])
    }
    var pending: PendingOperationApproval?
    for _ in 0..<100 where pending == nil {
      pending = await approvals.pendingApprovals().first
      if pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let firstApproval = try XCTUnwrap(pending)
    await approvals.resolve(firstApproval.id, approved: false)
    let firstResult = await askCall.value
    XCTAssertEqual(firstResult.data["error"], "local_action_denied")

    let switched = await router.callInCurrentProject(
      "projects", arguments: ["action": "switch", "projectId": .string(fullProject.id)])
    XCTAssertFalse(switched.isError)
    XCTAssertEqual(switched.data["project"]["permissionMode"], "fullProjectAccess")

    let fullResult = await router.callInCurrentProject(
      "run_shell",
      arguments: ["command": "printf full > switched.txt", "syncWait": 3])
    XCTAssertFalse(fullResult.isError)
    XCTAssertEqual(fullResult.data["localApproval"], .null)
    XCTAssertEqual(
      try String(contentsOf: fullFixture.root.appendingPathComponent("switched.txt"), encoding: .utf8),
      "full")
    let noPending = await approvals.pendingApprovals()
    XCTAssertTrue(noPending.isEmpty)

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["activeProject"]["permissionMode"], "fullProjectAccess")
    XCTAssertEqual(status.data["executionPolicy"]["permissionMode"], "fullProjectAccess")

    let switchedBack = await router.callInCurrentProject(
      "projects", arguments: ["action": "switch", "projectId": .string(askProject.id)])
    XCTAssertFalse(switchedBack.isError)
    let askAgain = Task {
      await router.callInCurrentProject(
        "run_shell",
        arguments: ["command": "printf ask-again > ask-again.txt", "syncWait": 3])
    }
    pending = nil
    for _ in 0..<100 where pending == nil {
      pending = await approvals.pendingApprovals().first
      if pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    let secondApproval = try XCTUnwrap(pending)
    await approvals.resolve(secondApproval.id, approved: false)
    let secondResult = await askAgain.value
    XCTAssertEqual(secondResult.data["error"], "local_action_denied")
  }

  func testMachineLevelHardDenyAppliesInAskAndFull() async throws {
    for mode in [ProjectPermissionMode.ask, .fullProjectAccess] {
      let f = try Fixture()
      let approvals = OperationApprovalBroker()
      let router = try f.router(
        execution: true, permissionMode: mode, operationApprovals: approvals)
      let result = await router.callInCurrentProject(
        "run_process", arguments: ["program": "/usr/bin/sudo", "args": ["-V"]])
      XCTAssertEqual(result.data["error"], "dangerous_command_denied", mode.rawValue)
      let pending = await approvals.pendingApprovals()
      XCTAssertTrue(pending.isEmpty)
      await router.stop()
      f.remove()
    }
  }

  func testRestrictedPolicyNarrowsEnvironmentExecutablesTasksAndShell() throws {
    let policy = try ProjectExecutionPolicy.restrictedFullLocal(
      localApproval: true,
      environmentAllowlist: ["CI"],
      executableAllowlist: ["/usr/bin/true"],
      taskAllowlist: ["task:test"],
      rawShellAllowed: false)

    XCTAssertEqual(try policy.userEnvironment(["CI": "1"]), ["CI": "1"])
    XCTAssertThrowsError(try policy.userEnvironment(["NODE_ENV": "test"])) { error in
      XCTAssertEqual((error as? Failure)?.code, "environment_not_allowed")
    }

    XCTAssertNoThrow(
      try policy.validateExecutable(
        program: "/usr/bin/true", cwd: URL(fileURLWithPath: "/tmp"), environment: [:]))
    XCTAssertThrowsError(
      try policy.validateExecutable(
        program: "/bin/echo", cwd: URL(fileURLWithPath: "/tmp"), environment: [:])
    ) { error in
      XCTAssertEqual((error as? Failure)?.code, "executable_not_allowed")
    }

    XCTAssertNoThrow(try policy.authorizeTask("task:test"))
    XCTAssertThrowsError(try policy.authorizeTask("task:dev")) { error in
      XCTAssertEqual((error as? Failure)?.code, "task_not_allowed")
    }
    XCTAssertThrowsError(try policy.authorize(.rawShell)) { error in
      XCTAssertEqual((error as? Failure)?.code, "execution_policy_denied")
    }
  }

  func testRestrictedPolicyTaskAllowlistIsAppliedToDiscoveredTasks() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write(
      "package.json",
      #"{"scripts":{"test":"/usr/bin/true","dev":"/usr/bin/true"}}"#)
    let npm = try ProcessPolicy.resolve(
      "npm", cwd: f.root, environment: ProcessPolicy.baseEnvironment)
    let policy = try ProjectExecutionPolicy.restrictedFullLocal(
      localApproval: true,
      environmentAllowlist: [],
      executableAllowlist: [npm.path],
      taskAllowlist: ["task:test"],
      rawShellAllowed: false)
    let router = try ToolRouter(
      workspace: f.files, jobs: JobManager(helper: Fixture.helper), images: ImageStore(),
      computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: policy, contextDataRoot: f.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let allowed = await router.callInCurrentProject(
      "run_process",
      arguments: ["taskId": "task:test", "syncWait": 3, "timeout": 20])
    XCTAssertFalse(allowed.isError)
    XCTAssertEqual(allowed.data["task"]["id"], "task:test")

    let denied = await router.callInCurrentProject(
      "run_process", arguments: ["taskId": "task:dev"])
    XCTAssertTrue(denied.isError)
    XCTAssertEqual(denied.data["error"], "task_not_allowed")
  }

  func testReadOnlyRuntimeStatusDoesNotClaimSandboxOrExecution() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }

    let status = await router.callInCurrentProject("runtime_status", arguments: [:])
    XCTAssertEqual(status.data["executionPolicy"]["profile"], "readOnly")
    XCTAssertEqual(status.data["executionPolicy"]["workspace"]["read"], true)
    XCTAssertEqual(status.data["executionPolicy"]["workspace"]["write"], false)
    XCTAssertEqual(status.data["executionPolicy"]["sandboxEnforced"], false)
    XCTAssertEqual(status.data["executionEnabled"], false)
    XCTAssertEqual(status.data["capabilities"]["commandExecution"], false)
  }

  func testUnsupportedDiagnosticsNeverStartsProjectLanguageServer() async throws {
    let f = try Fixture(); defer { f.remove() }
    let serverPath = "node_modules/.bin/typescript-language-server"
    try f.write(serverPath, "#!/bin/sh\n: > language-server-started\nexit 0\n")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: f.root.appendingPathComponent(serverPath).path)
    try f.write("source.ts", "export const value = 1\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let result = await router.callInCurrentProject(
      "code_query", arguments: ["action": "diagnostics", "path": "source.ts"])

    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "language_service_action_unavailable")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("language-server-started").path))
    let events = await router.activity.snapshot()
    XCTAssertEqual(events.last?.effect, "none")
  }

  private func installBlockedLanguageServer(_ fixture: Fixture) throws {
    let path = "node_modules/.bin/typescript-language-server"
    // A functioning initialize handshake followed by a full stdin pipe. Both
    // provider and descendant ignore TERM to exercise supervisor escalation.
    try fixture.write(path, #"""
    #!/usr/bin/python3
    import json, os, pathlib, signal, sys, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if line in (b"\r\n", b"\n"):
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    request = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    child = os.fork()
    if child == 0:
        while True:
            time.sleep(1)
    response = json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"capabilities":{}}}).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(response)).encode() + b"\r\n\r\n" + response)
    sys.stdout.buffer.flush()
    pathlib.Path("language-server-ready").write_text(str(os.getpid()) + " " + str(child))
    while True:
        time.sleep(1)
    """#)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
      ofItemAtPath: fixture.root.appendingPathComponent(path).path)
    try fixture.write("source.ts", String(repeating: "x", count: 600_000))
  }

  private func languageServerPIDs(_ fixture: Fixture) async throws -> [pid_t] {
    let marker = fixture.root.appendingPathComponent("language-server-ready")
    // The first Python launch on a fresh CI runner can take longer than three seconds.
    for _ in 0..<500 {
      if let text = try? String(contentsOf: marker, encoding: .utf8) {
        let pids = text.split(separator: " ").compactMap { Int32($0) }
        if pids.count == 2 { return pids }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Language server did not finish its initialize handshake.")
    return []
  }

  private func assertLanguageServerStopped(_ pids: [pid_t]) async throws {
    // A descendant may briefly remain a zombie until launchd reaps it.
    for _ in 0..<100 {
      if pids.allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    for pid in pids {
      XCTAssertEqual(kill(pid, 0), -1, "Language-service process \(pid) survived cleanup.")
      if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    }
  }

  func testLanguageServiceTimeoutBoundsBlockedInputAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper, timeout: 1.5)
    addTeardownBlock { await service.stop() }
    let started = Date()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("The provider never reads didOpen and must time out.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "language_service_timeout")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let pids = try await languageServerPIDs(f)
    try await assertLanguageServerStopped(pids)
  }

  func testLanguageServiceTimeoutBoundsUnansweredResponseAndStopRejectsNewQueries() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    // Small didOpen fits in the pipe, so this exercises receive(), not blocked send().
    try f.write("source.ts", "export const value = 1;")
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper, timeout: 1.5)
    addTeardownBlock { await service.stop() }
    let started = Date()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("The provider never answers documentSymbol and must time out.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "language_service_timeout")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let pids = try await languageServerPIDs(f)
    try await assertLanguageServerStopped(pids)
    await service.stop()
    do {
      _ = try await service.query(path: "source.ts", action: "documentSymbols")
      XCTFail("A stopped service must not start a new provider.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "runtime_stopped")
    }
  }

  func testRuntimeStopInterruptsBlockedLanguageServiceAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let query = Task {
      await router.callInCurrentProject("code_query", arguments: ["action": "documentSymbols", "path": "source.ts"])
    }
    let pids = try await languageServerPIDs(f)
    let started = Date()
    await router.stop()
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    let result = await query.value
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.data["error"], "runtime_stopped")
    try await assertLanguageServerStopped(pids)
  }

  func testCancellationInterruptsBlockedLanguageServiceAndReapsProviderGroup() async throws {
    let f = try Fixture(); defer { f.remove() }
    try installBlockedLanguageServer(f)
    let service = CodeQueryService(workspace: f.files, helper: Fixture.helper)
    addTeardownBlock { await service.stop() }
    let query = Task { try await service.query(path: "source.ts", action: "documentSymbols") }
    let pids = try await languageServerPIDs(f)
    let started = Date()
    query.cancel()
    do {
      _ = try await query.value
      XCTFail("Cancelled language-service calls must stop.")
    } catch {
      XCTAssertEqual(Failure.safe(error).code, "runtime_stopped")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    try await assertLanguageServerStopped(pids)
  }
}
