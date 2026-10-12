import XCTest
@testable import Luti

@MainActor final class WorkspaceMutationTests: XCTestCase {
  func testCreateCopyMoveDeleteAndNoOverwrite() async throws {
    let f = try Fixture(); defer { f.remove() }
    _ = try await f.files.createDirectory(path: "src/deep", recursive: true)
    try f.write("src/deep/a.txt", "hello")
    _ = try await f.files.copyPath(source: "src", destination: "copy")
    XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("copy/deep/a.txt"), encoding: .utf8), "hello")
    do { _ = try await f.files.copyPath(source: "src", destination: "copy"); XCTFail() } catch {}
    _ = try await f.files.movePath(source: "copy", destination: "moved")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("copy").path))
    do { _ = try await f.files.deletePath(path: "moved"); XCTFail() } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("moved/deep/a.txt").path))
    _ = try await f.files.deletePath(path: "moved", recursive: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("moved").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("src/deep/a.txt").path))
  }
  func testUnifiedEditAndPathToolsPreserveAllMutationCapabilities() async throws {
    let f = try Fixture(); defer { f.remove() }
    let checkpoints = f.contextDataRoot.appendingPathComponent("projects")
      .appendingPathComponent(LutiPaths.projectKey(for: f.root))
      .appendingPathComponent("checkpoints")
    let legacyManifest = checkpoints.appendingPathComponent("chk_legacy/manifest.json")
    let legacyBytes = Data("Invalid legacy checkpoint must not block file operations".utf8)
    try PrivateFiles.atomicWrite(legacyBytes, to: legacyManifest)
    let router = try f.router(execution: true)

    let createDirectory = await router.callInCurrentProject(
      "path_action",
      arguments: ["action": "createDirectory", "path": "src/deep", "recursive": true])
    XCTAssertFalse(createDirectory.isError)

    let create = await router.callInCurrentProject(
      "edit_files",
      arguments: ["action": "create", "path": "src/deep/a.txt", "content": "hello\n"])
    XCTAssertFalse(create.isError)
    let original = try await f.files.text("src/deep/a.txt")

    let edit = await router.callInCurrentProject(
      "edit_files",
      arguments: [
        "action": "edit", "path": "src/deep/a.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "hello", "newText": "edited"]],
      ])
    XCTAssertFalse(edit.isError)
    let editedFile = try await f.files.text("src/deep/a.txt")
    XCTAssertEqual(editedFile.text, "edited\n")

    let copy = await router.callInCurrentProject(
      "path_action",
      arguments: ["action": "copy", "source": "src", "destination": "copy"])
    XCTAssertFalse(copy.isError)
    let move = await router.callInCurrentProject(
      "path_action",
      arguments: ["action": "move", "source": "copy", "destination": "moved"])
    XCTAssertFalse(move.isError)

    let patch = """
    --- a/moved/deep/a.txt
    +++ b/moved/deep/a.txt
    @@ -1 +1 @@
    -edited
    +patched
    """
    let patched = await router.callInCurrentProject(
      "edit_files", arguments: ["action": "patch", "patch": .string(patch)])
    XCTAssertFalse(patched.isError)
    let patchedFile = try await f.files.text("moved/deep/a.txt")
    XCTAssertEqual(patchedFile.text, "patched\n")

    let deleted = await router.callInCurrentProject(
      "path_action",
      arguments: ["action": "delete", "path": "moved", "recursive": true])
    XCTAssertFalse(deleted.isError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("moved").path))

    let crossEdit = await router.callInCurrentProject(
      "edit_files",
      arguments: [
        "action": "patch", "patch": .string(patch), "path": "src/deep/a.txt",
      ])
    XCTAssertTrue(crossEdit.isError)

    let crossPath = await router.callInCurrentProject(
      "path_action",
      arguments: [
        "action": "copy", "source": "src", "destination": "copy2", "recursive": true,
      ])
    XCTAssertTrue(crossPath.isError)

    await router.stop()
    for result in [createDirectory, create, edit, copy, move, patched, deleted] {
      XCTAssertEqual(result.data["checkpoint"], .null)
      XCTAssertEqual(result.data["checkpointWarning"], .null)
    }
    XCTAssertEqual(try PrivateFiles.names(checkpoints), ["chk_legacy"])
    XCTAssertEqual(try PrivateFiles.read(legacyManifest, max: 4096), legacyBytes)
  }

  func testArchiveUsesValidatedWorkspaceTreeAndProducesZip() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("docs/a.txt", "alpha")
    try f.write("docs/nested/b.txt", "beta")

    let archive = try await f.files.archive(paths: ["docs"])
    XCTAssertTrue(archive.starts(with: [0x50, 0x4b, 0x03, 0x04]))
    XCTAssertTrue(String(decoding: archive, as: UTF8.self).contains("docs/a.txt"))
    XCTAssertTrue(String(decoding: archive, as: UTF8.self).contains("docs/nested/b.txt"))
    XCTAssertGreaterThanOrEqual(archive.count, 22)
    XCTAssertEqual(Array(archive.suffix(22).prefix(4)), [0x50, 0x4b, 0x05, 0x06])

    try f.write("unsafe/ok.txt", "safe")
    try f.write("unsafe/.env", "secret")
    do {
      _ = try await f.files.archive(paths: ["unsafe"])
      XCTFail("Protected descendants must prevent archive export.")
    } catch let error as Failure {
      XCTAssertEqual(error.code, "protected_path")
    }
  }

  func testArchiveExtractsWithNormalizedUnixModes() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("pkg/run.sh", "#!/bin/sh\n")
    try f.write("pkg/data.txt", "data")
    let manager = FileManager.default
    try manager.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: f.root.appendingPathComponent("pkg/run.sh").path)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.root.appendingPathComponent("pkg/data.txt").path)

    let out = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: out) }
    try manager.createDirectory(at: out, withIntermediateDirectories: true)
    try await f.files.archive(paths: ["pkg"]).write(to: out.appendingPathComponent("a.zip"))
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", "a.zip"]
    unzip.currentDirectoryURL = out
    try unzip.run()
    unzip.waitUntilExit()
    XCTAssertEqual(unzip.terminationStatus, 0)
    func mode(_ path: String) throws -> Int {
      try XCTUnwrap(manager.attributesOfItem(atPath: out.appendingPathComponent(path).path)[.posixPermissions] as? Int)
    }
    XCTAssertEqual(try mode("pkg"), 0o755)
    XCTAssertEqual(try mode("pkg/run.sh"), 0o755)
    XCTAssertEqual(try mode("pkg/data.txt"), 0o644)
  }

  func testProtectedDescendantsPreventWholeMutation() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("folder/a.txt", "keep")
    try f.write("folder/.env", "secret")
    for action in ["copy", "move", "delete"] {
      do {
        if action == "copy" { _ = try await f.files.copyPath(source: "folder", destination: "other") }
        if action == "move" { _ = try await f.files.movePath(source: "folder", destination: "other") }
        if action == "delete" { _ = try await f.files.deletePath(path: "folder", recursive: true) }
        XCTFail(action)
      } catch let error as Failure { XCTAssertEqual(error.code, "protected_path") }
      XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("folder/a.txt").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("other").path))
    }
    do { _ = try await f.files.deletePath(path: ".", recursive: true); XCTFail() } catch {}
  }
  func testPatchMultiFileDryRunAndConflictAreNonMutating() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("a.txt", "one\ntwo\n")
    try f.write("b.txt", "keep\n")
    let patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+three\n--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-keep\n+changed\n"
    _ = try await f.files.applyPatch(patch, dryRun: true)
    let before = try await f.files.text("a.txt")
    XCTAssertEqual(before.text, "one\ntwo\n")
    do { _ = try await f.files.applyPatch(patch.replacingOccurrences(of: "-keep", with: "-wrong")); XCTFail() }
    catch let error as Failure {
      XCTAssertEqual(error.code, "patch_conflict")
      XCTAssertTrue(error.message.contains("b.txt: hunk #1"))
    }
    let unchanged = try await f.files.text("a.txt")
    XCTAssertEqual(unchanged.text, before.text)
    _ = try await f.files.applyPatch(patch)
    let afterA = try await f.files.text("a.txt"), afterB = try await f.files.text("b.txt")
    XCTAssertEqual(afterA.text, "one\nthree\n")
    XCTAssertEqual(afterB.text, "changed\n")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".luti-") })
  }
  func testExactEditDiffRoundTripsThroughPatch() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("roundtrip.txt", "alpha\nomega\n")
    let source = try await f.files.text("roundtrip.txt")

    let insertion = try await f.files.edit(
      path: "roundtrip.txt", expectedSHA: source.sha256,
      edits: [TextEdit(oldText: "alpha\n", newText: "alpha\ninserted\n")], dryRun: true)
    let insertionPatch = try XCTUnwrap(insertion["diff"].string)
    let insertionApply = try await f.files.applyPatch(insertionPatch, dryRun: true)
    XCTAssertEqual(insertionApply["files"].array?.first?["sha256"], insertion["sha256"])
    XCTAssertEqual(insertionApply["effect"], "none")
    XCTAssertEqual(insertionApply["wouldChange"], true)

    let deletion = try await f.files.edit(
      path: "roundtrip.txt", expectedSHA: source.sha256,
      edits: [TextEdit(oldText: "alpha\n", newText: "")], dryRun: true)
    let deletionPatch = try XCTUnwrap(deletion["diff"].string)
    let deletionApply = try await f.files.applyPatch(deletionPatch, dryRun: true)
    XCTAssertEqual(deletionApply["files"].array?.first?["sha256"], deletion["sha256"])

    let current = try await f.files.text("roundtrip.txt")
    XCTAssertEqual(current.text, source.text)
  }

  func testPatchCreationDeletionAndNoNewline() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("old.txt", "old\n")
    let patch = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+new\n\\ No newline at end of file\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"
    _ = try await f.files.applyPatch(patch)
    let result = try await f.files.text("new.txt")
    XCTAssertEqual(result.text, "new")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("old.txt").path))
    for path in ["../outside", ".env", "/etc/hosts"] {
      let invalid = "--- /dev/null\n+++ \(path)\n@@ -0,0 +1 @@\n+x\n"
      do { _ = try await f.files.applyPatch(invalid); XCTFail(path) } catch {}
    }
  }
  func testPatchHardLinkRejectedAndMalformedHunk() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("a", "one\n")
    try FileManager.default.linkItem(at: f.root.appendingPathComponent("a"), to: f.root.appendingPathComponent("b"))
    do { _ = try await f.files.applyPatch("--- a/a\n+++ b/a\n@@ -1 +1 @@\n-one\n+two\n"); XCTFail() }
    catch let error as Failure { XCTAssertEqual(error.code, "unsupported_file") }
    XCTAssertThrowsError(try UnifiedPatch.parse("--- a/x\n+++ b/x\n@@ -1,9 +1 @@\n-x\n+y\n"))
  }
}

extension WorkspaceMutationTests {
  func testPatchRejectsCaseAliasesBeforeChangingExistingFiles() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("notes.txt", "one\ntwo\n")
    let aliasExists = FileManager.default.fileExists(atPath: f.root.appendingPathComponent("NOTES.txt").path)
    if !aliasExists { try f.write("NOTES.txt", "one\ntwo\n") }
    let patch = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-one\n+ONE\n--- a/NOTES.txt\n+++ b/NOTES.txt\n@@ -2 +2 @@\n-two\n+TWO\n"
    if aliasExists {
      for dryRun in [true, false] {
        do { _ = try await f.files.applyPatch(patch, dryRun: dryRun); XCTFail("Aliased targets must be rejected") }
        catch let error as Failure { XCTAssertEqual(error.code, "invalid_arguments") }
      }
      let current = try await f.files.text("notes.txt")
      XCTAssertEqual(current.text, "one\ntwo\n")
    } else {
      _ = try await f.files.applyPatch(patch)
      let first = try await f.files.text("notes.txt"), second = try await f.files.text("NOTES.txt")
      XCTAssertEqual(first.text, "ONE\ntwo\n")
      XCTAssertEqual(second.text, "one\nTWO\n")
    }
  }

  func testPatchCreationAliasesNeverOverwriteAndRollback() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("case-probe", "x")
    guard FileManager.default.fileExists(atPath: f.root.appendingPathComponent("CASE-PROBE").path) else { return }
    let patch = "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+first\n--- /dev/null\n+++ b/NEW.txt\n@@ -0,0 +1 @@\n+second\n"
    do { _ = try await f.files.applyPatch(patch); XCTFail("Creation must not overwrite a case alias") } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("new.txt").path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".luti-") })
  }

  func testExactEditDiffPreservesEOFAndEmptyFiles() async throws {
    let f = try Fixture(); defer { f.remove() }
    let pairs = [("one", "two"), ("one\n", "one"), ("one", "one\n"),
                 ("one\n", "two\n"), ("one", ""), ("one\n", ""), ("\n", ""),
                 ("head\ntail", "changed\ntail"), ("head\n\n", "head\n")]
    for (before, after) in pairs {
      try f.write("eof.txt", before)
      let edit = try await f.files.edit(path: "eof.txt", expectedSHA: Budget.sha256(Data(before.utf8)),
        edits: [TextEdit(oldText: before, newText: after)], dryRun: true)
      _ = try await f.files.applyPatch(try XCTUnwrap(edit["diff"].string))
      let bytes = try Data(contentsOf: f.root.appendingPathComponent("eof.txt"))
      XCTAssertEqual(bytes, Data(after.utf8), "\(before.debugDescription) -> \(after.debugDescription)")
      XCTAssertEqual(Budget.sha256(bytes), edit["sha256"].string)
    }
    for after in ["one", "one\n", "\n"] {
      try f.write("empty.txt", "")
      let patch = WorkspaceFiles.diff("", after, path: "empty.txt")
      _ = try await f.files.applyPatch(patch)
      XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("empty.txt")), Data(after.utf8))
    }
  }
}
