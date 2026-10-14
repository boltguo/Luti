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
    description: String = "Core module boundaries and storage layout",
    kind: MemoryKind = .architecture,
    content: String = "Use canonical paths for per-project storage.",
    host: String = "Test Host"
  ) throws -> JSONValue {
    try store.write(
      file: file, name: name, description: description,
      kind: kind, content: content, source: source(host))
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

  func testWriteOverwriteDeleteAndRestartSyncsMemoryIndexAndTopicMarkdownFiles() throws {
    let f = try Fixture(); defer { f.remove() }
    let s = try store(f)
    let created = try writeTopic(
      s, file: "architecture", name: "System Architecture",
      description: "Core module boundaries", kind: .architecture,
      content: "# Architecture\n\nUse one namespace per project.")
    XCTAssertEqual(created["created"], true)
    XCTAssertEqual(created["updated"], false)
    XCTAssertEqual(created["memory"]["file"], "architecture.md")
    XCTAssertTrue(created["indexMarkdown"].string!.contains("[architecture.md](architecture.md) — Core module boundaries"))

    let updated = try writeTopic(
      s, file: "architecture.md", name: "System Architecture",
      description: "Updated module boundaries", kind: .decision,
      content: "# Architecture\n\nUse MEMORY.md plus topic .md files.",
      host: "Second Host")
    XCTAssertEqual(updated["created"], false)
    XCTAssertEqual(updated["updated"], true)
    XCTAssertEqual(updated["fileCount"], 1)

    let readDoc = try s.read(file: "architecture.md")
    XCTAssertEqual(readDoc["memory"]["description"], "Updated module boundaries")
    XCTAssertEqual(readDoc["memory"]["kind"], "decision")
    XCTAssertEqual(readDoc["memory"]["source"]["host"], "Second Host")
    XCTAssertTrue(readDoc["memory"]["content"].string!.contains("Use MEMORY.md plus topic .md files."))

    let readIndex = try s.read(file: "MEMORY.md")
    XCTAssertEqual(readIndex["file"], "MEMORY.md")
    XCTAssertEqual(readIndex["fileCount"], 1)
    XCTAssertFalse(readIndex["content"].string!.contains("Core module boundaries"))
    XCTAssertTrue(readIndex["content"].string!.contains("Updated module boundaries"))

    let onDiskTopic = String(
      decoding: try PrivateFiles.read(s.memoryDirectory.appendingPathComponent("architecture.md"), max: 16_384),
      as: UTF8.self)
    XCTAssertTrue(onDiskTopic.contains("description: Updated module boundaries"))
    XCTAssertTrue(onDiskTopic.contains("Use MEMORY.md plus topic .md files."))

    let deleted = try s.delete(file: "architecture.md")
    XCTAssertEqual(deleted["deleted"], true)
    XCTAssertEqual(deleted["fileCount"], 0)

    let reopened = try store(f)
    XCTAssertEqual(try reopened.index()["fileCount"], 0)
    XCTAssertThrowsError(try reopened.read(file: "architecture.md")) {
      XCTAssertEqual(($0 as? Failure)?.code, "memory_not_found")
    }
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
    XCTAssertFalse(index["indexMarkdown"].string!.contains("INJECTED_CACHE_ONLY"))
    XCTAssertTrue(index["indexMarkdown"].string!.contains("[conventions.md](conventions.md)"))
    let diskIndex = String(decoding: try PrivateFiles.read(s.indexURL, max: 16_384), as: UTF8.self)
    XCTAssertFalse(diskIndex.contains("INJECTED_CACHE_ONLY"))
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
      s, file: "topic-0.md", description: "Updated decision 0", content: "Updated body 0")
    XCTAssertEqual(updated["updated"], true)
    XCTAssertEqual(try s.index()["fileCount"], .int(ProjectMemoryStore.maxTopicFiles))
  }

  func testRouterMemoryRequiresTokenForWriteAndDeleteAndAttributesSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router()
    addTeardownBlock { await router.stop() }
    let remote = ToolGrant.remote(
      RequestContext(
        transport: .cloudflare, clientID: "Writer Host",
        clientName: "Writer Host", authorizationID: UUID()))
    let missingToken = await router.call(
      "memory",
      arguments: [
        "action": "write", "file": "decisions.md",
        "description": "Needs token", "content": "Details",
      ],
      grant: remote)
    XCTAssertEqual(missingToken.data["error"], "project_binding_required")

    let write = await router.callInCurrentProject(
      "memory",
      arguments: [
        "action": "write", "file": "decisions.md",
        "description": "Shared project decision", "content": "Detailed decision markdown.",
      ],
      grant: remote)
    XCTAssertFalse(write.isError)
    XCTAssertEqual(write.data["memory"]["source"]["host"], "Writer Host")

    let read = await router.call(
      "memory", arguments: ["action": "read", "file": "decisions.md"], grant: .local)
    XCTAssertFalse(read.isError)
    XCTAssertEqual(read.data["memory"]["description"], "Shared project decision")

    for args: JSONValue in [
      ["action": "clear"], ["action": "purge"], ["action": "sessions"],
      ["action": "index", "projectId": "other"],
      ["action": "write", "file": "MEMORY.md", "description": "bad", "content": "bad"],
    ] {
      let output = await router.callInCurrentProject("memory", arguments: args)
      XCTAssertTrue(output.isError)
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
