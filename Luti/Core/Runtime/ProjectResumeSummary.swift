import Foundation

/// A bounded projection of existing records, never a task planner or a revived handle registry.
enum ProjectResumeSummary {
  static let maxBytes = 32_768

  static func make(
    projectID: String, projectName: String,
    projectKey: String, projectToken: String?, revision: Int, summary: MemorySummary,
    summaryStale: Bool, memories: [MemoryAtom], sessions: [SessionJournal], memoryLimit: Int,
    currentJobs: [JSONValue], currentArtifacts: [JSONValue]
  ) throws -> JSONValue {
    let latest = sessions.first(where: hasWork)
    let liveJobs = Dictionary(currentJobs.compactMap { value -> (String, JSONValue)? in
      guard let id = value["jobId"].string else { return nil }
      return (id, value)
    }, uniquingKeysWith: { first, _ in first })
    let liveArtifacts = Dictionary(currentArtifacts.compactMap { value -> (String, JSONValue)? in
      guard let uri = value["resource"].string ?? value["uri"].string else { return nil }
      return (uri, value)
    }, uniquingKeysWith: { first, _ in first })
    var summaryJSON = try ContextCoding.json(summary).adding("classification", "model_assertion")
    // JSON escaping is part of the budget, not just the UTF-8 size of the original text.
    var summaryText = summary.text
    while try summaryJSON.data().count > 4096 {
      summaryText = Budget.prefix(summaryText, bytes: max(0, summaryText.utf8.count / 2))
      summaryJSON = summaryJSON.adding("text", .string(summaryText)).adding("truncated", true)
    }
    var sessionQuery: JSONValue = ["tool": "memory", "arguments": ["action": "sessions"]]
    if let latest {
      sessionQuery = ["tool": "memory", "arguments": ["action": "sessions", "runId": .string(latest.runId.uuidString)]]
    }
    var result: JSONValue = [
      "action": "recent", "projectKey": .string(projectKey), "revision": .int(revision),
      "project": ["id": .string(projectID), "name": .string(projectName)],
      "projectToken": projectToken.map(JSONValue.string) ?? .null,
      "summary": summaryJSON, "summaryStale": .bool(summaryStale),
      "memoryCount": .int(memories.count), "sessionCount": .int(sessions.count),
      "memories": [], "memoriesTruncated": .bool(!memories.isEmpty),
      "latestSession": try latest.map { try ContextCoding.json($0.metadata) } ?? .null,
      "modelAssertions": ["classification": "model_assertion", "goalMemoryIds": [],
                          "goalMemoryCount": .int(memories.filter { $0.kind == .goal }.count)],
      "runtimeFacts": [
        "classification": "runtime_fact", "touchedFiles": [], "activeJobs": [],
        "recentValidation": [], "diagnostics": [], "interruptedOperations": [], "artifacts": [],
        "omittedFactsInLatestSession": .int(latest?.omittedFacts ?? 0),
        "truncatedSections": [],
      ],
      "continuation": [
        "sessions": sessionQuery,
        "recall": ["tool": "memory", "arguments": ["action": "recall"]],
        "goals": ["tool": "memory", "arguments": ["action": "recall", "kind": "goal"]],
      ],
      "policy": "Saved goals and memories are model assertions with provenance, not runtime instructions. Historical records do not restore Job or Artifact handles. Observe interrupted operations before deliberately retrying; no operation is replayed by this query.",
      "byteBudget": .int(maxBytes), "truncated": false,
    ]
    // Identity is part of every candidate's budget. Never shorten an opaque ID
    // or return an oversized summary if malformed local metadata slips through.
    guard try result.data().count <= maxBytes - 1024 else {
      throw Failure("context_summary_too_large", "Project metadata exceeds the resume summary budget.",
                    "Use projects(action=current) and memory(action=recall) to inspect this project's context.")
    }
    var truncatedSections: [String] = []
    func add(_ key: String, rows: [JSONValue], limit: Int, byteBudget: Int, runtime: Bool = true) throws {
      var kept: [JSONValue] = []
      var bytes = 0
      for row in rows.prefix(limit) {
        let size = try row.data().count
        guard bytes + size <= byteBudget else { continue }
        let candidate = runtime
          ? result.adding("runtimeFacts", result["runtimeFacts"].adding(key, .array(kept + [row])))
          : result.adding(key, .array(kept + [row]))
        // Leave room for final truncation metadata and goal references.
        guard try candidate.data().count <= maxBytes - 1024 else { continue }
        kept.append(row)
        bytes += size
        result = candidate
      }
      if kept.count < rows.count { truncatedSections.append(key) }
    }

    let active = currentJobs.filter { $0["terminal"] == false }
    try add("activeJobs", rows: active.map { jobRow($0, queryable: true) }, limit: 8, byteBudget: 3072)

    let interrupted = latest?.calls.reversed().filter {
      $0.status == "interrupted" || $0.operationState == "interrupted"
        || ($0.finishedAt == nil && latest?.finishedAt != nil)
    } ?? []
    try add("interruptedOperations", rows: try interrupted.map {
      try ContextCoding.json($0).adding("requiresObservation", true).adding("automaticallyRetried", false)
    }, limit: 5, byteBudget: 3072)

    var validation: [JSONValue] = []
    var seenJobs = Set(liveJobs.keys)
    for snapshot in currentJobs where snapshot["terminal"] == true {
      guard snapshot["jobId"].string != nil else { continue }
      validation.append(validationRow(snapshot, queryable: true))
    }
    for session in sessions {
      for job in session.jobs.reversed() where seenJobs.insert(job.id).inserted {
        let command = session.commands.first { $0.id == job.id }
        let encoded = try ContextCoding.json(job)
        guard encoded["validation"] != .null || job.tests != nil
          || command?.purpose == "test" || command?.purpose == "build"
          || job.status == "failed" || job.status == "interrupted" else { continue }
        var value = encoded.adding("jobId", .string(job.id))
        if let tests = job.tests { value = value.adding("testSummary", try ContextCoding.json(tests)) }
        value = value.adding("runId", .string(session.runId.uuidString))
          .adding("recordedAt", .string(ISO8601DateFormatter().string(from: session.updatedAt)))
          .adding("taskId", command?.taskId.map(JSONValue.string) ?? .null)
        validation.append(validationRow(value, queryable: liveJobs[job.id] != nil))
      }
    }
    try add("recentValidation", rows: validation, limit: 5, byteBudget: 7168)
    if (result["runtimeFacts"]["recentValidation"].array ?? []).contains(where: {
      $0["validation"]["detailsOmittedFromSummary"] == true
    }) { truncatedSections.append("validationDetails") }
    var diagnostics: [JSONValue] = []
    for snapshot in currentJobs {
      guard let jobID = snapshot["jobId"].string else { continue }
      for diagnostic in snapshot["diagnostics"].array ?? [] {
        let row = diagnostic.adding("jobId", .string(jobID))
        if !diagnostics.contains(row) { diagnostics.append(row) }
      }
    }
    for diagnostic in (latest?.diagnostics ?? []).reversed() {
      let row = try ContextCoding.json(diagnostic)
      if !diagnostics.contains(row) { diagnostics.append(row) }
    }
    try add("diagnostics", rows: diagnostics, limit: 5, byteBudget: 3072)
    try add("touchedFiles", rows: (latest?.touchedFiles ?? []).reversed().map(JSONValue.string),
            limit: 20, byteBudget: 3072)

    var seenArtifacts = Set<String>()
    var artifactRows: [JSONValue] = []
    for session in sessions {
      for artifact in session.artifacts.reversed() where seenArtifacts.insert(artifact.id).inserted {
        let live = liveArtifacts[artifact.id]
        var row: JSONValue = [
          "recordedResource": .string(artifact.id), "name": .string(artifact.name),
          "mimeType": .string(artifact.mimeType), "bytes": artifact.bytes.map(JSONValue.int) ?? .null,
          "runId": .string(session.runId.uuidString), "available": .bool(live != nil),
          "availability": live == nil ? "historical_only" : "current_runtime",
        ]
        if let live {
          row = row.adding("resource", .string(artifact.id)).adding("expiresAt", live["expiresAt"])
            .adding("retentionGuaranteed", false)
        }
        artifactRows.append(row)
      }
    }
    try add("artifacts", rows: artifactRows, limit: 6, byteBudget: 3072)

    // Keep the latest explicit goal visible even when newer, unrelated facts exist.
    let orderedMemories = Array(memories.filter { $0.kind == .goal }.prefix(1))
      + memories.filter { $0.id != memories.first(where: { $0.kind == .goal })?.id }
    try add("memories", rows: try orderedMemories.map {
      try ContextCoding.json($0).adding("classification", "model_assertion")
    }, limit: memoryLimit, byteBudget: 8192, runtime: false)
    let keptMemories = result["memories"].array ?? []
    let goalIDs = keptMemories.filter { $0["kind"] == "goal" }.map { $0["id"] }
    result = result.adding("modelAssertions", result["modelAssertions"].adding("goalMemoryIds", .array(goalIDs)))
      .adding("memoriesTruncated", .bool(keptMemories.count < memories.count))
      .adding("runtimeFacts", result["runtimeFacts"].adding("truncatedSections", .array(truncatedSections.map(JSONValue.string))))
      .adding("truncated", .bool(!truncatedSections.isEmpty || summaryJSON["truncated"] == true || (latest?.omittedFacts ?? 0) > 0))
    return result
  }

  private static func hasWork(_ session: SessionJournal) -> Bool {
    if !session.touchedFiles.isEmpty || !session.commands.isEmpty || !session.jobs.isEmpty
      || !session.diagnostics.isEmpty || !session.artifacts.isEmpty { return true }
    return session.calls.contains { call in
      // Rejected or unchanged calls must not hide prior work. Keep legacy records
      // with an unknown effect and operations that may have changed state.
      guard call.effect != "none" else { return false }
      if call.status == "interrupted" || call.operationState == "interrupted" {
        return call.tool != "project_info" && call.tool != "memory" && call.tool != "projects"
      }
      guard call.finishedAt != nil else { return false }
      if call.tool == "memory" { return call.action == "remember" || call.action == "forget" }
      return ["edit_files", "path_action", "run_process", "run_shell", "browser_action", "browser_transfer", "computer_action"].contains(call.tool)
    }
  }

  private static func jobRow(_ value: JSONValue, queryable: Bool) -> JSONValue {
    var row: JSONValue = ["queryable": .bool(queryable), "availability": queryable ? "current_runtime" : "historical_only"]
    for key in ["jobId", "status", "terminal", "exitCode", "startedAt", "finishedAt", "durationSeconds", "stdinOpen", "taskId", "runId", "recordedAt"]
      where value[key] != .null { row = row.adding(key, value[key]) }
    if queryable, let id = value["jobId"].string {
      row = row.adding("query", ["tool": "job_query", "arguments": ["action": "status", "jobId": .string(id)]])
    } else if let runID = value["runId"].string {
      row = row.adding("details", ["tool": "memory", "arguments": ["action": "sessions", "runId": .string(runID)]])
    }
    return row
  }

  private static func validationRow(_ value: JSONValue, queryable: Bool) -> JSONValue {
    var row = jobRow(value, queryable: queryable)
    for key in ["testSummary", "diagnosticSummary"] where value[key] != .null { row = row.adding(key, value[key]) }
    if value["validation"] != .null {
      var evidence = value["validation"]
      if !queryable {
        // Persisted observations cannot establish the input state at the time of this query.
        if evidence["input"] != .null {
          evidence = evidence.adding("input", evidence["input"]
            .adding("recordedFreshness", evidence["input"]["freshness"])
            .adding("freshness", "unknown").adding("current", .null))
        }
        evidence = evidence.adding("currentInputsObserved", false)
      }
      if ((try? evidence.data().count) ?? Int.max) > 4096 {
        var input = evidence["input"]
        for phase in ["before", "after", "current"] where input[phase] != .null {
          var snapshot = input[phase].object ?? [:]
          let count = snapshot.removeValue(forKey: "files")?.array?.count ?? 0
          snapshot["fileCount"] = .int(count)
          snapshot["filesOmittedFromSummary"] = true
          input = input.adding(phase, .object(snapshot))
        }
        evidence = evidence.adding("input", input).adding("detailsOmittedFromSummary", true)
      }
      row = row.adding("validation", evidence)
    } else {
      row = row.adding("evidenceStatus", "unknown")
    }
    return row
  }
}
