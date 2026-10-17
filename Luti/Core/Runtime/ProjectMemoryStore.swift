import Foundation

enum ContextCoding {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
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
  /// Unfinished work another session can continue: goal plus a "- [ ]" checklist.
  case task
}

struct MemorySource: Codable, Sendable, Equatable {
  let type: String
  let host: String
  let clientId: String?
  let transport: String

  static func model(grant: ToolGrant, redactor: Redactor) -> MemorySource {
    MemorySource(
      type: "model",
      host: Budget.prefix(
        redactor.clean(grant.context?.clientName ?? "local-client")
          .components(separatedBy: .newlines).joined(separator: " "), bytes: 64),
      clientId: grant.context?.clientID,
      transport: grant.context?.transport.rawValue ?? "loopback")
  }
}

struct MemoryDocument: Codable, Sendable, Identifiable, Equatable {
  var id: String { file }
  let file: String
  let name: String
  let description: String
  let kind: MemoryKind
  let content: String
  let source: MemorySource
  let updatedAt: Date
  let bytes: Int
  let sha256: String

  var metadataJSON: JSONValue {
    [
      "file": .string(file),
      "name": .string(name),
      "description": .string(description),
      "kind": .string(kind.rawValue),
      "updatedAt": .string(ISO8601DateFormatter().string(from: updatedAt)),
      "bytes": .int(bytes),
      "sha256": .string(sha256),
      "source": [
        "type": .string(source.type),
        "host": .string(source.host),
        "clientId": source.clientId.map(JSONValue.string) ?? .null,
        "transport": .string(source.transport),
      ],
    ]
  }

  var fullJSON: JSONValue {
    metadataJSON.adding("content", .string(content))
  }
}

struct ProjectMemorySnapshot: Sendable {
  let indexMarkdown: String
  let documents: [MemoryDocument]
  var memoryCount: Int { documents.count }
}

/// Per-project memory shared by every connected client:
/// - `memory/<topic>.md` files each record one durable decision, convention or architecture note.
/// - `memory/MEMORY.md` is derived from the topic files and never written by clients.
/// Replacing or deleting a topic requires the SHA-256 the client last read, so
/// concurrent clients cannot silently overwrite each other.
final class ProjectMemoryStore: @unchecked Sendable {
  static let lock = NSRecursiveLock()
  static let indexFileName = "MEMORY.md"
  static let maxTopicFiles = 100
  static let maxTopicFileBytes = 16_384
  static let maxTotalBytes = 4 * 1_048_576

  let projectKey: String
  let sourcePath: String
  let directory: URL
  let memoryDirectory: URL
  let redactor: Redactor
  private let projectID: String
  private let projectName: String
  private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
  var indexURL: URL { memoryDirectory.appendingPathComponent(Self.indexFileName) }

  init(
    project: ApprovedProject, dataRoot: URL = LutiPaths.root,
    redactor: Redactor = Redactor(), validateMemory: Bool = true
  ) throws {
    sourcePath = LutiPaths.canonicalProjectURL(project.url).path
    projectKey = LutiPaths.projectKey(for: project.url)
    projectID = project.id
    projectName = Budget.prefix(redactor.clean(project.name), bytes: 128)
    directory = dataRoot.appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(projectKey, isDirectory: true)
    memoryDirectory = directory.appendingPathComponent("memory", isDirectory: true)
    self.redactor = redactor
    try Self.lock.withLock {
      for url in [dataRoot, dataRoot.appendingPathComponent("projects"), directory, memoryDirectory] {
        try PrivateFiles.directory(url)
      }
      if try PrivateFiles.exists(manifestURL) {
        _ = try manifest()
      } else {
        let now = Date()
        let value = ProjectManifest(
          sourcePath: sourcePath, projectKey: projectKey,
          projectName: projectName, createdAt: now, updatedAt: now)
        try PrivateFiles.atomicWrite(ContextCoding.encode(value), to: manifestURL)
      }
      if validateMemory {
        let docs = try loadDocuments()
        materializeIndex(docs)
      }
    }
  }

  private func manifest() throws -> ProjectManifest {
    let value = try ContextCoding.decode(ProjectManifest.self, PrivateFiles.read(manifestURL, max: 16_384))
    guard value.schemaVersion == 1, value.identityScheme == "canonical-path-sha256-v1",
          value.sourcePath == sourcePath, value.projectKey == projectKey else {
      throw Failure(
        "context_identity_mismatch", "Project context does not match its canonical path or schema.",
        "Inspect the local project context; do not merge or overwrite another project's data.")
    }
    return value
  }

  static func normalizeTopicFileName(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else {
      throw Failure.invalid("Memory file name must be a single file name inside memory/.")
    }
    let withExtension = trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    guard withExtension.lowercased() != indexFileName.lowercased() else {
      throw Failure.invalid("MEMORY.md is generated from topic files; use memory_query(action=index) to list them and name a topic .md file.")
    }
    let stem = String(withExtension.dropLast(3))
    guard !stem.isEmpty,
          (1...64).contains(withExtension.utf8.count),
          !stem.contains(".."),
          let first = stem.unicodeScalars.first,
          CharacterSet.alphanumerics.contains(first),
          stem.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
          }) else {
      throw Failure.invalid("Memory file name must use ASCII letters, digits, '-', '_' or '.' and end with .md.")
    }
    return stem.lowercased() + ".md"
  }

  private static func defaultName(for file: String) -> String {
    let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    return stem
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  private static func encodeMarkdown(
    name: String, description: String, kind: MemoryKind,
    source: MemorySource, updatedAt: Date, content: String
  ) -> Data {
    let timestamp = ISO8601DateFormatter().string(from: updatedAt)
    var lines = [
      "---",
      "name: \(name)",
      "description: \(description)",
      "kind: \(kind.rawValue)",
      "host: \(source.host)",
    ]
    if let clientId = source.clientId, !clientId.isEmpty {
      lines.append("clientId: \(clientId)")
    }
    lines.append("transport: \(source.transport)")
    lines.append("updatedAt: \(timestamp)")
    lines.append("---")
    lines.append("")
    lines.append(content)
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
  }

  private func decodeDocument(file: String, data: Data, fallbackDate: Date = Date()) throws -> MemoryDocument {
    guard let text = String(data: data, encoding: .utf8) else {
      throw corruptMemory()
    }
    if text.hasPrefix("---\n"), let closeRange = text.dropFirst(4).range(of: "\n---\n") {
      let afterOpen = text.dropFirst(4)
      let headerBlock = afterOpen[..<closeRange.lowerBound]
      var body = String(afterOpen[closeRange.upperBound...])
      if body.hasPrefix("\n") { body.removeFirst() }
      if body.hasSuffix("\n") { body.removeLast() }

      var fields: [String: String] = [:]
      for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, fields[key] == nil { fields[key] = value }
      }

      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedBody.isEmpty, trimmedBody.utf8.count <= Self.maxTopicFileBytes else {
        throw corruptMemory()
      }
      let name = Budget.prefix(fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultName(for: file), bytes: 120)
      let fallbackDesc = trimmedBody.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
      let description = Budget.prefix(fields["description"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackDesc, bytes: 240)
      let kind = fields["kind"].flatMap(MemoryKind.init(rawValue:)) ?? .decision
      let host = fields["host"].flatMap { $0.isEmpty ? nil : $0 } ?? "local-client"
      let transport = fields["transport"].flatMap { $0.isEmpty ? nil : $0 } ?? "loopback"
      let updatedAt = fields["updatedAt"].flatMap { ISO8601DateFormatter().date(from: $0) } ?? fallbackDate

      return MemoryDocument(
        file: file,
        name: name,
        description: description,
        kind: kind,
        content: trimmedBody,
        source: MemorySource(
          type: "model",
          host: host,
          clientId: fields["clientId"],
          transport: transport),
        updatedAt: updatedAt,
        bytes: data.count,
        sha256: Budget.sha256(data))
    }

    let trimmedBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty, trimmedBody.utf8.count <= Self.maxTopicFileBytes else {
      throw corruptMemory()
    }
    let lines = trimmedBody.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    let heading = lines.first(where: { $0.hasPrefix("#") })?
      .drop(while: { $0 == "#" || $0 == " " })
    let name = Budget.prefix(
      heading.flatMap { $0.isEmpty ? nil : String($0) } ?? Self.defaultName(for: file),
      bytes: 120)
    let summaryLine = lines.first(where: { !$0.hasPrefix("#") }) ?? name
    let description = Budget.prefix(summaryLine, bytes: 240)
    return MemoryDocument(
      file: file,
      name: name,
      description: description,
      kind: .decision,
      content: trimmedBody,
      source: MemorySource(type: "model", host: "local-client", clientId: nil, transport: "loopback"),
      updatedAt: fallbackDate,
      bytes: data.count,
      sha256: Budget.sha256(data))
  }

  private func corruptMemory() -> Failure {
    Failure(
      "memory_store_corrupt",
      "A project memory markdown file is invalid; no memory files were discarded or overwritten.",
      "Inspect local memory files or clear Memory from the Mac's project page.")
  }

  private func loadDocuments() throws -> [MemoryDocument] {
    _ = try manifest()
    let names = try FileManager.default.contentsOfDirectory(atPath: memoryDirectory.path)
      .filter { !$0.hasPrefix(".") && $0 != Self.indexFileName }
      .sorted()
    var documents: [MemoryDocument] = []
    var totalBytes = 0
    for name in names {
      let url = memoryDirectory.appendingPathComponent(name)
      if name == "facts.jsonl" {
        try? PrivateFiles.removeFile(url)
        continue
      }
      guard name.hasSuffix(".md"),
            let normalized = try? Self.normalizeTopicFileName(name),
            normalized == name else {
        continue
      }
      let data = try PrivateFiles.read(url, max: Self.maxTopicFileBytes + 1024)
      if name == "project.md",
         let text = String(data: data, encoding: .utf8),
         text.hasPrefix("# Project memory\n\ngeneratedAt:") {
        try? PrivateFiles.removeFile(url)
        continue
      }
      totalBytes += data.count
      guard totalBytes <= Self.maxTotalBytes else {
        throw Failure(
          "memory_capacity", "Project memory exceeded its 4 MiB total storage limit.",
          "Delete outdated topic files or clear project memory locally.")
      }
      let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
      if let doc = try? decodeDocument(file: name, data: data, fallbackDate: modifiedAt) {
        documents.append(doc)
      }
    }
    return documents.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.file < $1.file
    }
  }

  private func renderIndexMarkdown(_ documents: [MemoryDocument]) -> String {
    var lines = [
      "# MEMORY.md",
      "",
      "Project memory index for \(projectName). Read full details with `memory_query(action=\"read\", file=\"<file>\")`.",
      "",
    ]
    if documents.isEmpty {
      lines.append("No project memory files recorded yet.")
    } else {
      for doc in documents {
        let row = "- [\(doc.file)](\(doc.file)) — \(doc.description) (`\(doc.kind.rawValue)`)"
        lines.append(row)
      }
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  @discardableResult
  private func materializeIndex(_ documents: [MemoryDocument]) -> String {
    let text = renderIndexMarkdown(documents)
    let data = Data(text.utf8)
    do {
      if let existing = try? PrivateFiles.read(indexURL, max: 65_536), existing == data {
        return text
      }
      try PrivateFiles.atomicWrite(data, to: indexURL)
    } catch {
      try? PrivateFiles.removeFile(indexURL)
      LocalLogStore.runtime("warning", "MEMORY.md index materialization failed.")
    }
    return text
  }

  private func touchManifest() throws {
    var metadata = try manifest()
    metadata.updatedAt = Date()
    try PrivateFiles.atomicWrite(ContextCoding.encode(metadata), to: manifestURL)
  }

  /// Compact listing for `project_info`, so every client sees existing memory
  /// without an extra call.
  /// "done/total" for markdown checklist items, or nil when there are none.
  static func checklistProgress(_ content: String) -> String? {
    var done = 0, total = 0
    for line in content.split(separator: "\n") {
      let item = line.drop(while: { $0 == " " || $0 == "\t" })
      guard item.hasPrefix("- [") || item.hasPrefix("* [") else { continue }
      let mark = item.dropFirst(3).prefix(2)
      if mark == "x]" || mark == "X]" { done += 1; total += 1 } else if mark == " ]" { total += 1 }
    }
    return total == 0 ? nil : "\(done)/\(total)"
  }

  func summary() throws -> JSONValue {
    try Self.lock.withLock {
      let docs = try loadDocuments()
      return [
        "fileCount": .int(docs.count),
        "files": .array(docs.map { doc -> JSONValue in
          var row: JSONValue = [
            "file": .string(doc.file), "description": .string(doc.description),
            "kind": .string(doc.kind.rawValue),
            "updatedAt": .string(ISO8601DateFormatter().string(from: doc.updatedAt)),
            "updatedBy": .string(doc.source.host),
          ]
          if doc.kind == .task, let progress = Self.checklistProgress(doc.content) {
            row = row.adding("progress", .string(progress))
          }
          return row
        }),
      ]
    }
  }

  func index(
    query: String = "", kind: MemoryKind? = nil
  ) throws -> JSONValue {
    try Self.lock.withLock {
      let allDocs = try loadDocuments()
      materializeIndex(allDocs)
      let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
      let matches = allDocs.filter { doc in
        guard kind == nil || doc.kind == kind else { return false }
        guard !tokens.isEmpty else { return true }
        let haystack = [doc.file, doc.name, doc.description, doc.kind.rawValue, doc.content]
          .joined(separator: "\n")
          .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
      }
      return [
        "action": "index",
        "project": ["id": .string(projectID), "name": .string(projectName)],
        "fileCount": .int(allDocs.count),
        "totalMatches": .int(matches.count),
        "files": .array(matches.map(\.metadataJSON)),
      ]
    }
  }

  func read(file rawFile: String) throws -> JSONValue {
    try Self.lock.withLock {
      let target = try Self.normalizeTopicFileName(rawFile)
      guard let doc = try loadDocuments().first(where: { $0.file == target }) else {
        throw notFound(target)
      }
      return ["action": "read", "memory": doc.fullJSON]
    }
  }

  /// Creates a topic when `expectedSHA256` is nil and never overwrites one;
  /// otherwise replaces the body only if the file still has that SHA-256.
  /// Omitted name, description and kind keep the stored values on replace.
  func write(
    file rawFile: String, name rawName: String? = nil, description rawDescription: String? = nil,
    kind rawKind: MemoryKind? = nil, content rawContent: String, expectedSHA256: String? = nil,
    source: MemorySource
  ) throws -> JSONValue {
    try Self.lock.withLock {
      let file = try Self.normalizeTopicFileName(rawFile)
      let docs = try loadDocuments()
      let current = try currentData(file)
      let previous = docs.first { $0.file == file }
      switch (current, expectedSHA256) {
      case (nil, nil):
        guard docs.count < Self.maxTopicFiles else {
          throw Failure(
            "memory_capacity",
            "The project reached its limit of \(Self.maxTopicFiles) memory .md files.",
            "Merge into or delete outdated topic files first.")
        }
      case (nil, _?):
        throw notFound(file)
      case (_?, nil):
        throw Failure(
          "memory_conflict", "memory/\(file) already exists; nothing was written.",
          "Read it with memory_query(action=read), merge your change into its content, then write the complete body with its sha256 as expectedSHA256.")
      case let (data?, expected?):
        guard Budget.sha256(data) == expected else { throw changed(file, effect: "written") }
        guard previous != nil else { throw corruptMemory() }
      }

      func line(_ value: String?) -> String? {
        value.map {
          $0.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        }.flatMap { $0.isEmpty ? nil : $0 }
      }
      let name = line(rawName) ?? previous?.name ?? Self.defaultName(for: file)
      guard let description = line(rawDescription) ?? previous?.description else {
        throw Failure.invalid("Creating a memory file requires a one-line description for MEMORY.md.")
      }
      let kind = rawKind ?? previous?.kind ?? .decision
      let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)

      guard (1...120).contains(name.utf8.count), !name.contains("\0"),
            (1...240).contains(description.utf8.count), !description.contains("\0"),
            (1...Self.maxTopicFileBytes).contains(content.utf8.count), !content.contains("\0") else {
        throw Failure.invalid(
          "Memory write requires name (1–120B), one-line description (1–240B) and markdown content (1–16384B).")
      }
      for field in [name, description, content] {
        guard redactor.clean(field) == field, !MemoryPrivacy.containsCredential(field) else {
          throw Failure(
            "memory_sensitive_content", "Possible credentials were rejected before persistence.",
            "Store architectural decisions, conventions or project notes—never credentials or secrets.")
        }
      }

      let encoded = Self.encodeMarkdown(
        name: name, description: description, kind: kind,
        source: source, updatedAt: Date(), content: content)
      try PrivateFiles.atomicWrite(encoded, to: memoryDirectory.appendingPathComponent(file))
      try touchManifest()

      let updatedDocs = try loadDocuments()
      materializeIndex(updatedDocs)
      guard let saved = updatedDocs.first(where: { $0.file == file }) else {
        throw corruptMemory()
      }
      return [
        "action": "write",
        "created": .bool(previous == nil),
        "updated": .bool(previous != nil),
        "memory": saved.metadataJSON,
        "fileCount": .int(updatedDocs.count),
      ]
    }
  }

  func delete(file rawFile: String, expectedSHA256: String) throws -> JSONValue {
    try Self.lock.withLock {
      let file = try Self.normalizeTopicFileName(rawFile)
      guard let data = try currentData(file) else { throw notFound(file) }
      guard Budget.sha256(data) == expectedSHA256 else { throw changed(file, effect: "deleted") }
      try PrivateFiles.removeFile(memoryDirectory.appendingPathComponent(file))
      try touchManifest()
      let remaining = try loadDocuments()
      materializeIndex(remaining)
      return [
        "action": "delete",
        "file": .string(file),
        "deleted": true,
        "fileCount": .int(remaining.count),
      ]
    }
  }

  /// On-disk bytes, including files that failed to decode, so a client can
  /// never replace a topic it could not read.
  private func currentData(_ file: String) throws -> Data? {
    let url = memoryDirectory.appendingPathComponent(file)
    return try PrivateFiles.exists(url) ? PrivateFiles.read(url, max: Self.maxTopicFileBytes + 1024) : nil
  }

  private func notFound(_ file: String) -> Failure {
    Failure(
      "memory_not_found", "No memory file named \(file) exists in this project.",
      "Call memory_query(action=index) to list current files; omit expectedSHA256 to create a new one.")
  }

  private func changed(_ file: String, effect: String) -> Failure {
    Failure(
      "memory_conflict", "memory/\(file) changed since it was read; nothing was \(effect).",
      "Read it again with memory_query(action=read), merge your change into the current content, then retry with its new sha256.")
  }

  func snapshot() throws -> ProjectMemorySnapshot {
    try Self.lock.withLock {
      let docs = try loadDocuments()
      let indexMarkdown = materializeIndex(docs)
      return ProjectMemorySnapshot(indexMarkdown: indexMarkdown, documents: docs)
    }
  }

  /// Only the native project UI calls this after confirmation, with Runtime stopped.
  func clear() throws {
    try Self.lock.withLock {
      _ = try manifest()
      try PrivateFiles.clearDirectory(memoryDirectory)
      materializeIndex([])
      try touchManifest()
    }
  }
}

private enum MemoryPrivacy {
  static func containsCredential(_ text: String) -> Bool {
    [
      #"(?i)\b(?:cookie|set-cookie|access[_-]?token|refresh[_-]?token|client[_-]?secret)\s*[:=]"#,
      #"\beyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b"#,
      #"\b(?:ot|luti)_(?:at|rt|cs)_[A-Za-z0-9_-]{16,}\b"#,
      #"-----BEGIN .*PRIVATE KEY-----"#,
    ].contains {
      text.range(of: $0, options: .regularExpression) != nil
    }
  }
}
