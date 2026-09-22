import Foundation

/// The caller supplies only the bounded scope it actually knows about. This is
/// deliberately not a claim that all inputs to a command have been enumerated.
public struct ValidationScopeRequest: Sendable {
  let files: WorkspaceFiles
  let paths: [String]
  let scopeComplete: Bool
  let taskID: String?
  let purpose: String?
  let reportPath: String?

  public init(files: WorkspaceFiles, paths: [String], scopeComplete: Bool = false,
              taskID: String? = nil, purpose: String? = nil, reportPath: String? = nil) {
    self.files = files
    self.paths = paths
    self.scopeComplete = scopeComplete
    self.taskID = taskID
    self.purpose = purpose
    self.reportPath = reportPath
  }
}

struct ValidationFileDigest: Codable, Sendable, Equatable {
  let path: String
  let state: String
  let sha256: String?
}

struct ValidationScopeSnapshot: Codable, Sendable, Equatable {
  let observedAt: Date
  let files: [ValidationFileDigest]
  let complete: Bool
  let omittedFiles: Int

  static func capture(files workspace: WorkspaceFiles, paths: [String]) async -> Self {
    let unique = Array(Set(paths)).sorted()
    var rows: [ValidationFileDigest] = []
    var remaining = 2_097_152
    var pathBytes = 0
    var complete = unique.count <= 32
    var omitted = max(0, unique.count - 32)
    for path in unique.prefix(32) {
      guard (try? WorkspaceFiles.components(path)) != nil,
            pathBytes + path.utf8.count <= 4096 else {
        complete = false
        omitted += 1
        continue
      }
      pathBytes += path.utf8.count
      do {
        guard remaining > 0 else { throw Failure.invalid("Validation input budget exceeded.") }
        let (data, _) = try await workspace.data(path, limit: min(remaining, WorkspaceFiles.maxFileBytes))
        remaining -= data.count
        rows.append(ValidationFileDigest(path: path, state: "present", sha256: Budget.sha256(data)))
      } catch {
        let missing = (error as? Failure)?.code == "file_not_found"
        if !missing { complete = false }
        rows.append(ValidationFileDigest(path: path, state: missing ? "missing" : "unknown", sha256: nil))
      }
    }
    return Self(observedAt: Date(), files: rows, complete: complete, omittedFiles: omitted)
  }
}

struct ValidationInputEvidence: Codable, Sendable, Equatable {
  let scope: String
  let scopeComplete: Bool
  let before: ValidationScopeSnapshot
  var after: ValidationScopeSnapshot?
  var current: ValidationScopeSnapshot?
  // No filesystem snapshot/lock covers the execution interval.
  let consistency: String
  var freshness: String

  mutating func assess() {
    guard let after, let current else { freshness = "unknown"; return }
    let observations = [before, after, current]
    // A known difference is stale even if other files could not be read.
    let baseline = Dictionary(uniqueKeysWithValues: before.files.map { ($0.path, $0) })
    for snapshot in [after, current] {
      for file in snapshot.files {
        if let prior = baseline[file.path], prior.state != "unknown", file.state != "unknown",
           prior != file {
          freshness = "stale"
          return
        }
      }
    }
    guard !before.files.isEmpty, observations.allSatisfy(\.complete),
          before.files == after.files, after.files == current.files else {
      freshness = "unknown"
      return
    }
    freshness = "observed_match"
  }
}

struct ValidationTestEvidence: Codable, Sendable, Equatable {
  let framework: String
  var status: String
  let total: Int
  let passed: Int
  let failed: Int
  let skipped: Int
  let errors: Int
  let source: String

  var json: JSONValue { (try? ContextCoding.json(self)) ?? .null }
}

struct ValidationReportEvidence: Codable, Sendable, Equatable {
  let path: String
  let source: String
  let sha256: String?
  let provenance: String
  let status: String
}

struct ValidationEvidence: Codable, Sendable, Equatable {
  var resultKind: String
  var processOutcome: String
  let observedAt: Date
  let outputComplete: Bool
  var taskId: String?
  var tests: ValidationTestEvidence?
  var report: ValidationReportEvidence?
  var input: ValidationInputEvidence?

  func refreshed(using files: WorkspaceFiles) async -> Self {
    var result = self
    if let input {
      result.input?.current = await ValidationScopeSnapshot.capture(
        files: files, paths: input.before.files.map(\.path))
      result.input?.assess()
    }
    return result
  }

  static func process(command: String, stdout: String, stderr: String, status: String,
                      terminal: Bool, outputComplete: Bool, observedAt: Date) -> Self {
    let interrupted = ["stopped", "timed_out", "stopping"].contains(status)
    let outcome = !terminal ? "running" : interrupted ? "interrupted" : status == "completed" ? "succeeded" : "failed"
    var tests = terminal ? TestEvidenceParser.parse(stdout + "\n" + stderr) : nil
    if !outputComplete || interrupted { tests?.status = "unknown" }
    let kind: String
    if !terminal { kind = "running" }
    else if !outputComplete || interrupted { kind = "incomplete" }
    else if let tests { kind = tests.total == 0 ? "no_tests" : "tests_recognized" }
    else { kind = "command_only" }
    return Self(resultKind: kind, processOutcome: outcome, observedAt: observedAt,
                outputComplete: outputComplete, tests: tests)
  }
}
