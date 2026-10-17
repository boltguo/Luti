import XCTest
@testable import Luti

@MainActor final class ProjectMemoryTests: XCTestCase {
  private func store(_ f: Fixture, project: ApprovedProject? = nil) throws -> ProjectMemoryStore {
    try ProjectMemoryStore(
      project: project ?? ApprovedProject(url: f.root),
      dataRoot: f.contextDataRoot)
  }

  private func source(_ host: String = "Test Host") -> MemorySource {
    MemorySource(type: "model", host: host, clientId: "test-client", transport: "loopback")
  }

  @discardableResult
  private func writeTopic(
    _ store: ProjectMemoryStore,
    file: String = "architecture.md",
    name: String? = "Architecture",
    description: String? = "Core module boundaries and storage layout",
    kind: MemoryKind? = .architecture,
    content: String = "Use canonical paths for per-project storage.",
    expectedSHA256: String? = nil,
    host: String = "Test Host"
  ) throws -> JSONValue {
    try store.write(
      file: file, name: name, description: description, kind: kind,
      content: content, expectedSHA256: expectedSHA256, source: source(host))
  }

  private func sha(_ store: ProjectMemoryStore, _ file: String) throws -> String {
    try XCTUnwrap(store.read(file: file)["memory"]["sha256"].string)
  }

  private func assertConflict(_ expression: @autoclosure () throws -> JSONValue, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_conflict", file: file, line: line)
    }
  }

  func testReapprovalUsesSameNamespaceAndDifferentProjectIsIsolated() throws {
    let f = try Fixture(), other = try Fixture()
    defer { f.remove(); other.remove() }
    let first = try store(f, project: ApprovedProject(id: "first", url: f.root))
    try writeTopic(first)
    let reapproved = try store(f, project: ApprovedProject(id: "new-approval", url: f.root))
    XCTAssertEqual(first.directory, reapproved.directory)
    XCTAssertEqual(try reapproved.index()["fileCount"], 1)
    let independent = try ProjectMemoryStore(
      project: ApprovedProject(url: other.root), dataRoot: f.contextDataRoot)
    XCTAssertEqual(try independent.index()["fileCount"], 0)
    XCTAssertNotEqual(first.directory, independent.directory)
  }

  func testCreateReplaceDeleteAndRestartKeepIndexAndTopicFilesInSync() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let created = try writeTopic(
      s, file: "Architecture", name: "System Architecture",
      description: "Core module boundaries", kind: .architecture,
      content: "# Architecture\n\nUse one namespace per project.")
    XCTAssertEqual(created["created"], true)
    XCTAssertEqual(created["memory"]["file"], "architecture.md")
    XCTAssertEqual(created["memory"]["content"], .null, "Writes return metadata, not an echo of the body.")
    let firstSHA = try XCTUnwrap(created["memory"]["sha256"].string)
    XCTAssertEqual(try sha(s, "architecture.md"), firstSHA)

    let replaced = try writeTopic(
      s, file: "architecture.md", name: nil, description: nil, kind: nil,
      content: "# Architecture\n\nUse MEMORY.md plus topic .md files.",
      expectedSHA256: firstSHA, host: "Second Host")
    XCTAssertEqual(replaced["updated"], true)
    XCTAssertEqual(replaced["fileCount"], 1)
    XCTAssertNotEqual(replaced["memory"]["sha256"].string, firstSHA)

    let doc = try s.read(file: "architecture.md")["memory"]
    XCTAssertEqual(doc["name"], "System Architecture", "Omitted metadata keeps stored values.")
    XCTAssertEqual(doc["description"], "Core module boundaries")
    XCTAssertEqual(doc["kind"], "architecture")
    XCTAssertEqual(doc["source"]["host"], "Second Host")
    XCTAssertEqual(doc["content"], "# Architecture\n\nUse MEMORY.md plus topic .md files.")

    let diskIndex = String(decoding: try PrivateFiles.read(s.indexURL, max: 16_384), as: UTF8.self)
    XCTAssertTrue(diskIndex.contains("[architecture.md](architecture.md) — Core module boundaries"))
    XCTAssertThrowsError(try s.read(file: "MEMORY.md"))

    assertConflict(try s.delete(file: "architecture.md", expectedSHA256: firstSHA))
    let deleted = try s.delete(file: "architecture.md", expectedSHA256: try sha(s, "architecture.md"))
    XCTAssertEqual(deleted["deleted"], true)
    XCTAssertEqual(deleted["fileCount"], 0)

    let reopened = try store(f)
    XCTAssertEqual(try reopened.index()["fileCount"], 0)
    XCTAssertThrowsError(try reopened.read(file: "architecture.md")) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_not_found")
    }
  }

  func testWritesNeverOverwriteWithoutTheCurrentSHA() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try writeTopic(s, content: "Original body")
    let original = try sha(s, "architecture.md")

    assertConflict(try writeTopic(s, content: "Blind create"))
    assertConflict(try writeTopic(s, content: "Stale", expectedSHA256: String(repeating: "0", count: 64)))
    XCTAssertThrowsError(try writeTopic(s, file: "missing.md", expectedSHA256: original)) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_not_found")
    }
    XCTAssertEqual(try s.read(file: "architecture.md")["memory"]["content"], "Original body")
    XCTAssertEqual(try sha(s, "architecture.md"), original)
  }

  func testConcurrentReplacementsOfOneFileLoseNoUpdate() async throws {
    let f = try Fixture(); defer { f.remove() }
    let a = try store(f), b = try store(f)
    try writeTopic(a, content: "Base")
    let base = try sha(a, "architecture.md")
    let author = source()
    let succeeded = try await withThrowingTaskGroup(of: Bool.self) { group in
      for i in 0..<8 {
        group.addTask {
          do {
            _ = try (i.isMultiple(of: 2) ? a : b).write(
              file: "architecture.md", content: "Writer \(i)", expectedSHA256: base, source: author)
            return true
          } catch let failure as Failure where failure.code == "memory_conflict" {
            return false
          }
        }
      }
      var count = 0
      for try await won in group where won { count += 1 }
      return count
    }
    XCTAssertEqual(succeeded, 1, "Exactly one writer may replace the version it read.")
  }

  func testIndexIsDerivedFromTopicMarkdownFilesAndOverwritesTamperedIndexFile() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try writeTopic(
      s, file: "conventions.md", name: "Conventions",
      description: "Swift formatting and commit conventions",
      kind: .convention, content: "Follow Conventional Commits.")
    try PrivateFiles.atomicWrite(Data("INJECTED_CACHE_ONLY".utf8), to: s.indexURL)
    let index = try s.index()
    XCTAssertEqual(index["files"].array?.first?["file"], "conventions.md")
    XCTAssertEqual(index["indexMarkdown"], .null)
    let diskIndex = String(decoding: try PrivateFiles.read(s.indexURL, max: 16_384), as: UTF8.self)
    XCTAssertFalse(diskIndex.contains("INJECTED_CACHE_ONLY"))
    XCTAssertTrue(diskIndex.contains("[conventions.md](conventions.md)"))
  }

  func testConcurrentWritersDoNotLoseTopicFiles() async throws {
    let f = try Fixture(); defer { f.remove() }
    let a = try store(f), b = try store(f)
    let author = source()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<12 {
        group.addTask {
          _ = try (i.isMultiple(of: 2) ? a : b).write(
            file: "topic-\(i).md",
            name: "Topic \(i)",
            description: "Decision summary \(i)",
            kind: .decision,
            content: "Detailed markdown for topic \(i).",
            source: author)
        }
      }
      try await group.waitForAll()
    }
    let result = try a.index()
    XCTAssertEqual(result["fileCount"], 12)
    XCTAssertEqual(result["totalMatches"], 12)
  }

  func testIndexQueryAndKindFiltering() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try writeTopic(
      s, file: "cloudflare-tunnel.md", name: "Cloudflare Tunnel",
      description: "Zero Trust tunnel setup", kind: .architecture,
      content: "Use cloudflared service token.")
    try writeTopic(
      s, file: "git-commits.md", name: "Git Commits",
      description: "Conventional commit rules", kind: .convention,
      content: "Use feat/fix/refactor prefixes.")
    XCTAssertEqual(try s.index(query: "cloudflared")["totalMatches"], 1)
    XCTAssertEqual(try s.index(kind: .convention)["totalMatches"], 1)
    XCTAssertEqual(try s.index(query: "nonexistent")["totalMatches"], 0)
  }

  func testSensitiveContentAndInvalidFileNamesAreRejectedBeforeWrite() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for text in [
      "access_token=synthetic-test-value",
      "Cookie: fixture_only",
      String(repeating: "x", count: ProjectMemoryStore.maxTopicFileBytes + 1),
    ] {
      XCTAssertThrowsError(try writeTopic(s, content: text))
    }
    for badFile in ["MEMORY.md", "../escape.md", "nested/file.md", ".hidden.md", ""] {
      XCTAssertThrowsError(try writeTopic(s, file: badFile))
    }
    XCTAssertThrowsError(try writeTopic(s, description: nil), "Creating requires an index description.")
    XCTAssertEqual(try s.index()["fileCount"], 0)
    let known = try ProjectMemoryStore(
      project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot,
      redactor: Redactor(known: ["fixture-known-private-marker"]))
    XCTAssertThrowsError(try writeTopic(known, content: "Do not store fixture-known-private-marker"))
    XCTAssertEqual(try s.index()["fileCount"], 0)
  }

  func testTopicFileCapacityRejectsNewFilesButAllowsUpdatingExistingFile() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    for index in 0..<ProjectMemoryStore.maxTopicFiles {
      try writeTopic(s, file: "topic-\(index).md", description: "Decision \(index)", content: "Body \(index)")
    }
    XCTAssertEqual(try s.index()["fileCount"], .int(ProjectMemoryStore.maxTopicFiles))
    XCTAssertThrowsError(try writeTopic(s, file: "overflow.md")) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_capacity")
    }
    let updated = try writeTopic(
      s, file: "topic-0.md", description: "Updated decision 0", content: "Updated body 0",
      expectedSHA256: try sha(s, "topic-0.md"))
    XCTAssertEqual(updated["updated"], true)
    XCTAssertEqual(try s.index()["fileCount"], .int(ProjectMemoryStore.maxTopicFiles))
  }

  func testRouterSplitsReadAndWriteAndAttributesSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    let query = try XCTUnwrap(ToolCatalog.definitions.first { $0["name"] == "memory_query" })
    let action = try XCTUnwrap(ToolCatalog.definitions.first { $0["name"] == "memory_action" })
    XCTAssertEqual(query["annotations"]["readOnlyHint"], true)
    XCTAssertEqual(action["annotations"]["readOnlyHint"], false)
    XCTAssertFalse(ToolCatalog.names.contains("memory"))

    let remote = ToolGrant.remote(
      RequestContext(
        transport: .cloudflare, clientID: "Writer Host",
        clientName: "Writer\nHost", authorizationID: UUID()))
    let create: JSONValue = [
      "action": "write", "file": "decisions.md",
      "description": "Shared project decision", "content": "Detailed decision markdown.",
    ]
    let missingToken = await router.call("memory_action", arguments: create, grant: remote)
    XCTAssertEqual(missingToken.data["error"], "project_binding_required")

    let write = await router.callInCurrentProject("memory_action", arguments: create, grant: remote)
    XCTAssertFalse(write.isError)
    XCTAssertEqual(write.data["memory"]["source"]["host"], "Writer Host")

    let info = await router.call("project_info", arguments: [:])
    XCTAssertEqual(info.data["memory"]["fileCount"], 1)
    XCTAssertEqual(info.data["memory"]["files"].array?.first?["file"], "decisions.md")
    XCTAssertEqual(info.data["memory"]["files"].array?.first?["description"], "Shared project decision")

    let read = await router.call(
      "memory_query", arguments: ["action": "read", "file": "decisions.md"], grant: .local)
    XCTAssertFalse(read.isError)
    let sha = try XCTUnwrap(read.data["memory"]["sha256"].string)

    let blind = await router.callInCurrentProject("memory_action", arguments: create)
    XCTAssertEqual(blind.data["error"], "memory_conflict")
    let replace = await router.callInCurrentProject("memory_action", arguments: [
      "action": "write", "file": "decisions.md", "content": "Merged decision markdown.",
      "expectedSHA256": .string(sha),
    ])
    XCTAssertEqual(replace.data["updated"], true)
    let staleDelete = await router.callInCurrentProject("memory_action", arguments: [
      "action": "delete", "file": "decisions.md", "expectedSHA256": .string(sha),
    ])
    XCTAssertEqual(staleDelete.data["error"], "memory_conflict")

    let invalid: [(String, JSONValue)] = [
      ("memory_query", ["action": "write", "file": "x.md", "content": "bad"]),
      ("memory_query", ["action": "index", "projectId": "other"]),
      ("memory_action", ["action": "index"]),
      ("memory_action", ["action": "clear"]),
      ("memory_action", ["action": "delete", "file": "decisions.md"]),
      ("memory_action", ["action": "write", "file": "MEMORY.md", "description": "bad", "content": "bad"]),
      ("memory_action", ["action": "write", "file": "x.md", "content": "bad", "expectedSHA256": "short"]),
    ]
    for (name, args) in invalid {
      let output = await router.callInCurrentProject(name, arguments: args)
      XCTAssertTrue(output.isError, "\(name): \(args)")
    }
  }

  func testMemoryClearIsScopedAndBlockedWhileRuntimeActive() async throws {
    let f = try Fixture(), other = try Fixture()
    defer { f.remove(); other.remove() }
    try writeTopic(try store(f), file: "own.md", content: "Own project memory")
    try writeTopic(
      try ProjectMemoryStore(project: ApprovedProject(url: other.root), dataRoot: f.contextDataRoot),
      file: "peer.md", content: "Peer project memory")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    let selected = try XCTUnwrap(model.activeProject)
    model.phase = .running
    do {
      try await model.clearProjectMemory(selected)
      XCTFail("Running memory cannot be cleared")
    } catch {}
    XCTAssertEqual(try store(f).index()["fileCount"], 1)
    model.phase = .stopped
    try await model.clearProjectMemory(selected)
    XCTAssertEqual(try store(f).index()["fileCount"], 0)
    XCTAssertEqual(
      try ProjectMemoryStore(project: ApprovedProject(url: other.root), dataRoot: f.contextDataRoot)
        .index()["fileCount"], 1)
  }

  func testLegacyFactsAndPlainMarkdownFilesLoadWithoutError() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    try PrivateFiles.atomicWrite(Data("{\"revision\":1}\n".utf8), to: s.memoryDirectory.appendingPathComponent("facts.jsonl"))
    try PrivateFiles.atomicWrite(
      Data("# Project memory\n\ngeneratedAt: 2026-10-14T00:00:00Z\nsourceRevision: 1\n".utf8),
      to: s.memoryDirectory.appendingPathComponent("project.md"))
    try PrivateFiles.atomicWrite(
      Data("# Notes\n\nPlain markdown without YAML frontmatter.\n".utf8),
      to: s.memoryDirectory.appendingPathComponent("notes.md"))

    let reopened = try store(f)
    let index = try reopened.index()
    XCTAssertEqual(index["fileCount"], 1)
    XCTAssertEqual(index["files"].array?.first?["file"], "notes.md")
    XCTAssertEqual(index["files"].array?.first?["name"], "Notes")
    XCTAssertEqual(index["files"].array?.first?["description"], "Plain markdown without YAML frontmatter.")
  }
}
