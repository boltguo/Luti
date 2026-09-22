import XCTest

@testable import Luti

@MainActor final class WorkspaceTests: XCTestCase {
  func testPaths() throws {
    for path in [
      "../x", "/etc/passwd", "a/../../x", "a//b", "a/./b", "~/.ssh", "a\\b", ".env",
      "a/.env.production", "x.PEM", "a/secrets/data", ".git/config", "id_ed25519",
    ] {
      XCTAssertThrowsError(try WorkspaceFiles.components(path), path)
    }
    XCTAssertEqual(try WorkspaceFiles.components("src/main.swift"), ["src", "main.swift"])
  }
  func testBatchAndRanges() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a.txt", "one\ntwo\nthree")
    try f.write("b.txt", "你好")
    let result = try await f.files.readFiles(paths: ["a.txt", "b.txt"], startLine: 2, endLine: 3)
    XCTAssertEqual(result["files"].array?.count, 2)
    XCTAssertEqual(result["files"].array?[0]["content"].string, "two\nthree")
    XCTAssertEqual(result["files"].array?[0]["complete"], true)
    XCTAssertEqual(result["successCount"], 2)
    XCTAssertEqual(result["failureCount"], 0)
    XCTAssertEqual(result["partial"], false)

    let partial = try await f.files.readFiles(paths: ["a.txt", "missing.txt"])
    XCTAssertEqual(partial["successCount"], 1)
    XCTAssertEqual(partial["failureCount"], 1)
    XCTAssertEqual(partial["partial"], true)
  }
  func testSymlinksAndHardlinks() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("source", "safe")
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("link"),
      withDestinationURL: f.root.appendingPathComponent("source"))
    try FileManager.default.linkItem(
      at: f.root.appendingPathComponent("source"), to: f.root.appendingPathComponent("hard"))
    let output = try await f.files.readFiles(paths: ["link", "hard"])
    XCTAssertEqual(output["files"].array?[0]["failure"]["error"].string, "path_outside_workspace")
    XCTAssertEqual(output["files"].array?[1]["failure"]["error"].string, "unsupported_file")
  }
  func testDirectorySymlinkEscape() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("escape"),
      withDestinationURL: f.root.deletingLastPathComponent())
    do {
      _ = try await f.files.workingDirectory("escape")
      XCTFail("Escape")
    } catch let e as Failure { XCTAssertEqual(e.code, "path_outside_workspace") }
  }
  func testExactEditAndSHA() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("source", "let x = 1\r\nlet y = 2\r\n")
    let source = try await f.files.text("source")
    let edit = TextEdit(oldText: "let x = 1", newText: "let x = 9")
    _ = try await f.files.edit(
      path: "source", expectedSHA: source.sha256, edits: [edit], dryRun: true)
    let dry = try await f.files.text("source")
    XCTAssertEqual(dry.text, source.text)
    _ = try await f.files.edit(path: "source", expectedSHA: source.sha256, edits: [edit])
    let changed = try await f.files.text("source")
    XCTAssertEqual(changed.text, "let x = 9\r\nlet y = 2\r\n")
    do {
      _ = try await f.files.edit(path: "source", expectedSHA: source.sha256, edits: [edit])
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "sha_conflict") }
  }
  func testEditFailureIsNonMutating() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a", "abc abc\nunique")
    let source = try await f.files.text("a")
    for (edits, error) in [
      ([TextEdit(oldText: "abc", newText: "x")], "edit_ambiguous"),
      ([TextEdit(oldText: "missing", newText: "x")], "edit_not_found"),
      (
        [TextEdit(oldText: "unique", newText: "x"), TextEdit(oldText: "nique", newText: "y")],
        "edit_overlap"
      ),
    ] {
      do {
        _ = try await f.files.edit(path: "a", expectedSHA: source.sha256, edits: edits)
        XCTFail()
      } catch let e as Failure { XCTAssertEqual(e.code, error) }
    }
    let after = try await f.files.text("a")
    XCTAssertEqual(after.text, source.text)
  }
  func testNewFileNeverOverwrites() async throws {
    let f = try Fixture()
    defer { f.remove() }
    _ = try await f.files.create(path: "new.swift", content: "hi")
    do {
      _ = try await f.files.create(path: "new.swift", content: "other")
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "file_exists") }
    let after = try await f.files.text("new.swift")
    XCTAssertEqual(after.text, "hi")
  }
  func testNewFileDryRunDoesNotWrite() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let dry = try await f.files.create(path: "planned.swift", content: "let ready = true\n", dryRun: true)
    XCTAssertEqual(dry["dryRun"], true)
    XCTAssertEqual(dry["wouldChange"], true)
    XCTAssertEqual(dry["applied"], false)
    XCTAssertEqual(dry["effect"], "none")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("planned.swift").path))

    let created = try await f.files.create(path: "planned.swift", content: "let ready = true\n")
    XCTAssertEqual(created["applied"], true)
    XCTAssertEqual(created["effect"], "confirmed")
  }

  func testSearchIgnoresSecretsAndBulk() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("src/a.ts", "useAuth()\nuseAuth")
    try f.write(".env", "useAuth=secret")
    try f.write("node_modules/a.ts", "useAuth")
    let output = try await f.files.search(query: "useAuth", glob: "*.ts")
    XCTAssertEqual(output["matches"].array?.count, 2)
    XCTAssertTrue(output["matches"].array?.allSatisfy { $0["path"].string == "src/a.ts" } == true)
  }
  func testFilenameSearchDoesNotReadContents() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("src/UserProfile.ts", "no matching content")
    try f.write("src/other.ts", "UserProfile only inside content")
    let output = try await f.files.search(
      query: "userprofile", glob: "*.ts", caseSensitive: false, mode: "filename")
    XCTAssertEqual(output["matches"].array?.count, 1)
    XCTAssertEqual(output["matches"].array?.first?["path"].string, "src/UserProfile.ts")
    XCTAssertEqual(output["backend"].string, "native-filename")
  }

  func testRegexSearchReturnsBoundedContextAndStillExcludesSecrets() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write(
      "src/example.ts",
      """
      before
      const user42 = "visible"
      after
      """)
    try f.write(".env", "const user99 = \"secret\"")

    let output = try await f.files.search(
      query: #"user[0-9]+"#, glob: "*.ts", caseSensitive: true, mode: "regex",
      contextBefore: 1, contextAfter: 1)
    XCTAssertEqual(output["backend"], "native-bounded-regex")
    XCTAssertEqual(output["matches"].array?.count, 1)
    let match = try XCTUnwrap(output["matches"].array?.first)
    XCTAssertEqual(match["line"], 2)
    XCTAssertTrue(match["context"].string?.contains("1: before") == true)
    XCTAssertTrue(match["context"].string?.contains("3: after") == true)
    XCTAssertFalse(output.text().contains("secret"))
  }

  func testRegexSearchRejectsAdvancedUnboundedFeatures() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a.txt", "aaaa")
    for pattern in [#"(?=a)"#, #"(a)\1"#, #"(a+)+b"#, #"a*a*b"#, #"a{1,99}"#] {
      do {
        _ = try await f.files.search(query: pattern, mode: "regex")
        XCTFail("Advanced regex feature should be rejected: \(pattern)")
      } catch let error as Failure {
        XCTAssertEqual(error.code, "invalid_arguments")
      }
    }
  }

  func testRepeatedEnumeration() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a", "match")
    let first = try await f.files.projectInfo()
    let second = try await f.files.projectInfo()
    XCTAssertEqual(first, second)
  }
  func testSearchLimitAndReadBudget() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try f.write("a", String(repeating: "match\n", count: 20_000))
    let search = try await f.files.search(query: "match", maxResults: 2)
    XCTAssertEqual(search["matches"].array?.count, 2)
    XCTAssertEqual(search["truncated"], true)
    let read = try await f.files.readFiles(paths: ["a"])
    XCTAssertLessThanOrEqual(
      read["files"].array?[0]["content"].string?.utf8.count ?? Int.max, 65_536)
    XCTAssertEqual(read["files"].array?[0]["complete"], false)
    XCTAssertNotEqual(read["files"].array?[0]["next"], .null)
  }

  func testReadFilesLongUTF8LineCanContinueByReturnedByteCursor() async throws {
    let f = try Fixture()
    defer { f.remove() }
    let source = String(repeating: "🙂", count: 20_000)
    try f.write("long.txt", source)

    let first = try await f.files.readFiles(paths: ["long.txt"], startLine: 1, endLine: 1)
    let firstFile = try XCTUnwrap(first["files"].array?.first)
    XCTAssertEqual(firstFile["complete"], false)
    XCTAssertEqual(firstFile["next"]["line"], 1)
    let offset = try XCTUnwrap(firstFile["next"]["byteOffset"].int)
    XCTAssertGreaterThan(offset, 0)
    XCTAssertEqual(offset % 4, 0)

    let second = try await f.files.readFiles(
      paths: ["long.txt"], startLine: 1, endLine: 1, byteOffset: offset)
    let secondFile = try XCTUnwrap(second["files"].array?.first)
    XCTAssertEqual(secondFile["complete"], true)
    XCTAssertEqual(secondFile["next"], .null)

    let prefix = try XCTUnwrap(firstFile["content"].string)
    let suffix = try XCTUnwrap(secondFile["content"].string)
    XCTAssertEqual(prefix + suffix, source)

    let invalid = try await f.files.readFiles(
      paths: ["long.txt"], startLine: 1, endLine: 1, byteOffset: offset + 1)
    XCTAssertEqual(
      invalid["files"].array?.first?["failure"]["error"], "invalid_arguments")
  }
  func testBinaryAndSizeRejection() async throws {
    let f = try Fixture()
    defer { f.remove() }
    try Data([0, 255]).write(to: f.root.appendingPathComponent("binary"))
    try Data(repeating: 65, count: WorkspaceFiles.maxFileBytes + 1).write(
      to: f.root.appendingPathComponent("big"))
    let read = try await f.files.readFiles(paths: ["binary", "big"])
    XCTAssertEqual(read["files"].array?[0]["failure"]["error"].string, "binary_file")
    XCTAssertEqual(read["files"].array?[1]["failure"]["error"].string, "file_too_large")
  }
  func testStopRevokesFilesystem() async throws {
    let f = try Fixture()
    defer { f.remove() }
    await f.files.shutdown()
    do {
      _ = try await f.files.create(path: "late", content: "no")
      XCTFail()
    } catch let e as Failure { XCTAssertEqual(e.code, "runtime_stopped") }
  }
}
