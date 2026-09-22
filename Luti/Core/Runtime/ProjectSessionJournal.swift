import Foundation

extension ProjectContextStore {
  private func sessionURL(_ id: UUID) -> URL {
    sessionsDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
  }

  func sessionJournals() throws -> [SessionJournal] {
    try Self.lock.withLock {
      let names = try PrivateFiles.names(sessionsDirectory, limit: 1024)
      var result: [SessionJournal] = []
      for name in names where name.hasSuffix(".json") {
        guard let id = UUID(uuidString: String(name.dropLast(5))) else {
          throw Failure.invalid("Unexpected session journal filename.")
        }
        let data = try PrivateFiles.read(sessionsDirectory.appendingPathComponent(name), max: Self.maxSessionBytes)
        let journal = try ContextCoding.decode(SessionJournal.self, data)
        guard journal.schemaVersion == 1, journal.runId == id, journal.projectKey == projectKey else {
          throw Failure("session_identity_mismatch", "A session journal has an invalid project identity or schema.",
                        "Inspect this project's context in the local app.")
        }
        result.append(journal)
      }
      return result.sorted {
        $0.updatedAt == $1.updatedAt ? $0.runId.uuidString > $1.runId.uuidString : $0.updatedAt > $1.updatedAt
      }
    }
  }

  func session(_ id: UUID) throws -> SessionJournal {
    let journal = try ContextCoding.decode(SessionJournal.self, PrivateFiles.read(sessionURL(id), max: Self.maxSessionBytes))
    guard journal.schemaVersion == 1, journal.runId == id, journal.projectKey == projectKey else {
      throw Failure.invalid("The journal does not belong to this project and run.")
    }
    return journal
  }

  /// Called only by Runtime, never by a read-only UI visit. A → B → A resumes the
  /// same run file and keeps its facts instead of creating or replacing a session.
  func startSession(_ runID: UUID) throws {
    try Self.lock.withLock {
      for var prior in try sessionJournals() where prior.runId != runID && prior.finishedAt == nil {
        prior.status = "interrupted"
        // Last verified activity time, not a fabricated time of process death.
        prior.finishedAt = prior.updatedAt
        interruptUnfinished(&prior)
        try writeSession(prior, prune: false)
      }
      var journal: SessionJournal
      if try PrivateFiles.exists(sessionURL(runID)) {
        journal = try session(runID)
        guard journal.finishedAt == nil else { throw Failure.invalid("A finished runtime session cannot be resumed.") }
        journal.status = "running"
        journal.visits += 1
        journal.updatedAt = Date()
      } else {
        let now = Date()
        journal = SessionJournal(runId: runID, projectKey: projectKey, startedAt: now,
                                 updatedAt: now, finishedAt: nil, status: "running")
      }
      try writeSession(journal)
    }
  }

  func pauseSession(_ runID: UUID) throws {
    try Self.lock.withLock {
      var journal = try session(runID)
      journal.status = "paused"
      journal.updatedAt = Date()
      try writeSession(journal)
    }
  }

  func finishSession(_ runID: UUID) throws {
    try Self.lock.withLock {
      var journal = try session(runID)
      guard journal.finishedAt == nil else { return }
      journal.status = journal.calls.contains { $0.finishedAt == nil } ? "interrupted" : "completed"
      journal.updatedAt = Date()
      journal.finishedAt = journal.updatedAt
      interruptUnfinished(&journal)
      try writeSession(journal)
    }
  }

  private func interruptUnfinished(_ journal: inout SessionJournal) {
    journal.calls = journal.calls.map { call in
      guard call.finishedAt == nil else { return call }
      return SessionCall(id: call.id, tool: call.tool, action: call.action,
                         startedAt: call.startedAt, finishedAt: nil, status: "interrupted",
                         operationState: "interrupted", effect: "possible", jobId: call.jobId,
                         errorCode: "session_interrupted",
                         recovery: "Observe the current state before intentionally repeating an action.",
                         checkpointId: call.checkpointId, source: call.source)
    }
    for index in journal.jobs.indices where !journal.jobs[index].terminal {
      journal.jobs[index].status = "interrupted"
      // The outcome of a process after loss of ownership is unknown, not success.
      journal.jobs[index].terminal = true
      if var evidence = journal.jobs[index].validation {
        evidence.resultKind = "incomplete"
        evidence.processOutcome = "unknown"
        evidence.tests?.status = "unknown"
        evidence.input?.freshness = "unknown"
        journal.jobs[index].validation = evidence
      }
    }
  }

  func recordCallStarted(runID: UUID, id: UUID, tool: String, action: String?, startedAt: Date,
                         source: ActivitySource?) throws {
    try Self.lock.withLock {
      var journal = try session(runID)
      journal.toolCallCount += 1
      if journal.tools.count < 64 || journal.tools[tool] != nil { journal.tools[tool, default: 0] += 1 }
      journal.calls.append(SessionCall(id: id, tool: tool, action: action, startedAt: startedAt,
                                       finishedAt: nil, status: "running", operationState: nil,
                                       effect: nil, jobId: nil, errorCode: nil, recovery: nil,
                                       checkpointId: nil, source: source))
      journal.updatedAt = Date()
      try writeSession(journal)
    }
  }

  func recordCallFinished(runID: UUID, event: ActivityEvent, arguments: JSONValue,
                          output: ToolOutput) throws {
    try Self.lock.withLock {
      var journal = try session(runID)
      let checkpointID: String? = {
        guard let raw = output.data["checkpoint"]["id"].string,
              raw.hasPrefix("chk_"), raw.utf8.count <= 80,
              redactor.clean(raw) == raw else { return nil }
        return raw
      }()
      let call = SessionCall(id: event.id, tool: event.tool, action: event.action,
                             startedAt: event.startedAt, finishedAt: event.finishedAt,
                             status: event.status, operationState: event.operationState, effect: event.effect,
                             jobId: event.jobID, errorCode: event.errorCode,
                             // An allowlisted native recovery instruction, never an arbitrary output message.
                             recovery: event.errorCode == nil ? nil : "Inspect the failed operation before retrying; do not replay uncertain side effects.",
                             checkpointId: checkpointID, source: event.source)
      if let index = journal.calls.firstIndex(where: { $0.id == event.id }) { journal.calls[index] = call }
      else { journal.calls.append(call) }
      if output.isError { journal.failedCallCount += 1 }
      if !output.isError || (["run_process", "run_shell"].contains(event.tool) && output.data["jobId"].string != nil) {
        // A command that failed after launch still has verifiable command metadata.
        collectVerifiedFacts(into: &journal, tool: event.tool, arguments: arguments, result: output.data)
      }
      // A failed process is still a verifiable Job, and should not disappear from history.
      mergeJobs([output.data], into: &journal)
      journal.updatedAt = Date()
      try writeSession(journal)
    }
  }

  func reconcileSessionJobs(_ snapshots: [JSONValue], runID: UUID) throws {
    try Self.lock.withLock {
      var journal = try session(runID)
      let before = journal.jobs
      mergeJobs(snapshots, into: &journal)
      var newlyFailed = 0
      var callsChanged = false
      journal.calls = journal.calls.map { call in
        guard ["run_process", "run_shell"].contains(call.tool),
              let jobId = call.jobId, let job = journal.jobs.first(where: { $0.id == jobId }),
              call.finishedAt == nil, job.terminal else { return call }
        callsChanged = true
        let succeeded = job.status == "completed"
        if !succeeded { newlyFailed += 1 }
        return SessionCall(id: call.id, tool: call.tool, action: call.action, startedAt: call.startedAt,
                           finishedAt: Date(), status: succeeded ? "ok" : "failed",
                           operationState: job.status, effect: succeeded ? "confirmed" : "possible",
                           jobId: jobId, errorCode: succeeded ? nil : "job_" + job.status,
                           recovery: succeeded ? nil : "Inspect the job outcome before retrying; do not replay uncertain side effects.",
                           checkpointId: call.checkpointId, source: call.source)
      }
      // job_query may already have merged the terminal Job. Its successful query
      // must stay successful, while the originating command is completed exactly once.
      guard before != journal.jobs || callsChanged else { return }
      journal.failedCallCount += newlyFailed
      journal.updatedAt = Date()
      try writeSession(journal)
    }
  }

  private func collectVerifiedFacts(into journal: inout SessionJournal, tool: String,
                                    arguments: JSONValue, result: JSONValue) {
    func safePath(_ value: JSONValue) -> String? {
      guard let path = value.string, !path.isEmpty, path.utf8.count <= 4096,
            !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
            redactor.clean(path) == path else { return nil }
      return path
    }
    if tool == "read_files" {
      for file in result["files"].array ?? [] where file["failure"] == .null {
        if let path = safePath(file["path"]), !journal.readFiles.contains(path) { journal.readFiles.append(path) }
      }
    }
    if ["edit_files", "import_artifact"].contains(tool), result["applied"] == true, result["dryRun"] != true {
      let paths = (result["files"].array ?? []).filter { $0["wouldChange"] == true }.map { $0["path"] }
        + [result["path"]]
      for value in paths {
        if let path = safePath(value), !journal.touchedFiles.contains(path) { journal.touchedFiles.append(path) }
      }
    }
    if tool == "path_action", result["effect"] == "confirmed" {
      for value in [result["path"], result["source"], result["destination"]] {
        if let path = safePath(value), !journal.touchedFiles.contains(path) { journal.touchedFiles.append(path) }
      }
    }
    if ["run_process", "run_shell"].contains(tool), let jobID = result["jobId"].string,
       !journal.commands.contains(where: { $0.id == jobID }) {
      let task = result["task"]
      let args =
        arguments["args"].array?.compactMap(\.string)
        ?? task["args"].array?.compactMap(\.string)
        ?? []
      let rawProgram =
        tool == "run_shell" ? "shell"
        : (arguments["program"].string ?? task["program"].string ?? "process")
      let program = URL(fileURLWithPath: rawProgram).lastPathComponent
      let safeProgram = Budget.prefix(redactor.clean(program), bytes: 80)
      let taskID: String? = {
        guard let raw = task["id"].string, raw.hasPrefix("task:"),
              raw.utf8.count <= 128, redactor.clean(raw) == raw else { return nil }
        return raw
      }()
      var purpose = task["kind"].string.map { Budget.prefix($0, bytes: 32) }
      if tool == "run_process", purpose == nil {
        if ["xcodebuild", "swift", "npm", "pnpm", "yarn", "bun", "cargo", "go"].contains(program) {
          if args.contains("test") { purpose = "test" }
          else if args.contains("build") || args.contains("build-for-testing") { purpose = "build" }
        }
        if ["pytest", "vitest", "jest"].contains(program) { purpose = "test" }
      }
      journal.commands.append(
        SessionCommand(
          id: jobID, program: safeProgram, argumentCount: args.count,
          cwd: safePath(arguments["cwd"]) ?? safePath(task["cwd"]) ?? ".",
          purpose: purpose, taskId: taskID))
    }
    for value in [result["artifact"], result["source"], result] {
      guard let resource = value["resource"].string, resource.hasPrefix("luti://"),
            resource.utf8.count <= 256, !journal.artifacts.contains(where: { $0.id == resource }) else { continue }
      journal.artifacts.append(SessionArtifact(id: resource,
        name: Budget.prefix(redactor.clean(value["name"].string ?? "artifact"), bytes: 128),
        mimeType: Budget.prefix(value["mimeType"].string ?? "application/octet-stream", bytes: 80),
        bytes: value["bytes"].int ?? value["size"].int))
    }
  }

  private func mergeJobs(_ snapshots: [JSONValue], into journal: inout SessionJournal) {
    for value in snapshots {
      guard let id = value["jobId"].string, id.hasPrefix("job_"), id.utf8.count <= 80,
            let status = value["status"].string,
            ["running", "stopping", "completed", "failed", "timed_out", "stopped"].contains(status) else { continue }
      let counts = value["testSummary"]
      let tests: SessionTestCounts?
      if let passed = counts["passed"].int, let failed = counts["failed"].int {
        tests = SessionTestCounts(passed: max(0, passed), failed: max(0, failed),
          skipped: max(0, counts["skipped"].int ?? 0), errors: max(0, counts["errors"].int ?? 0),
          total: counts["total"].int)
      } else { tests = nil }
      var validation = try? ContextCoding.decode(ValidationEvidence.self, value["validation"].data())
      // Current is an observation made for this query, not an enduring assertion.
      // Persist only launch/end observations; querying refreshes it from the files.
      validation?.input?.current = nil
      validation?.input?.freshness = "unknown"
      var job = SessionJob(id: id, status: status, terminal: value["terminal"] == true,
                           exitCode: value["exitCode"].int, tests: tests, validation: validation)
      if let index = journal.jobs.firstIndex(where: { $0.id == id }) {
        let prior = journal.jobs[index]
        if prior.validationOmitted == true, prior.terminal, job.terminal,
           prior.status == job.status, prior.exitCode == job.exitCode, prior.tests == job.tests {
          // Periodic lifecycle reconciliation must not rehydrate, discard and
          // recount the same deliberately omitted evidence on every UI tick.
          job.validation = nil
          job.validationOmitted = true
        }
        journal.jobs[index] = job
      }
      else { journal.jobs.append(job) }

      if value["terminal"] == true {
        journal.diagnostics.removeAll { $0.jobId == id }
        for item in (value["diagnostics"].array ?? []).prefix(64) {
          guard let file = item["file"].string, !file.isEmpty, file.utf8.count <= 4096,
                !file.hasPrefix("/"), !file.split(separator: "/").contains(".."),
                !WorkspaceFiles.protected(file),
                let line = item["line"].int, (1...1_000_000).contains(line),
                let severity = item["severity"].string,
                ["error", "warning", "information"].contains(severity),
                let message = item["message"].string, !message.isEmpty,
                let source = item["source"].string, !source.isEmpty
          else { continue }
          let diagnostic = SessionDiagnostic(
            jobId: id,
            file: file,
            line: line,
            column: item["column"].int.flatMap { (1...1_000_000).contains($0) ? $0 : nil },
            severity: severity,
            code: item["code"].string.map { Budget.prefix(redactor.clean($0), bytes: 128) },
            message: Budget.prefix(redactor.clean(message), bytes: 1024),
            source: Budget.prefix(redactor.clean(source), bytes: 64))
          if !journal.diagnostics.contains(where: { $0.id == diagnostic.id }) {
            journal.diagnostics.append(diagnostic)
          }
        }
      }
    }
  }

  private func writeSession(_ value: SessionJournal, prune: Bool = true) throws {
    var journal = value
    func cap<T>(_ values: inout [T], _ limit: Int) -> Int {
      let dropped = max(0, values.count - limit)
      if dropped > 0 { values.removeFirst(dropped) }
      return dropped
    }
    journal.omittedFacts += cap(&journal.calls, 128)
    journal.omittedFacts += cap(&journal.readFiles, 128)
    journal.omittedFacts += cap(&journal.touchedFiles, 128)
    journal.omittedFacts += cap(&journal.commands, 64)
    journal.omittedFacts += cap(&journal.jobs, 64)
    journal.omittedFacts += cap(&journal.diagnostics, 64)
    journal.omittedFacts += cap(&journal.artifacts, 32)
    let latestValidation = journal.jobs.indices.filter { journal.jobs[$0].validation != nil }.max {
      let left = journal.jobs[$0].validation!.observedAt
      let right = journal.jobs[$1].validation!.observedAt
      return left == right ? $0 < $1 : left < right
    }
    var data = try ContextCoding.encode(journal)
    while data.count > Self.maxSessionBytes {
      if let oldEvidence = journal.jobs.indices.first(where: {
        $0 != latestValidation && journal.jobs[$0].validation != nil
      }) {
        // Optional hash detail must not crowd out the session's actual work.
        // Keep the newest evidence, plus every compact Job and test observation.
        journal.jobs[oldEvidence].validation = nil
        journal.jobs[oldEvidence].validationOmitted = true
      }
      else if !journal.calls.isEmpty { journal.calls.removeFirst() }
      else if !journal.readFiles.isEmpty { journal.readFiles.removeFirst() }
      else if !journal.touchedFiles.isEmpty { journal.touchedFiles.removeFirst() }
      else if !journal.artifacts.isEmpty { journal.artifacts.removeFirst() }
      else if !journal.diagnostics.isEmpty { journal.diagnostics.removeFirst() }
      else if !journal.commands.isEmpty { journal.commands.removeFirst() }
      else if !journal.jobs.isEmpty { journal.jobs.removeFirst() }
      else { throw Failure.invalid("Session metadata exceeds its storage budget.") }
      journal.omittedFacts += 1
      data = try ContextCoding.encode(journal)
    }
    try PrivateFiles.atomicWrite(data, to: sessionURL(journal.runId))
    if prune { try retainSessions(protecting: journal.runId) }
  }

  private func retainSessions(protecting id: UUID) throws {
    let journals = try sessionJournals().sorted { $0.startedAt < $1.startedAt }
    var count = journals.count
    var total = try journals.reduce(0) { try $0 + ContextCoding.encode($1).count }
    for journal in journals where journal.runId != id {
      guard count > Self.maxSessions || total > Self.maxSessionsBytes else { break }
      let bytes = try ContextCoding.encode(journal).count
      try PrivateFiles.removeFile(sessionURL(journal.runId))
      count -= 1
      total -= bytes
    }
  }

  func sessionsResult(runID: UUID?, limit: Int, offset: Int) throws -> JSONValue {
    try Self.lock.withLock {
      guard (1...50).contains(limit), (0...100_000).contains(offset) else {
        throw Failure.invalid("Invalid session pagination.")
      }
      if let runID {
        let journal = try session(runID)
        let tests = journal.jobs.filter { job in
          job.tests != nil || journal.commands.contains { $0.id == job.id && $0.purpose == "test" }
        }
        let builds = journal.jobs.filter { job in journal.commands.contains { $0.id == job.id && $0.purpose == "build" } }
        return ["action": "sessions", "projectKey": .string(projectKey),
                "session": try ContextCoding.json(journal), "tests": try ContextCoding.json(tests),
                "builds": try ContextCoding.json(builds),
                "outcomePolicy": "Exit status and parsed test counts are observations, not proof of correctness."]
      }
      let journals = try sessionJournals()
      let rows = Array(journals.dropFirst(offset).prefix(limit))
      let next = offset + rows.count
      return ["action": "sessions", "projectKey": .string(projectKey),
              "sessions": .array(try rows.map { try ContextCoding.json($0.metadata) }),
              "totalCount": .int(journals.count), "nextOffset": next < journals.count ? .int(next) : .null]
    }
  }

  func sessionsResultObserved(runID: UUID?, limit: Int, offset: Int,
                              files: WorkspaceFiles) async throws -> JSONValue {
    let result = try sessionsResult(runID: runID, limit: limit, offset: offset)
    guard let runID else { return result }
    var journal = try ContextCoding.decode(SessionJournal.self, result["session"].data())
    guard journal.runId == runID else { return result }
    for index in journal.jobs.indices {
      if let evidence = journal.jobs[index].validation {
        journal.jobs[index].validation = await evidence.refreshed(using: files)
      }
    }
    let tests = journal.jobs.filter { job in
      job.tests != nil || journal.commands.contains { $0.id == job.id && $0.purpose == "test" }
    }
    let builds = journal.jobs.filter { job in journal.commands.contains { $0.id == job.id && $0.purpose == "build" } }
    return result.adding("session", try ContextCoding.json(journal))
      .adding("tests", try ContextCoding.json(tests)).adding("builds", try ContextCoding.json(builds))
  }
}
