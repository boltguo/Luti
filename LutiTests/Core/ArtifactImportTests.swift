import XCTest

@testable import Luti

@MainActor final class ArtifactImportTests: XCTestCase {
  private func checkpointDirectory(_ f: Fixture) -> URL {
    f.contextDataRoot.appendingPathComponent("projects")
      .appendingPathComponent(LutiPaths.projectKey(for: f.root))
      .appendingPathComponent("checkpoints")
  }

  private func importArtifact(
    _ artifact: Artifact, path: String, fixture: Fixture, artifacts: ArtifactStore,
    dryRun: Bool = false
  ) async throws -> JSONValue {
    let source = try await artifacts.resolve(artifact.uri)
    return try await fixture.files.importArtifact(source, path: path, dryRun: dryRun)
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
    XCTAssertEqual(imported.data["checkpoint"], .null)
    let events = await router.activity.snapshot()
    XCTAssertTrue(events.contains { $0.tool == "import_artifact" && $0.status == "ok" })
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
  }

  func testLargeBinaryImportPreservesBytesAndProvenanceWithoutRecovery() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    // Binary imports retain their own size limit, independent of text editing.
    let bytes = Data(repeating: 0xff, count: WorkspaceFiles.maxFileBytes + 1)
    let artifact = try await artifacts.insert(bytes, name: "design.png", mimeType: "image/png", source: .project)
    let result = try await importArtifact(artifact, path: "design.png", fixture: f, artifacts: artifacts)
    XCTAssertEqual(result["applied"], true)
    XCTAssertEqual(result["effect"], "confirmed")
    XCTAssertEqual(result["bytes"].int, bytes.count)
    XCTAssertEqual(result["sha256"].string, Budget.sha256(bytes))
    XCTAssertEqual(result["source"]["resource"].string, artifact.uri)
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("design.png")), bytes)

    XCTAssertEqual(result["checkpoint"], .null)
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
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

  func testDryRunAndNoOverwriteDoNotLeaveFilesOrRecoveryStorage() async throws {
    let f = try Fixture(); defer { f.remove() }
    let artifacts = ArtifactStore()
    let artifact = try await artifacts.insert(Data([0, 1, 2]), name: "sample.bin", source: .project)
    let preview = try await importArtifact(
      artifact, path: "sample.bin", fixture: f, artifacts: artifacts, dryRun: true)
    XCTAssertEqual(preview["applied"], false)
    XCTAssertEqual(preview["effect"], "none")
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
    try f.write("sample.bin", "keep")
    do {
      _ = try await importArtifact(artifact, path: "sample.bin", fixture: f, artifacts: artifacts)
      XCTFail("Imports never overwrite existing destinations.")
    } catch let failure as Failure {
      XCTAssertEqual(failure.code, "file_exists")
    }
    XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("sample.bin")), Data("keep".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
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
        let artifact = try await store.resolve(source)
        _ = try await f.files.importArtifact(artifact, path: "sample.bin")
        XCTFail("Only live artifacts from the current runtime may be imported: \(source)")
      } catch let failure as Failure {
        XCTAssertEqual(failure.code, "resource_not_found")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("sample.bin").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
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
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointDirectory(f).path))
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
