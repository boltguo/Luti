import Foundation

public actor JobManager {
  private struct Record {
    let process: OwnedProcess
    let fingerprint: String
    let key: String?
    let deadline: ContinuousClock.Instant
    let validation: ValidationScopeRequest?
    let before: ValidationScopeSnapshot?
    let reportBefore: ValidationFileDigest?
    var finalEvidence: Task<ValidationEvidence, Never>?
  }
  private let helper: URL
  private let redactor: Redactor
  private var jobs: [String: Record] = [:]
  private var order: [String] = []
  private var open = true
  public init(helper: URL, redactor: Redactor = Redactor()) {
    self.helper = helper
    self.redactor = redactor
  }
  public static var defaultHelper: URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
      .appendingPathComponent("LutiProcessHost")
  }
  public func submit(_ request: ProcessRequest, validation: ValidationScopeRequest? = nil) async throws -> JSONValue {
    guard open else { throw Failure.stopped }
    try Task.checkCancellation()
    try ProcessPolicy.validate(request)
    let validationIdentity: JSONValue = [
      "reportPath": validation?.reportPath.map(JSONValue.string) ?? .null,
      "taskId": validation?.taskID.map(JSONValue.string) ?? .null,
      "purpose": validation?.purpose.map(JSONValue.string) ?? .null,
    ]
    let fingerprint = request.fingerprint + Budget.sha256((try? validationIdentity.data()) ?? Data())
    if let key = request.idempotencyKey, let entry = jobs.first(where: { $0.value.key == key }) {
      guard entry.value.fingerprint == fingerprint else {
        throw Failure(
          "idempotency_conflict", "This key already refers to different command input.",
          "Observe the existing Job; use a new key only for an intentionally different operation.")
      }
      return await snapshot(entry.key)
    }
    let before: ValidationScopeSnapshot?
    let reportBefore: ValidationFileDigest?
    if let validation {
      before = await ValidationScopeSnapshot.capture(files: validation.files, paths: validation.paths)
      reportBefore = await Self.reportDigest(validation)
    } else { before = nil; reportBefore = nil }
    // File reads suspend the actor. Recheck ownership and idempotency before launch.
    guard open else { throw Failure.stopped }
    try Task.checkCancellation()
    if let key = request.idempotencyKey, let entry = jobs.first(where: { $0.value.key == key }) {
      guard entry.value.fingerprint == fingerprint else {
        throw Failure("idempotency_conflict", "This key already refers to different command input.",
                      "Observe the existing Job; use a new key only for a new operation.")
      }
      return await snapshot(entry.key)
    }
    guard jobs.values.filter({ !$0.process.finished }).count < 4 else {
      throw Failure(
        "job_capacity", "Four jobs are already active.",
        "Observe or stop an existing job before starting another.")
    }
    while jobs.count >= 64, let old = order.first(where: { jobs[$0]?.process.finished == true }) {
      jobs.removeValue(forKey: old)
      order.removeAll { $0 == old }
    }
    let process = try OwnedProcess(request, helper: helper, redactor: redactor)
    let id = "job_" + UUID().uuidString.lowercased()
    jobs[id] = Record(
      process: process, fingerprint: fingerprint, key: request.idempotencyKey,
      deadline: ContinuousClock.now.advanced(by: .seconds(request.timeout)),
      validation: validation, before: before, reportBefore: reportBefore)
    order.append(id)
    Task { [weak self] in
      while let self {
        if await self.enforceDeadline(id) { return }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    let until = ContinuousClock.now.advanced(by: .seconds(request.syncWait))
    while !process.finished && ContinuousClock.now < until {
      // Caller disconnect is not an instruction to spawn the command again.
      if Task.isCancelled { break }
      try? await Task.sleep(for: .milliseconds(30))
    }
    return await snapshot(id)
  }
  private func enforceDeadline(_ id: String) async -> Bool {
    guard let job = jobs[id] else { return true }
    if job.process.finished {
      _ = await snapshot(id, refreshInputs: false)
      return true
    }
    if ContinuousClock.now >= job.deadline { job.process.requestStop(reason: "timed_out") }
    return false
  }
  public func status(
    _ id: String, waitMilliseconds: Int = 0, knownStatus: String? = nil
  ) async throws -> JSONValue {
    guard let job = jobs[id] else {
      throw Failure(
        "job_not_found", "The job is unknown or its bounded history expired.",
        "Use the Job ID from this runtime instance; stopped runtimes do not recover prior jobs.")
    }
    let started = ContinuousClock.now
    func observed(_ snapshot: JSONValue) -> Bool {
      if snapshot["terminal"] == true { return true }
      guard let knownStatus else { return waitMilliseconds == 0 }
      return snapshot["status"].string != knownStatus
    }

    var snapshot = job.process.snapshot(id: id)
    if waitMilliseconds > 0, !observed(snapshot) {
      let deadline = started.advanced(by: .milliseconds(waitMilliseconds))
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(50))
        snapshot = job.process.snapshot(id: id)
        if observed(snapshot) { break }
      }
    }
    let elapsed = started.duration(to: .now).components
    let waitedMilliseconds = max(
      0, Int64(elapsed.seconds) * 1000 + Int64(elapsed.attoseconds / 1_000_000_000_000_000))
    let final = await self.snapshot(id)
    return final
      .adding("waitSatisfied", .bool(observed(final)))
      .adding("waitedMilliseconds", .integer(waitedMilliseconds))
  }
  public func input(_ id: String, text: String, close: Bool = false) async throws -> JSONValue {
    guard let job = jobs[id] else {
      throw Failure(
        "job_not_found", "The job does not exist.", "Use a Job ID returned by this runtime.")
    }
    let process = job.process
    // Pipe writes can block when a child stops reading. Perform the bounded write
    // away from this actor so status/stop/deadline calls remain responsive.
    try await Task.detached(priority: .utility) {
      try process.sendInput(text, close: close)
    }.value
    return await snapshot(id)
  }

  public func stop(_ id: String) async throws -> JSONValue {
    guard let job = jobs[id] else {
      throw Failure(
        "job_not_found", "The job does not exist.", "Use a Job ID returned by this runtime.")
    }
    job.process.requestStop()
    let until = ContinuousClock.now.advanced(by: .seconds(3))
    while !job.process.finished && ContinuousClock.now < until {
      try? await Task.sleep(for: .milliseconds(30))
    }
    return await snapshot(id)
  }
  func fullLog(_ id: String) throws -> Data? {
    guard let job = jobs[id] else { throw Failure.invalid("Unknown job ID.") }
    return job.process.fullLog()
  }
  func logs(_ id: String, stdoutOffset: Int, stderrOffset: Int, maxBytes: Int) async throws -> JSONValue {
    guard let job = jobs[id] else {
      throw Failure(
        "job_not_found", "The job does not exist.", "Use a Job ID returned by this runtime.")
    }
    let status = await snapshot(id)
    return status.adding(
      "delta",
      job.process.logDelta(
        stdoutOffset: stdoutOffset, stderrOffset: stderrOffset, maxBytes: maxBytes))
  }
  public func activeCount() -> Int { jobs.values.filter { !$0.process.finished }.count }
  public func stopActive() async -> Int {
    let active = jobs.values.filter { !$0.process.finished }
    for job in active { job.process.requestStop() }
    let until = ContinuousClock.now.advanced(by: .seconds(3))
    while jobs.values.contains(where: { !$0.process.finished }) && ContinuousClock.now < until {
      try? await Task.sleep(for: .milliseconds(30))
    }
    return active.count
  }
  public func list(refreshInputs: Bool = true) async -> [JSONValue] {
    var values: [JSONValue] = []
    for id in order.reversed() where jobs[id] != nil {
      values.append(await snapshot(id, refreshInputs: refreshInputs))
    }
    return values
  }

  private func snapshot(_ id: String, refreshInputs: Bool = true) async -> JSONValue {
    guard let job = jobs[id] else { return .null }
    var result = job.process.snapshot(id: id)
    guard let request = job.validation, let before = job.before else { return result }
    var evidence: ValidationEvidence
    if result["terminal"] == true {
      let task: Task<ValidationEvidence, Never>
      if let pending = job.finalEvidence { task = pending }
      else {
        let raw = result
        task = Task {
          await Self.completedEvidence(raw, request: request, before: before, reportBefore: job.reportBefore)
        }
        // Publish the same capture task before suspending, so concurrent observers
        // all use one execution-end observation and never move its timestamp.
        jobs[id]?.finalEvidence = task
      }
      evidence = await task.value
      if refreshInputs {
        evidence = await evidence.refreshed(using: request.files)
      } else {
        // Native status polling only needs lifecycle facts. Do not reread every
        // historical input or imply that an old observation describes now.
        evidence.input?.current = nil
        evidence.input?.freshness = "unknown"
      }
    } else {
      evidence = ValidationEvidence.process(command: "", stdout: "", stderr: "",
        status: result["status"].string ?? "running", terminal: false, outputComplete: false,
        observedAt: ISO8601DateFormatter().date(from: result["startedAt"].string ?? "") ?? before.observedAt)
      evidence.taskId = request.taskID
      evidence.input = ValidationInputEvidence(scope: "session-touched-files-and-manifests",
        scopeComplete: request.scopeComplete, before: before,
        consistency: "unknown", freshness: "unknown")
    }
    result = result.adding("validation", (try? ContextCoding.json(evidence)) ?? .null)
    if let tests = evidence.tests { result = result.adding("testSummary", tests.json) }
    return result
  }

  private static func reportDigest(_ request: ValidationScopeRequest) async -> ValidationFileDigest? {
    guard let path = request.reportPath else { return nil }
    do {
      let (data, _) = try await request.files.data(path)
      return ValidationFileDigest(path: path, state: "present", sha256: Budget.sha256(data))
    } catch {
      return ValidationFileDigest(path: path,
        state: (error as? Failure)?.code == "file_not_found" ? "missing" : "unknown", sha256: nil)
    }
  }

  private static func completedEvidence(_ result: JSONValue, request: ValidationScopeRequest,
                                        before: ValidationScopeSnapshot,
                                        reportBefore: ValidationFileDigest?) async -> ValidationEvidence {
    var evidence = (try? ContextCoding.decode(ValidationEvidence.self, result["validation"].data()))
      ?? ValidationEvidence.process(command: "", stdout: "", stderr: "",
        status: result["status"].string ?? "failed", terminal: true, outputComplete: false, observedAt: Date())
    evidence.taskId = request.taskID
    let after = await ValidationScopeSnapshot.capture(files: request.files, paths: request.paths)
    evidence.input = ValidationInputEvidence(scope: "session-touched-files-and-manifests",
      scopeComplete: request.scopeComplete, before: before, after: after, current: after,
      consistency: "unknown", freshness: "unknown")
    evidence.input?.assess()
    if evidence.resultKind == "command_only", evidence.processOutcome == "succeeded", request.purpose == "build" {
      evidence.resultKind = "build_only"
    }
    if let path = request.reportPath {
      do {
        let (data, _) = try await request.files.data(path)
        let digest = Budget.sha256(data)
        let changed = reportBefore?.state == "missing"
          || (reportBefore?.state == "present" && reportBefore?.sha256 != digest)
        let parsed = TestEvidenceParser.junit(data)
        let accepted = changed && parsed != nil && evidence.processOutcome != "interrupted"
        evidence.report = ValidationReportEvidence(path: path, source: "junit-xml", sha256: digest,
          provenance: changed ? "changed_since_launch" : "unknown",
          status: accepted ? "parsed" : parsed == nil ? "invalid_or_incomplete" : "unattributed")
        if accepted, let parsed {
          evidence.tests = parsed
          evidence.resultKind = parsed.total == 0 ? "no_tests" : "tests_recognized"
        }
      } catch {
        evidence.report = ValidationReportEvidence(path: path, source: "junit-xml", sha256: nil,
          provenance: "unknown", status: "unavailable")
      }
    }
    return evidence
  }

  public func shutdown() async {
    open = false
    for job in jobs.values { job.process.requestStop() }
    let until = ContinuousClock.now.advanced(by: .seconds(4))
    while jobs.values.contains(where: { !$0.process.finished }) && ContinuousClock.now < until {
      try? await Task.sleep(for: .milliseconds(30))
    }
  }
}
