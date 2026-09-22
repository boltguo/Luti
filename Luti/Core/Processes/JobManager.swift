import Foundation

public actor JobManager {
  private struct Record {
    let process: OwnedProcess
    let fingerprint: String
    let key: String?
    let deadline: ContinuousClock.Instant
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
  public func submit(_ request: ProcessRequest) async throws -> JSONValue {
    guard open else { throw Failure.stopped }
    try Task.checkCancellation()
    try ProcessPolicy.validate(request)
    if let key = request.idempotencyKey, let entry = jobs.first(where: { $0.value.key == key }) {
      guard entry.value.fingerprint == request.fingerprint else {
        throw Failure(
          "idempotency_conflict", "This key already refers to different command input.",
          "Observe the existing Job; use a new key only for an intentionally different operation.")
      }
      return entry.value.process.snapshot(id: entry.key)
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
      process: process, fingerprint: request.fingerprint, key: request.idempotencyKey,
      deadline: ContinuousClock.now.advanced(by: .seconds(request.timeout)))
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
    return process.snapshot(id: id)
  }
  private func enforceDeadline(_ id: String) -> Bool {
    guard let job = jobs[id] else { return true }
    if job.process.finished { return true }
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
    return snapshot
      .adding("waitSatisfied", .bool(observed(snapshot)))
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
    return process.snapshot(id: id)
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
    return job.process.snapshot(id: id)
  }
  func fullLog(_ id: String) throws -> Data? {
    guard let job = jobs[id] else { throw Failure.invalid("Unknown job ID.") }
    return job.process.fullLog()
  }
  func logs(_ id: String, stdoutOffset: Int, stderrOffset: Int, maxBytes: Int) throws -> JSONValue {
    guard let job = jobs[id] else {
      throw Failure(
        "job_not_found", "The job does not exist.", "Use a Job ID returned by this runtime.")
    }
    let status = job.process.snapshot(id: id)
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
  public func list() -> [JSONValue] {
    order.reversed().compactMap { id in jobs[id]?.process.snapshot(id: id) }
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
