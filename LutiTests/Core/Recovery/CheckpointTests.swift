import XCTest

@testable import Luti

@MainActor final class CheckpointTests: XCTestCase {
  private func store(_ f: Fixture) throws -> ProjectCheckpointStore {
    try ProjectCheckpointStore(
      project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot)
  }

  func testConfirmedEditCreatesRestorablePrivateCheckpoint() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    XCTAssertFalse(edit.isError)
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    XCTAssertEqual(edit.data["checkpoint"]["status"], "ready")
    let afterEdit = try await f.files.text("source.txt")
    XCTAssertEqual(afterEdit.text, "after\n")

    let checkpointStore = try store(f)
    let recent = try checkpointStore.recent()
    XCTAssertEqual(recent.map(\.id), [checkpointID])
    XCTAssertEqual(recent.first?.files.first?.beforeSHA256, original.sha256)
    XCTAssertNotNil(recent.first?.files.first?.afterSHA256)

    let plan = try checkpointStore.restorePlan(id: checkpointID)
    let restored = try await f.files.restoreCheckpointFiles(plan.1)
    XCTAssertEqual(restored["restored"], true)
    _ = try checkpointStore.markRestored(checkpointID)
    let afterRestore = try await f.files.text("source.txt")
    XCTAssertEqual(afterRestore.text, "before\n")
    XCTAssertEqual(try checkpointStore.recent().first?.status, "restored")
    XCTAssertThrowsError(try checkpointStore.restorePlan(id: checkpointID)) { error in
      XCTAssertEqual((error as? Failure)?.code, "checkpoint_not_restorable")
    }
  }

  func testCheckpointIDIsSharedByToolSessionAndPersistedActivity() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    XCTAssertFalse(edit.isError)
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)

    let events = await router.activity.snapshot()
    let activity = try XCTUnwrap(events.first { $0.tool == "edit_files" })
    XCTAssertEqual(activity.checkpointID, checkpointID)

    let project = ApprovedProject(url: f.root)
    let context = try ProjectContextStore(
      project: project, dataRoot: f.contextDataRoot)
    let journal = try context.session(router.activity.runID)
    let call = try XCTUnwrap(journal.calls.first { $0.tool == "edit_files" })
    XCTAssertEqual(call.checkpointId, checkpointID)

    let persisted = LocalLogStore.recentActivities(
      limit: 50, directory: context.activityDirectory)
    let persistedEdit = try XCTUnwrap(
      persisted.last { $0.tool == "edit_files" && $0.status == "ok" })
    XCTAssertEqual(persistedEdit.checkpointID, checkpointID)
  }

  func testCheckpointPreviewIsBoundedVerifiedAndRejectsStaleState() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    let checkpointStore = try store(f)
    let plan = try checkpointStore.restorePlan(id: checkpointID)

    let preview = try await f.files.previewCheckpointFiles(
      plan.1, maxDiffBytes: 128)
    XCTAssertEqual(preview["currentStateVerified"], true)
    XCTAssertLessThanOrEqual(preview["diffBytes"].int ?? .max, 128)
    XCTAssertEqual(preview["files"].array?.first?["operation"], "edit")
    XCTAssertEqual(preview["files"].array?.first?["textPreview"], true)
    XCTAssertTrue(preview["diff"].string?.contains("--- a/source.txt") == true)
    XCTAssertTrue(preview["diff"].string?.contains("+after") == true)

    try Data("external\n".utf8).write(
      to: f.root.appendingPathComponent("source.txt"), options: .atomic)
    do {
      _ = try await f.files.previewCheckpointFiles(plan.1)
      XCTFail("A stale checkpoint preview must be rejected")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
  }

  func testCheckpointPreviewUsesMetadataOnlyForLargeText() async throws {
    let f = try Fixture(); defer { f.remove() }
    let before =
      String(repeating: "a", count: 150_000) + "UNIQUE_TARGET"
      + String(repeating: "a", count: 150_000) + "\n"
    try f.write("large.txt", before)
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("large.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "large.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "UNIQUE_TARGET", "newText": "CHANGED_TARGET"]],
      ])
    XCTAssertFalse(edit.isError)
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    let plan = try store(f).restorePlan(id: checkpointID)
    let preview = try await f.files.previewCheckpointFiles(plan.1)

    XCTAssertEqual(preview["textPreviewCount"], 0)
    XCTAssertEqual(preview["metadataOnlyCount"], 1)
    XCTAssertEqual(preview["diff"], "")
    XCTAssertEqual(
      preview["files"].array?.first?["previewUnavailable"],
      "largeOrNonUTF8")
  }

  func testCheckpointRestoreRefusesExternalModification() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "one\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "one", "newText": "two"]],
      ])
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    try Data("external\n".utf8).write(
      to: f.root.appendingPathComponent("source.txt"), options: .atomic)

    let checkpointStore = try store(f)
    let plan = try checkpointStore.restorePlan(id: checkpointID)
    do {
      _ = try await f.files.restoreCheckpointFiles(plan.1)
      XCTFail("External modifications must block restore")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
    let external = try await f.files.text("source.txt")
    XCTAssertEqual(external.text, "external\n")
  }

  func testCheckpointRestoreRefusesModeOnlyExternalModification() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "one\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit",
        "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "one", "newText": "two"]],
      ])
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    let url = f.root.appendingPathComponent("source.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)

    let checkpointStore = try store(f)
    let plan = try checkpointStore.restorePlan(id: checkpointID)
    do {
      _ = try await f.files.restoreCheckpointFiles(plan.1)
      XCTFail("Mode-only external modifications must block restore")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
    let current = try await f.files.text("source.txt")
    XCTAssertEqual(current.text, "two\n")
  }

  func testCreateCheckpointRestoreRemovesCreatedFile() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let created = await router.call(
      "edit_files",
      arguments: ["action": "create", "path": "new.txt", "content": "new\n"])
    XCTAssertFalse(created.isError)
    let checkpointID = try XCTUnwrap(created.data["checkpoint"]["id"].string)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("new.txt").path))

    let checkpointStore = try store(f)
    let plan = try checkpointStore.restorePlan(id: checkpointID)
    let result = try await f.files.restoreCheckpointFiles(plan.1)
    XCTAssertEqual(result["restored"], true)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("new.txt").path))
  }

  func testMultiFilePatchCheckpointRestoresCreateEditAndDelete() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("a.txt", "alpha\n")
    try f.write("b.txt", "beta\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let patch = """
    --- a/a.txt
    +++ b/a.txt
    @@ -1 +1 @@
    -alpha
    +changed
    --- /dev/null
    +++ b/c.txt
    @@ -0,0 +1 @@
    +created
    --- a/b.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -beta
    """
    let output = await router.call(
      "edit_files", arguments: ["action": "patch", "patch": .string(patch)])
    XCTAssertFalse(output.isError)
    let checkpointID = try XCTUnwrap(output.data["checkpoint"]["id"].string)
    let changedA = try await f.files.text("a.txt")
    XCTAssertEqual(changedA.text, "changed\n")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("b.txt").path))
    let createdC = try await f.files.text("c.txt")
    XCTAssertEqual(createdC.text, "created\n")

    let checkpointStore = try store(f)
    let plan = try checkpointStore.restorePlan(id: checkpointID)
    let restored = try await f.files.restoreCheckpointFiles(plan.1)
    XCTAssertEqual(restored["paths"].array?.count, 3)
    let restoredA = try await f.files.text("a.txt")
    let restoredB = try await f.files.text("b.txt")
    XCTAssertEqual(restoredA.text, "alpha\n")
    XCTAssertEqual(restoredB.text, "beta\n")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("c.txt").path))
  }

  func testDryRunAndFailedEditDoNotLeaveCheckpoint() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let original = try await f.files.text("source.txt")

    let dry = await router.call(
      "edit_files",
      arguments: [
        "action": "edit", "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
        "dryRun": true,
      ])
    XCTAssertFalse(dry.isError)
    XCTAssertEqual(dry.data["applied"], false)
    XCTAssertEqual(try store(f).recent().count, 0)

    let failed = await router.call(
      "edit_files",
      arguments: [
        "action": "edit", "path": "source.txt",
        "expectedSHA256": .string(String(repeating: "0", count: 64)),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    XCTAssertTrue(failed.isError)
    XCTAssertEqual(try store(f).recent().count, 0)
  }

  func testAppModelRestoreRequiresStoppedRuntimeAndLocalApprovedProject() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before")
    let router = try f.router(execution: true)
    let original = try await f.files.text("source.txt")
    let edit = await router.call(
      "edit_files",
      arguments: [
        "action": "edit", "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    let checkpointID = try XCTUnwrap(edit.data["checkpoint"]["id"].string)
    await router.stop()

    let project = ApprovedProject(url: f.root)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.phase = .running
    do {
      _ = try await model.restoreCheckpoint(checkpointID, project: project)
      XCTFail("An active Runtime must block local restore")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, Failure.invalid("").code)
    }
    model.phase = .stopped
    let restored = try await model.restoreCheckpoint(checkpointID, project: project)
    XCTAssertEqual(restored["restored"], true)
    let fresh = try WorkspaceFiles(root: f.root)
    let current = try await fresh.text("source.txt")
    await fresh.shutdown()
    XCTAssertEqual(current.text, "before")
  }

  func testCreateDirectoryCheckpointRestoresOnlyCreatedSubtree() async throws {
    let f = try Fixture(); defer { f.remove() }
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("existing"), withIntermediateDirectories: true)
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let created = await router.call(
      "path_action",
      arguments: [
        "action": "createDirectory", "path": "existing/a/b", "recursive": true,
      ])
    XCTAssertFalse(created.isError)
    XCTAssertEqual(created.data["checkpoint"]["kind"], "pathAction")
    XCTAssertEqual(created.data["checkpoint"]["pathAction"], "createDirectory")
    let checkpointID = try XCTUnwrap(created.data["checkpoint"]["id"].string)

    let checkpointStore = try store(f)
    let plan = try XCTUnwrap(checkpointStore.pathActionRestorePlan(id: checkpointID))
    let preview = try await f.files.previewPathActionCheckpoint(plan)
    XCTAssertEqual(preview["pathAction"], "createDirectory")
    XCTAssertEqual(preview["currentStateVerified"], true)
    XCTAssertEqual(preview["metadataOnlyCount"], 2)

    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["restored"], true)
    _ = try checkpointStore.markRestored(checkpointID)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("existing").path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("existing/a").path))
  }

  func testCopyCheckpointRestoreRemovesVerifiedCopyAndPreservesSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/nested/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let copied = await router.call(
      "path_action",
      arguments: ["action": "copy", "source": "src", "destination": "copy"])
    XCTAssertFalse(copied.isError)
    XCTAssertEqual(copied.data["checkpoint"]["status"], "ready")
    let checkpointID = try XCTUnwrap(copied.data["checkpoint"]["id"].string)

    let checkpointStore = try store(f)
    let plan = try XCTUnwrap(checkpointStore.pathActionRestorePlan(id: checkpointID))
    let preview = try await f.files.previewPathActionCheckpoint(plan)
    XCTAssertEqual(preview["pathAction"], "copy")
    XCTAssertEqual(preview["currentStateVerified"], true)

    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["operation"], "removeCreatedTree")
    _ = try checkpointStore.markRestored(checkpointID)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("copy").path))
    let source = try await f.files.text("src/nested/a.txt")
    XCTAssertEqual(source.text, "alpha\n")
  }

  func testCopyCheckpointRefusesToRemoveExternallyModifiedDestination() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let copied = await router.call(
      "path_action",
      arguments: ["action": "copy", "source": "src", "destination": "copy"])
    let checkpointID = try XCTUnwrap(copied.data["checkpoint"]["id"].string)
    try Data("user-change\n".utf8).write(
      to: f.root.appendingPathComponent("copy/a.txt"), options: .atomic)

    let plan = try XCTUnwrap(try store(f).pathActionRestorePlan(id: checkpointID))
    do {
      _ = try await f.files.restorePathActionCheckpoint(plan)
      XCTFail("Externally modified copied trees must not be removed")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
    let current = try await f.files.text("copy/a.txt")
    XCTAssertEqual(current.text, "user-change\n")
  }

  func testMoveCheckpointRestoresTreeByVerifiedInverseRename() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/nested/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let moved = await router.call(
      "path_action",
      arguments: ["action": "move", "source": "src", "destination": "moved"])
    XCTAssertFalse(moved.isError)
    let checkpointID = try XCTUnwrap(moved.data["checkpoint"]["id"].string)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("src").path))

    let checkpointStore = try store(f)
    let plan = try XCTUnwrap(checkpointStore.pathActionRestorePlan(id: checkpointID))
    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["operation"], "moveBack")
    _ = try checkpointStore.markRestored(checkpointID)

    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("moved").path))
    let source = try await f.files.text("src/nested/a.txt")
    XCTAssertEqual(source.text, "alpha\n")
  }

  func testMoveCheckpointRefusesChangedDestinationOrRecreatedSource() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let moved = await router.call(
      "path_action",
      arguments: ["action": "move", "source": "src", "destination": "moved"])
    let checkpointID = try XCTUnwrap(moved.data["checkpoint"]["id"].string)
    let plan = try XCTUnwrap(try store(f).pathActionRestorePlan(id: checkpointID))

    try Data("changed\n".utf8).write(
      to: f.root.appendingPathComponent("moved/a.txt"), options: .atomic)
    do {
      _ = try await f.files.restorePathActionCheckpoint(plan)
      XCTFail("Changed moved destination must block inverse rename")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }

    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("src"), withIntermediateDirectories: false)
    do {
      _ = try await f.files.previewPathActionCheckpoint(plan)
      XCTFail("Recreated source must block recovery review")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
  }

  func testDeleteCheckpointRestoresBoundedTreeContentsAndModes() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("trash/nested/a.txt", "alpha\n")
    try f.write("trash/b.txt", "beta\n")
    let executable = f.root.appendingPathComponent("trash/nested/a.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o744)], ofItemAtPath: executable.path)

    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let deleted = await router.call(
      "path_action",
      arguments: ["action": "delete", "path": "trash", "recursive": true])
    XCTAssertFalse(deleted.isError)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("trash").path))
    XCTAssertGreaterThan(deleted.data["checkpoint"]["storedBytes"].int ?? 0, 0)
    let checkpointID = try XCTUnwrap(deleted.data["checkpoint"]["id"].string)

    let checkpointStore = try store(f)
    let plan = try XCTUnwrap(checkpointStore.pathActionRestorePlan(id: checkpointID))
    let preview = try await f.files.previewPathActionCheckpoint(plan)
    XCTAssertEqual(preview["pathAction"], "delete")
    XCTAssertEqual(preview["currentStateVerified"], true)

    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["operation"], "restoreDeletedTree")
    _ = try checkpointStore.markRestored(checkpointID)
    let restoredA = try await f.files.text("trash/nested/a.txt")
    let restoredB = try await f.files.text("trash/b.txt")
    XCTAssertEqual(restoredA.text, "alpha\n")
    XCTAssertEqual(restoredB.text, "beta\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o744)
  }

  func testDeleteCheckpointRestoresSingleFileContentsAndMode() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("deleted.txt", "alpha\n")
    let file = f.root.appendingPathComponent("deleted.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: file.path)

    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let deleted = await router.call(
      "path_action",
      arguments: ["action": "delete", "path": "deleted.txt", "recursive": false])
    XCTAssertFalse(deleted.isError)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    let checkpointID = try XCTUnwrap(deleted.data["checkpoint"]["id"].string)

    let checkpointStore = try store(f)
    let plan = try XCTUnwrap(checkpointStore.pathActionRestorePlan(id: checkpointID))
    let preview = try await f.files.previewPathActionCheckpoint(plan)
    XCTAssertEqual(preview["pathAction"], "delete")
    XCTAssertEqual(preview["currentStateVerified"], true)

    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["operation"], "restoreDeletedTree")
    _ = try checkpointStore.markRestored(checkpointID)
    let restoredFile = try await f.files.text("deleted.txt")
    XCTAssertEqual(restoredFile.text, "alpha\n")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
  }

  func testDeleteCheckpointRefusesWhenDeletedRootWasRecreated() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("trash/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let deleted = await router.call(
      "path_action",
      arguments: ["action": "delete", "path": "trash", "recursive": true])
    let checkpointID = try XCTUnwrap(deleted.data["checkpoint"]["id"].string)
    try f.write("trash/new.txt", "new\n")

    let plan = try XCTUnwrap(try store(f).pathActionRestorePlan(id: checkpointID))
    do {
      _ = try await f.files.restorePathActionCheckpoint(plan)
      XCTFail("Recreated deleted roots must block restore")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
    let recreated = try await f.files.text("trash/new.txt")
    XCTAssertEqual(recreated.text, "new\n")
  }

  func testPathActionRecoveryBudgetFailsBeforeDestructiveMutation() async throws {
    let f = try Fixture(); defer { f.remove() }
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent("large-tree"), withIntermediateDirectories: true)
    for index in 0..<513 {
      let name = String(format: "large-tree/%04d.txt", index)
      try f.write(name, "x")
    }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }

    let deleted = await router.call(
      "path_action",
      arguments: [
        "action": "delete", "path": "large-tree", "recursive": true,
      ])
    XCTAssertTrue(deleted.isError)
    XCTAssertEqual(deleted.data["error"], "checkpoint_tree_too_large")
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("large-tree/0000.txt").path))
    XCTAssertEqual(try store(f).recent().count, 0)
  }

  func testAppModelPreviewsAndRestoresPathActionCheckpoint() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("src/a.txt", "alpha\n")
    let router = try f.router(execution: true)
    let copied = await router.call(
      "path_action",
      arguments: ["action": "copy", "source": "src", "destination": "copy"])
    let checkpointID = try XCTUnwrap(copied.data["checkpoint"]["id"].string)
    await router.stop()

    let project = ApprovedProject(url: f.root)
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.approvedProjects = [project]
    model.activeProjectID = project.id
    model.phase = .stopped

    let preview = try await model.checkpointPreview(checkpointID, project: project)
    XCTAssertEqual(preview["pathAction"], "copy")
    XCTAssertEqual(preview["currentStateVerified"], true)

    let restored = try await model.restoreCheckpoint(checkpointID, project: project)
    XCTAssertEqual(restored["operation"], "removeCreatedTree")
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent("copy").path))
  }

  func testCheckpointDataNeverTouchesProjectGitNamespace() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "before")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let original = try await f.files.text("source.txt")
    let output = await router.call(
      "edit_files",
      arguments: [
        "action": "edit", "path": "source.txt",
        "expectedSHA256": .string(original.sha256),
        "edits": [["oldText": "before", "newText": "after"]],
      ])
    XCTAssertFalse(output.isError)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: f.root.appendingPathComponent(".luti").path))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: f.contextDataRoot.appendingPathComponent("projects").path))
  }
}
