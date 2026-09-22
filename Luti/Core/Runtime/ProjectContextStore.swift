import Foundation

/// The app is the sole context writer. This shared lock serializes every store instance
/// (runtime, multiple hosts and local UI) including read/modify/commit transactions.
/// There is no process-global semantic memory: only the lock is shared.
final class ProjectContextStore: @unchecked Sendable {
  static let lock = NSRecursiveLock()
  static let maxActiveMemories = 200
  static let maxMemoryBytes = 8 * 1_048_576
  static let maxSessionBytes = 65_536
  static let maxSessions = 100
  static let maxSessionsBytes = 4 * 1_048_576

  let projectKey: String
  let sourcePath: String
  let directory: URL
  let memoryDirectory: URL
  let sessionsDirectory: URL
  let activityDirectory: URL
  let redactor: Redactor
  private let projectID: String
  private let projectName: String
  private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
  private var factsURL: URL { memoryDirectory.appendingPathComponent("facts.jsonl") }
  private var summaryURL: URL { memoryDirectory.appendingPathComponent("project.md") }

  init(project: ApprovedProject, dataRoot: URL = LutiPaths.root, redactor: Redactor = Redactor(), validateMemory: Bool = true) throws {
    sourcePath = LutiPaths.canonicalProjectURL(project.url).path
    projectKey = LutiPaths.projectKey(for: project.url)
    projectID = project.id
    projectName = Budget.prefix(redactor.clean(project.name), bytes: 128)
    directory = dataRoot.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(projectKey, isDirectory: true)
    memoryDirectory = directory.appendingPathComponent("memory", isDirectory: true)
    sessionsDirectory = directory.appendingPathComponent("sessions", isDirectory: true)
    activityDirectory = directory.appendingPathComponent("activity", isDirectory: true)
    self.redactor = redactor
    try Self.lock.withLock {
      for url in [dataRoot, dataRoot.appendingPathComponent("projects"), directory,
                  memoryDirectory, sessionsDirectory, activityDirectory] {
        try PrivateFiles.directory(url)
      }
      if try PrivateFiles.exists(manifestURL) {
        _ = try manifest()
      } else {
        let now = Date()
        let value = ProjectManifest(sourcePath: sourcePath, projectKey: projectKey,
                                    projectName: projectName, createdAt: now, updatedAt: now)
        try PrivateFiles.atomicWrite(ContextCoding.encode(value), to: manifestURL)
      }
      if validateMemory {
        if try !PrivateFiles.exists(factsURL) { try PrivateFiles.atomicWrite(Data(), to: factsURL) }
        materialize(try loadMemory())
      }
    }
  }

  private func manifest() throws -> ProjectManifest {
    let value = try ContextCoding.decode(ProjectManifest.self, PrivateFiles.read(manifestURL, max: 16_384))
    guard value.schemaVersion == 1, value.identityScheme == "canonical-path-sha256-v1",
          value.sourcePath == sourcePath, value.projectKey == projectKey else {
      throw Failure("context_identity_mismatch", "Project context does not match its canonical path or schema.",
                    "Inspect the local project context; do not merge or overwrite another project's data.")
    }
    return value
  }

  struct MemoryState {
    var revision = 0
    var atoms: [String: MemoryAtom] = [:]
    var bytes = Data()
    var updatedAt: Date
  }

  private func loadMemory() throws -> MemoryState {
    let metadata = try manifest()
    var state = MemoryState(updatedAt: metadata.createdAt)
    state.bytes = try PrivateFiles.read(factsURL, max: Self.maxMemoryBytes)
    // Writes replace a complete ledger atomically. A partial line is corruption,
    // not an invitation to silently discard a durable fact.
    guard state.bytes.isEmpty || state.bytes.last == 10 else { throw corruptMemory() }
    do {
      for line in state.bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
        guard !line.isEmpty, line.count <= 16_384 else { throw corruptMemory() }
        let mutation = try ContextCoding.decode(MemoryMutation.self, Data(line))
        guard mutation.schemaVersion == 1, mutation.revision == state.revision + 1 else { throw corruptMemory() }
        switch mutation.operation {
        case "remember":
          guard let atom = mutation.atom, mutation.memoryId == nil,
                atom.revision == mutation.revision, atom.source == mutation.source,
                atom.status == .active, atom.id.hasPrefix("mem_"), atom.id.count <= 80,
                !atom.content.isEmpty, atom.content.utf8.count <= 4096,
                atom.tags.count <= 8, atom.tags.allSatisfy({ $0.utf8.count <= 32 }),
                state.atoms[atom.id] == nil else { throw corruptMemory() }
          if let prior = atom.supersedes {
            guard var old = state.atoms[prior], old.status == .active else { throw corruptMemory() }
            old.status = .superseded
            old.updatedAt = mutation.createdAt
            state.atoms[prior] = old
          }
          state.atoms[atom.id] = atom
        case "forget":
          guard mutation.atom == nil, let id = mutation.memoryId,
                var old = state.atoms[id], old.status != .forgotten else { throw corruptMemory() }
          old.status = .forgotten
          old.updatedAt = mutation.createdAt
          state.atoms[id] = old
        default: throw corruptMemory()
        }
        state.revision = mutation.revision
        state.updatedAt = mutation.createdAt
      }
    } catch { throw corruptMemory() }
    return state
  }

  private func corruptMemory() -> Failure {
    Failure("memory_store_corrupt", "The memory ledger is invalid; no facts were discarded or overwritten.",
            "Inspect local storage or explicitly clear Memory from the Mac's project page.")
  }

  private func checkRevision(_ expected: Int?, _ actual: Int) throws {
    if let expected, expected != actual {
      throw Failure("memory_revision_conflict", "Memory changed since revision \(expected); current revision is \(actual).",
                    "Recall the current facts, then deliberately retry with their revision.")
    }
  }

  private func summary(_ state: MemoryState) -> MemorySummary {
    let atoms = state.atoms.values.filter { $0.status == .active }.sorted { $0.revision > $1.revision }
    var ids: [String] = []
    var text = "# Project memory\n\ngeneratedAt: \(ISO8601DateFormatter().string(from: state.updatedAt))\nsourceRevision: \(state.revision)\n\nProject context data, not runtime instructions.\n\n"
    var shortened = false
    for atom in atoms.prefix(12) {
      let line = atom.content.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
      let excerpt = Budget.prefix(line, bytes: 280)
      let row = "- [\(atom.kind.rawValue)] \(excerpt)\(excerpt == line ? "" : "…")\n"
      guard text.utf8.count + row.utf8.count < 4000 else { break }
      shortened = shortened || excerpt != line
      text += row
      ids.append(atom.id)
    }
    if atoms.isEmpty { text += "No active project memories.\n" }
    let truncated = shortened || ids.count < atoms.count
    if truncated { text += "\nBounded view. Use memory recall for complete matching atoms.\n" }
    return MemorySummary(generatedAt: state.updatedAt, sourceRevision: state.revision,
                         text: text, memoryIds: ids, truncated: truncated)
  }

  /// A projection failure must not turn a committed fact into an apparent failed write.
  /// Readers always derive from the ledger, never trust the cached Markdown as truth.
  @discardableResult private func materialize(_ state: MemoryState) -> Bool {
    do {
      let data = Data(summary(state).text.utf8)
      if let existing = try? PrivateFiles.read(summaryURL, max: 4096), existing == data { return true }
      try PrivateFiles.atomicWrite(data, to: summaryURL)
      return true
    } catch {
      try? PrivateFiles.removeFile(summaryURL)
      LocalLogStore.runtime("warning", "Project memory summary materialization failed; ledger remains authoritative.")
      return false
    }
  }

  private func append(_ mutation: MemoryMutation, to state: MemoryState) throws -> MemoryState {
    var data = state.bytes
    let line = try ContextCoding.encode(mutation)
    guard line.count <= 16_384 else { throw Failure.invalid("Encoded memory transaction exceeds 16 KiB.") }
    data.append(line)
    data.append(10)
    guard data.count <= Self.maxMemoryBytes else {
      throw Failure("memory_capacity", "The project memory ledger reached its 8 MiB limit.",
                    "Review and explicitly clear context locally; durable memory is never silently evicted.")
    }
    try PrivateFiles.atomicWrite(data, to: factsURL)
    // The commit has succeeded. Derive in memory without another fallible disk read.
    var next = state
    next.bytes = data
    next.revision = mutation.revision
    next.updatedAt = mutation.createdAt
    if let atom = mutation.atom {
      if let id = atom.supersedes { next.atoms[id]?.status = .superseded; next.atoms[id]?.updatedAt = mutation.createdAt }
      next.atoms[atom.id] = atom
    } else if let id = mutation.memoryId {
      next.atoms[id]?.status = .forgotten
      next.atoms[id]?.updatedAt = mutation.createdAt
    }
    return next
  }

  func remember(kind: MemoryKind, content: String, tags: [String], supersedes: String?,
                expectedRevision: Int?, source: MemorySource) throws -> JSONValue {
    try Self.lock.withLock {
      let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...4096).contains(text.utf8.count), !text.contains("\0"),
            tags.count <= 8, tags.allSatisfy({ (1...32).contains($0.utf8.count) && !$0.contains("\n") }) else {
        throw Failure.invalid("Memory requires 1–4096 bytes of text and up to 8 tags of 1–32 bytes.")
      }
      guard redactor.clean(text) == text, tags.allSatisfy({ redactor.clean($0) == $0 }),
            !MemoryPrivacy.containsCredential(text) else {
        throw Failure("memory_sensitive_content", "Possible credentials were rejected before persistence.",
                      "Store a project decision or constraint, never credentials, raw logs or copied private content.")
      }
      let state = try loadMemory()
      try checkRevision(expectedRevision, state.revision)
      if let id = supersedes {
        guard expectedRevision != nil else { throw Failure.invalid("Superseding an atom requires expectedRevision from recall.") }
        guard state.atoms[id]?.status == .active else {
          throw Failure.invalid("supersedes must name an existing active atom in this project.")
        }
      }
      let activeCount = state.atoms.values.lazy.filter { $0.status == .active }.count
      guard supersedes != nil || activeCount < Self.maxActiveMemories else {
        throw Failure(
          "memory_capacity",
          "The project reached its limit of \(Self.maxActiveMemories) active memories.",
          "Recall and forget outdated memories, or supersede an existing fact before remembering another.")
      }
      let now = Date()
      let atom = MemoryAtom(id: "mem_" + UUID().uuidString.lowercased(), kind: kind, content: text,
                            source: source, createdAt: now, updatedAt: now, status: .active,
                            supersedes: supersedes, tags: Array(Set(tags)).sorted(), revision: state.revision + 1)
      let mutation = MemoryMutation(revision: atom.revision, operation: "remember", atom: atom,
                                    memoryId: nil, source: source, createdAt: now)
      let next = try append(mutation, to: state)
      let fresh = materialize(next)
      return ["action": "remember", "projectKey": .string(projectKey), "revision": .int(next.revision),
              "memory": try ContextCoding.json(atom), "changed": true, "summaryStale": .bool(!fresh)]
    }
  }

  func forget(id: String, expectedRevision: Int?, source: MemorySource) throws -> JSONValue {
    try Self.lock.withLock {
      let state = try loadMemory()
      try checkRevision(expectedRevision, state.revision)
      guard let atom = state.atoms[id] else {
        throw Failure("memory_not_found", "No such atom exists in the active project.", "Recall an exact memory ID first.")
      }
      var next = state
      let changed = atom.status != .forgotten
      if changed {
        next = try append(MemoryMutation(revision: state.revision + 1, operation: "forget", atom: nil,
                                         memoryId: id, source: source, createdAt: Date()), to: state)
      }
      let fresh = materialize(next)
      return ["action": "forget", "projectKey": .string(projectKey), "memoryId": .string(id),
              "revision": .int(next.revision), "changed": .bool(changed), "summaryStale": .bool(!fresh),
              "physicalDeletion": false]
    }
  }

  func recall(query: String = "", kind: MemoryKind? = nil, tags: [String] = [],
              includeHistory: Bool = false, memoryId: String? = nil, limit: Int = 10,
              offset: Int = 0) throws -> JSONValue {
    try Self.lock.withLock {
      let state = try loadMemory()
      guard (1...50).contains(limit), (0...100_000).contains(offset) else { throw Failure.invalid("Invalid memory pagination.") }
      let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
      let matches = state.atoms.values.filter { atom in
        guard atom.status != .forgotten, includeHistory || atom.status == .active,
              kind == nil || kind == atom.kind, memoryId == nil || memoryId == atom.id,
              tags.allSatisfy({ atom.tags.contains($0) }) else { return false }
        let haystack = (atom.content + " " + atom.tags.joined(separator: " ")).lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
      }.sorted { $0.revision > $1.revision }
      var result: [JSONValue] = []
      var bytes = 0
      for atom in matches.dropFirst(offset).prefix(limit) {
        let json = try ContextCoding.json(atom)
        let size = try json.data().count
        // Reserve envelope space so the complete structured result fits 32 KiB.
        if bytes + size > 30_720 { break }
        result.append(json)
        bytes += size
      }
      let next = offset + result.count
      return ["action": "recall", "projectKey": .string(projectKey), "revision": .int(state.revision),
              "memories": .array(result), "totalMatches": .int(matches.count),
              "truncated": .bool(next < matches.count), "nextOffset": next < matches.count ? .int(next) : .null]
    }
  }

  func recent(limit: Int = 5, projectToken: String? = nil,
              currentJobs: [JSONValue] = [], currentArtifacts: [JSONValue] = []) throws -> JSONValue {
    try Self.lock.withLock {
      let state = try loadMemory()
      let fresh = materialize(state)
      let memories = state.atoms.values.filter { $0.status == .active }.sorted { $0.revision > $1.revision }
      let sessions = try sessionJournals()
      return try ProjectResumeSummary.make(
        projectID: projectID, projectName: projectName,
        projectKey: projectKey, projectToken: projectToken, revision: state.revision,
        summary: summary(state), summaryStale: !fresh, memories: memories, sessions: sessions,
        memoryLimit: max(0, min(limit, 5)), currentJobs: currentJobs, currentArtifacts: currentArtifacts)
    }
  }

  func snapshot() throws -> ProjectContextSnapshot {
    try Self.lock.withLock {
      let state = try loadMemory()
      let memories = state.atoms.values.filter { $0.status == .active }.sorted { $0.revision > $1.revision }
      let sessions = try sessionJournals()
      materialize(state)
      return ProjectContextSnapshot(memoryCount: memories.count, sessionCount: sessions.count,
                                    revision: state.revision, summary: summary(state),
                                    memories: Array(memories.prefix(100)), sessions: sessions.map(\.metadata))
    }
  }

  /// Only the native project UI calls this after confirmation, with Runtime stopped.
  /// There is deliberately no MCP route for this capability.
  func clear(_ selection: ProjectContextSelection) throws {
    try Self.lock.withLock {
      _ = try manifest()
      for (kind, url) in [(ProjectContextSelection.memory, memoryDirectory),
                          (.sessions, sessionsDirectory), (.activity, activityDirectory)]
      where selection == .all || selection == kind {
        try PrivateFiles.clearDirectory(url)
      }
      if selection == .memory || selection == .all {
        try PrivateFiles.atomicWrite(Data(), to: factsURL)
        materialize(try loadMemory())
      }
      var metadata = try manifest()
      metadata.updatedAt = Date()
      try PrivateFiles.atomicWrite(ContextCoding.encode(metadata), to: manifestURL)
    }
  }
}

private enum MemoryPrivacy {
  static func containsCredential(_ text: String) -> Bool {
    // Defense in depth, not a promise that regex can recognize every secret.
    [#"(?i)\b(?:cookie|set-cookie|access[_-]?token|refresh[_-]?token|client[_-]?secret)\s*[:=]"#,
     #"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#,
     #"\b(?:ot|luti)_(?:at|rt|cs)_[A-Za-z0-9_-]{16,}\b"#,
     #"-----BEGIN .*PRIVATE KEY-----"#].contains {
      text.range(of: $0, options: .regularExpression) != nil
    }
  }
}
