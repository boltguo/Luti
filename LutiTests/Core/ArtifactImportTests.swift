import XCTest

@testable import Luti

@MainActor final class ArtifactImportTests: XCTestCase {
  private func store(_ f: Fixture) throws -> ProjectCheckpointStore {
    try ProjectCheckpointStore(project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot)
  }

  private func importArtifact(
    _ artifact: Artifact, path: String, fixture: Fixture, artifacts: ArtifactStore,
    dryRun: Bool = false
  ) async throws -> JSONValue {
    try await ArtifactImporter.importArtifact(
      resource: artifact.uri, path: path, dryRun: dryRun, artifacts: artifacts,
      workspace: fixture.files, checkpoints: store(fixture), runID: UUID())
  }

  func testRouterRequiresBindingAndWriteScopeThenJournalsImport() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("source.txt", "sample")
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let exported = await router.callInCurrentProject(
      "export_artifact", arguments: ["path": "source.txt"])
    XCTAssertFalse(exported.isError)
    let resource = try XCTUnwrap(exported.data["resource"].string)
    let arguments: JSONValue = ["resource": .string(resource), "path": "imported.txt"]
    let missingBinding = await router.call("import_artifact", arguments: arguments)
    XCTAssertEqual(missingBinding.data["error"], "project_binding_required")
    let readOnlyGrant = ToolGrant.remote(RequestContext(
      transport: .loopback, clientID: "import-test", clientName: "Import test",
      authorizationID: UUID(), scopes: [.projectRead], resource: "http://localhost/mcp"))
    let denied = await router.callInCurrentProject(
      "import_artifact", arguments: arguments, grant: readOnlyGrant)
    XCTAssertEqual(denied.data["error"], "insufficient_scope")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("imported.txt").path))

    let imported = await router.callInCurrentProject("import_artifact", arguments: arguments)
    XCTAssertFalse(imported.isError)
    XCTAssertEqual(imported.data["checkpoint"]["status"], "ready")
    let checkpointID = try XCTUnwrap(imported.data["checkpoint"]["id"].string)
    let context = try ProjectContextStore(project: ApprovedProject(url: f.root), dataRoot: f.contextDataRoot)
    let journal = try context.session(router.activity.runID)
    XCTAssertTrue(journal.touchedFiles.contains("imported.txt"))
    XCTAssertEqual(journal.calls.last(where: { $0.tool == "import_artifact" })?.checkpointId, checkpointID)
    let events = await router.activity.snapshot()
    XCTAssertEqual(events.first(where: { $0.tool == "import_artifact" && $0.status == "ok" })?.checkpointID, checkpointID)
  }

  func testLargeBinaryImportPreservesBytesProvenanceAndRestores() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    // A real binary file above the text-edit ceiling must still be recoverable.
    let bytes = Data(repeating: 0xff, count: WorkspaceFiles.maxFileBytes + 1)
    let artifact = try await artifacts.insert(bytes, name: "design.png", mimeType: "image/png", source: .project)
    let result = try await importArtifact(artifact, path: "design.png", fixture: f, artifacts: artifacts)
    XCTAssertEqual(result["applied"], true)
    XCTAssertEqual(result["effect"], "confirmed")
    XCTAssertEqual(result["bytes"].int, bytes.count)
    XCTAssertEqual(result["sha256"].string, Budget.sha256(bytes))
    XCTAssertEqual(result["source"]["resource"].string, artifact.uri)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("design.png")), bytes)

    let checkpointID = try XCTUnwrap(result["checkpoint"]["id"].string)
    let checkpoints = try store(f)
    let manifest = try XCTUnwrap(checkpoints.recent().first)
    XCTAssertEqual(manifest.id, checkpointID)
    XCTAssertEqual(manifest.status, "ready")
    XCTAssertEqual(manifest.tool, "import_artifact")
    XCTAssertEqual(manifest.storedBytes, 0)
    XCTAssertEqual(manifest.pathAction?.sourceArtifactResource, artifact.uri)
    XCTAssertEqual(manifest.pathAction?.expectedAfter.first?.sha256, Budget.sha256(bytes))
    let plan = try XCTUnwrap(checkpoints.pathActionRestorePlan(id: checkpointID))
    let preview = try await f.files.previewPathActionCheckpoint(plan)
    XCTAssertEqual(preview["currentStateVerified"], true)
    XCTAssertEqual(preview["files"].array?.first?["operation"], "remove")
    let restored = try await f.files.restorePathActionCheckpoint(plan)
    XCTAssertEqual(restored["restored"], true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("design.png").path))
  }

  func testImportCannotBypassSourceReadPermission() async throws {
    let f = try Fixture(); defer { f.remove() }
    let router = try f.router(execution: true)
    addTeardownBlock { await router.stop() }
    let artifacts = await router.artifacts
    let sources: [(ArtifactSource, OAuthScope)] = [(.project, .projectRead), (.process, .processRun), (.browser, .browserUse)]
    func grant(_ scopes: Set<OAuthScope>) -> ToolGrant {
      .remote(RequestContext(transport: .loopback, clientID: "importer", clientName: "Importer",
        authorizationID: UUID(), scopes: scopes, resource: "http://localhost/mcp"))
    }
    for (index, pair) in sources.enumerated() {
      let artifact = try await artifacts.insert(Data([UInt8(index)]), name: "source.bin", source: pair.0)
      let path = "import-\(index).bin"
      let arguments: JSONValue = ["resource": .string(artifact.uri), "path": .string(path)]
      let missingRead = await router.callInCurrentProject("import_artifact", arguments: arguments,
        grant: grant([.projectWrite]))
      XCTAssertEqual(missingRead.data["error"], "insufficient_scope")
      let wrongDomain = await router.callInCurrentProject("import_artifact", arguments: arguments.adding("dryRun", true),
        grant: grant([.projectWrite, .computerRead]))
      XCTAssertEqual(wrongDomain.data["error"], "insufficient_scope")
      if pair.1 != .projectRead {
        let projectReader = await router.callInCurrentProject("import_artifact", arguments: arguments,
          grant: grant([.projectRead, .projectWrite]))
        XCTAssertEqual(projectReader.data["error"], "insufficient_scope")
      }
      let missingWrite = await router.callInCurrentProject("import_artifact", arguments: arguments,
        grant: grant([pair.1]))
      XCTAssertEqual(missingWrite.data["error"], "insufficient_scope")
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path))
      let imported = await router.callInCurrentProject("import_artifact", arguments: arguments,
        grant: grant([.projectWrite, pair.1]))
      XCTAssertFalse(imported.isError, imported.data.text())
      XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(path)), artifact.bytes)
    }
  }

  func testImportRecoveryPreservesSubsequentUserChanges() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    let artifact = try await artifacts.insert(Data([0, 1, 2, 3]), name: "sample.bin", source: .project)
    let result = try await importArtifact(artifact, path: "sample.bin", fixture: f, artifacts: artifacts)
    let checkpointID = try XCTUnwrap(result["checkpoint"]["id"].string)
    let plan = try XCTUnwrap(store(f).pathActionRestorePlan(id: checkpointID))
    try f.write("sample.bin", "user revision")
    do {
      _ = try await f.files.restorePathActionCheckpoint(plan)
      XCTFail("Recovery must not delete a file the user changed after import.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "checkpoint_restore_conflict")
    }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("sample.bin")), Data("user revision".utf8))
  }

  func testDryRunAndNoOverwriteDoNotLeaveFilesOrCheckpoints() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    let artifact = try await artifacts.insert(Data([0, 1, 2]), name: "sample.bin", source: .project)
    let preview = try await importArtifact(
      artifact, path: "sample.bin", fixture: f, artifacts: artifacts, dryRun: true)
    XCTAssertEqual(preview["applied"], false)
    XCTAssertEqual(preview["effect"], "none")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
    XCTAssertTrue(try store(f).recent().isEmpty)
    try f.write("sample.bin", "keep")
    do {
      _ = try await importArtifact(artifact, path: "sample.bin", fixture: f, artifacts: artifacts)
      XCTFail("Imports never overwrite existing destinations.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "file_exists")
    }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("sample.bin")), Data("keep".utf8))
    XCTAssertTrue(try store(f).recent().isEmpty)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains { $0.hasPrefix(".luti-import-") })
  }

  func testExpiredForeignAndExternalSourcesAreRefused() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    let foreignStore = ArtifactStore()
    let foreign = try await foreignStore.insert(Data([1]), name: "foreign.bin", source: .project)
    let expiredStore = ArtifactStore(ttl: -1)
    let expired = try await expiredStore.insert(Data([1]), name: "expired.bin", source: .project)
    let evictedStore = ArtifactStore()
    let evicted = try await evictedStore.insert(Data([1]), name: "evicted.bin", source: .project)
    for index in 0..<16 {
      _ = try await evictedStore.insert(Data([1]), name: "cache-\(index).bin", source: .project)
    }
    for (source, store) in [
      (foreign.uri, artifacts), (expired.uri, expiredStore),
      (evicted.uri, evictedStore),
      ("https://example.com/image.png", artifacts),
      ("file:///etc/passwd", artifacts), ("/tmp/sample.bin", artifacts),
      ("data:application/octet-stream;base64,AQ==", artifacts),
    ] {
      do {
        _ = try await ArtifactImporter.importArtifact(
          resource: source, path: "sample.bin", artifacts: store, workspace: f.files,
          checkpoints: self.store(f), runID: UUID())
        XCTFail("Only live artifacts from the current runtime may be imported: \(source)")
      } catch let failure as Failure {
        XCTAssertEqual(failure.code, "resource_not_found")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
    XCTAssertTrue(try store(f).recent().isEmpty)
  }

  func testImportUsesWorkspacePathAndSymlinkPolicy() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    let artifact = try await artifacts.insert(Data([0, 1]), name: "sample.bin", source: .project)
    try f.write("safe/target.bin", "keep")
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("alias"), withDestinationURL: f.root.appendingPathComponent("safe"))
    try FileManager.default.createSymbolicLink(
      at: f.root.appendingPathComponent("linked.bin"), withDestinationURL: f.root.appendingPathComponent("safe/target.bin"))
    let cases = [
      ("../escaped.bin", "path_outside_workspace"),
      ("/tmp/escaped.bin", "path_outside_workspace"),
      (".env", "protected_path"), (".git/config", "protected_path"),
      ("alias/escaped.bin", "path_outside_workspace"),
      ("linked.bin", "file_exists"),
    ]
    for (path, expectedCode) in cases {
      do {
        _ = try await importArtifact(artifact, path: path, fixture: f, artifacts: artifacts)
        XCTFail("Unsafe destination accepted: \(path)")
      } catch let failure as Failure {
        XCTAssertEqual(failure.code, expectedCode)
      }
    }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("safe/target.bin")), Data("keep".utf8))
    XCTAssertTrue(try store(f).recent().isEmpty)
  }

  func testBudgetAndStoppedRuntimeRejectBeforeMutation() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    do {
      _ = try await artifacts.insert(Data(count: ArtifactStore.maxBytes + 1), name: "oversized.bin", source: .project)
      XCTFail("Artifacts above 32 MiB must be rejected.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "invalid_arguments")
    }
    let artifact = try await artifacts.insert(Data([0]), name: "sample.bin", source: .project)
    await artifacts.stop()
    do {
      _ = try await importArtifact(artifact, path: "sample.bin", fixture: f, artifacts: artifacts)
      XCTFail("Stopped runtime artifacts must not remain importable.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, Failure.stopped.code)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
  }
}
