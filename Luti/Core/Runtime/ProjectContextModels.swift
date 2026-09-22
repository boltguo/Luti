import Foundation

// All durable context has one schema. Unknown/corrupt schemas fail closed; no legacy decoding.
enum ContextCoding {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    // Validate duplicate keys/depth before Codable accepts a document.
    _ = try JSONValue.decode(data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: data)
  }
  static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue.decode(encode(value))
  }
}

struct ProjectManifest: Codable, Sendable {
  var schemaVersion = 1
  var identityScheme = "canonical-path-sha256-v1"
  let sourcePath: String
  let projectKey: String
  var projectName: String
  let createdAt: Date
  var updatedAt: Date
}

enum MemoryKind: String, CaseIterable, Codable, Sendable {
  case architecture, decision, convention, constraint, security, pitfall, goal, rationale
}

enum MemoryStatus: String, Codable, Sendable { case active, superseded, forgotten }

struct MemorySource: Codable, Sendable, Equatable {
  let type: String
  let runId: UUID
  let host: String
  let clientId: String?
  let transport: String

  static func model(runID: UUID, grant: ToolGrant, redactor: Redactor) -> MemorySource {
    MemorySource(
      type: "model", runId: runID,
      host: Budget.prefix(redactor.clean(grant.context?.clientName ?? "local-client"), bytes: 64),
      clientId: grant.context?.clientID,
      transport: grant.context?.transport.rawValue ?? "loopback")
  }
}

struct MemoryAtom: Codable, Sendable, Identifiable, Equatable {
  let id: String
  let kind: MemoryKind
  let content: String
  let source: MemorySource
  let createdAt: Date
  var updatedAt: Date
  var status: MemoryStatus
  let supersedes: String?
  let tags: [String]
  let revision: Int
}

/// One complete transaction per JSONL line. A supersede changes the derived status
/// of the prior atom in this same transaction; a forget is a provenance-bearing tombstone.
struct MemoryMutation: Codable, Sendable {
  var schemaVersion = 1
  let revision: Int
  let operation: String
  let atom: MemoryAtom?
  let memoryId: String?
  let source: MemorySource
  let createdAt: Date
}

struct MemorySummary: Codable, Sendable {
  let generatedAt: Date
  let sourceRevision: Int
  let text: String
  let memoryIds: [String]
  let truncated: Bool
}

struct SessionCall: Codable, Sendable, Identifiable {
  let id: UUID
  let tool: String
  let action: String?
  let startedAt: Date
  let finishedAt: Date?
  let status: String
  let operationState: String?
  let effect: String?
  let jobId: String?
  let errorCode: String?
  let recovery: String?
  let checkpointId: String?
  let source: ActivitySource?
}

struct SessionCommand: Codable, Sendable, Identifiable {
  let id: String
  let program: String
  let argumentCount: Int
  let cwd: String
  let purpose: String?
  let taskId: String?
  // No argv, shell source, stdin, environment, stdout or stderr fields by design.
}

struct SessionJob: Codable, Sendable, Identifiable, Equatable {
  let id: String
  var status: String
  var terminal: Bool
  var exitCode: Int?
  var tests: SessionTestCounts?
}

struct SessionTestCounts: Codable, Sendable, Equatable {
  let passed: Int
  let failed: Int
  let skipped: Int
}

struct SessionDiagnostic: Codable, Sendable, Equatable, Identifiable {
  let jobId: String
  let file: String
  let line: Int
  let column: Int?
  let severity: String
  let code: String?
  let message: String
  let source: String

  var id: String {
    [
      jobId, file, String(line), String(column ?? 0), severity, code ?? "", message, source,
    ].joined(separator: "\u{1f}")
  }
}

struct SessionArtifact: Codable, Sendable, Identifiable {
  let id: String
  let name: String
  let mimeType: String
  let bytes: Int?
  // Metadata only. The runtime owns the bytes; this record does not revive an expired handle.
}

struct SessionJournal: Codable, Sendable, Identifiable {
  var schemaVersion = 1
  let runId: UUID
  let projectKey: String
  let startedAt: Date
  var updatedAt: Date
  var finishedAt: Date?
  var status: String
  var visits = 1
  var toolCallCount = 0
  var failedCallCount = 0
  var tools: [String: Int] = [:]
  var calls: [SessionCall] = []
  var touchedFiles: [String] = []
  var readFiles: [String] = []
  var commands: [SessionCommand] = []
  var jobs: [SessionJob] = []
  var diagnostics: [SessionDiagnostic] = []
  var artifacts: [SessionArtifact] = []
  var omittedFacts = 0

  var id: UUID { runId }
  var metadata: SessionMetadata {
    SessionMetadata(
      runId: runId, projectKey: projectKey, startedAt: startedAt, updatedAt: updatedAt,
      finishedAt: finishedAt, status: status, visits: visits, toolCallCount: toolCallCount,
      touchedFileCount: touchedFiles.count, jobCount: jobs.count,
      failureCount: failedCallCount,
      omittedFacts: omittedFacts)
  }
}

struct SessionMetadata: Codable, Sendable, Identifiable {
  let runId: UUID
  let projectKey: String
  let startedAt: Date
  let updatedAt: Date
  let finishedAt: Date?
  let status: String
  let visits: Int
  let toolCallCount: Int
  let touchedFileCount: Int
  let jobCount: Int
  let failureCount: Int
  let omittedFacts: Int
  var id: UUID { runId }
}

struct ProjectContextSnapshot: Sendable {
  let memoryCount: Int
  let sessionCount: Int
  let revision: Int
  let summary: MemorySummary
  let memories: [MemoryAtom]
  let sessions: [SessionMetadata]
}

enum ProjectContextSelection: String, CaseIterable, Identifiable, Hashable, Sendable {
  case memory, sessions, activity, all
  var id: String { rawValue }
}
