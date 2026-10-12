import XCTest
@testable import Luti

@MainActor final class ProjectEnablementTests: XCTestCase {
  func testAddingOneFolderRejectsAnotherUntilRemoved() throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let model = AppModel(contextDataRoot: first.contextDataRoot, defaults: first.defaults)
    XCTAssertNil(model.activeProject)
    XCTAssertFalse(model.canStart)
    model.addProject(first.root)
    let selected = try XCTUnwrap(model.activeProject)
    XCTAssertEqual(selected.path, first.root.path)
    XCTAssertTrue(model.canStart)
    model.addProject(second.root)
    XCTAssertEqual(model.activeProject, selected)
  }

  func testUnreadableSelectionStartsEmpty() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set(Data("broken".utf8), forKey: "selectedFolder")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertNil(model.activeProject)
    XCTAssertFalse(model.canStart)
  }

  func testRemoveKeepsSourceAndActivityForReattachment() async throws {
    let f = try Fixture(); defer { f.remove() }
    try f.write("keep.txt", "Keep this file")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    let selected = try XCTUnwrap(model.activeProject)
    let directory = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot)
    let event = ActivityEvent(id: UUID(), startedAt: Date(), finishedAt: Date(), tool: "read_files",
      target: "keep.txt", status: "ok", summary: "Read", durationSeconds: 0)
    LocalLogStore.appendActivity(event, directory: directory)
    model.removeProject(selected.id)
    XCTAssertNil(model.activeProject)
    XCTAssertFalse(model.canStart)
    XCTAssertTrue(model.activity.isEmpty)
    XCTAssertNil(f.defaults.object(forKey: "selectedFolder"))
    XCTAssertNil(AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults).activeProject)
    XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("keep.txt"), encoding: .utf8), "Keep this file")
    model.addProject(f.root)
    await model.activityLoad?.value
    XCTAssertEqual(model.activity.map(\.id), [event.id])
  }

  func testActiveRuntimeBlocksFolderChanges() throws {
    let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    let selected = try XCTUnwrap(model.activeProject)
    model.phase = .running
    model.removeProject(selected.id)
    model.addProject(other.root)
    XCTAssertEqual(model.activeProject, selected)
  }

  func testLegacyMigrationKeepsActiveProjectAndOpenAISettings() throws {
    let f = try Fixture(), other = try Fixture(); defer { f.remove(); other.remove() }
    // The 1.0.x format: several projects with extra fields, OpenAI address, other providers.
    let legacy = """
      [{"id":"a","name":"A","path":"\(other.root.path)","enabled":true,"permissionMode":"ask"},
       {"id":"b","name":"B","path":"\(f.root.path)","enabled":false,"permissionMode":"full"}]
      """
    f.defaults.set(Data(legacy.utf8), forKey: "approvedProjects")
    f.defaults.set("b", forKey: "activeProjectID")
    f.defaults.set("tunnel_0123456789abcdef0123456789abcdef", forKey: "connection.openai.address")
    f.defaults.set("https://mcp.example.com", forKey: "publicBaseURL")
    f.defaults.set("https://example.ngrok.app", forKey: "connection.ngrok.address")
    let data = f.contextDataRoot
    let project = data.appendingPathComponent("projects/key")
    for name in ["auth", "projects/key/memory", "projects/key/sessions", "projects/key/checkpoints",
                 "projects/key/activity"] {
      try FileManager.default.createDirectory(
        at: data.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    LegacyMigration.run(defaults: f.defaults, dataRoot: data, keychain: false)

    let selected = try XCTUnwrap(f.defaults.data(forKey: "selectedFolder"))
    XCTAssertEqual(try JSONDecoder().decode(ApprovedProject.self, from: selected).id, "b")
    XCTAssertEqual(f.defaults.string(forKey: "connection.openai.tunnelID"), "tunnel_0123456789abcdef0123456789abcdef")
    for key in ["approvedProjects", "activeProjectID", "connection.openai.address",
                "publicBaseURL", "connection.ngrok.address"] {
      XCTAssertNil(f.defaults.object(forKey: key), key)
    }
    XCTAssertTrue(f.defaults.bool(forKey: LegacyMigration.completedKey))
    XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("auth").path))
    for name in ["memory", "sessions", "checkpoints"] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), name)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("activity").path))

    let model = AppModel(contextDataRoot: data, defaults: f.defaults)
    XCTAssertEqual(model.activeProject?.path, ApprovedProject(url: f.root).path)
    XCTAssertEqual(model.tunnelID, "tunnel_0123456789abcdef0123456789abcdef")
  }

  func testLegacyMigrationLeavesFreshInstallUntouched() throws {
    let f = try Fixture(); defer { f.remove() }
    let auth = f.contextDataRoot.appendingPathComponent("auth")
    try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
    LegacyMigration.run(defaults: f.defaults, dataRoot: f.contextDataRoot, keychain: false)
    XCTAssertTrue(f.defaults.bool(forKey: LegacyMigration.completedKey))
    XCTAssertNil(f.defaults.data(forKey: "selectedFolder"))
    // No 1.0.x settings means nothing on disk is treated as legacy data.
    XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
  }
}

extension ProjectEnablementTests {
  func testCredentialMigrationRetriesReadsAndWritesAfterPreferencesAreRetired() throws {
    let old = "connection-openai-credential", current = KeychainService.openAIAPIKey
    for failWrite in [false, true] {
      let f = try Fixture(); defer { f.remove() }
      let store = FixtureKeychain(values: [old: "synthetic-key"],
        failedReads: failWrite ? [:] : [old: 1], failedSaves: failWrite ? 1 : 0)
      let tunnel = "tunnel_0123456789abcdef0123456789abcdef"
      f.defaults.set(tunnel, forKey: "connection.openai.address")
      f.defaults.set(try JSONEncoder().encode([ApprovedProject(url: f.root)]), forKey: "approvedProjects")
      LegacyMigration.run(defaults: f.defaults, dataRoot: f.contextDataRoot, keychain: true, credentials: store.client)
      XCTAssertTrue(f.defaults.bool(forKey: LegacyMigration.completedKey))
      XCTAssertFalse(f.defaults.bool(forKey: LegacyMigration.credentialsCompletedKey))
      XCTAssertNil(f.defaults.object(forKey: "connection.openai.address"))
      XCTAssertEqual(store.value(old), "synthetic-key")
      XCTAssertNil(store.value(current))
      LegacyMigration.run(defaults: f.defaults, dataRoot: f.contextDataRoot, keychain: true, credentials: store.client)
      XCTAssertTrue(f.defaults.bool(forKey: LegacyMigration.credentialsCompletedKey))
      XCTAssertEqual(store.value(current), "synthetic-key")
      XCTAssertNil(store.value(old))
      XCTAssertEqual(f.defaults.string(forKey: "connection.openai.tunnelID"), tunnel)
      XCTAssertNotNil(f.defaults.data(forKey: "selectedFolder"))
      XCTAssertTrue(store.readInteractions.allSatisfy { !$0 })
    }
  }

  func testCredentialMigrationRecoversAnAlreadyMarkedLegacyUpgrade() throws {
    let f = try Fixture(); defer { f.remove() }
    f.defaults.set(true, forKey: LegacyMigration.completedKey)
    let store = FixtureKeychain(values: ["connection-openai-credential": "preserved-key"])
    LegacyMigration.run(defaults: f.defaults, dataRoot: f.contextDataRoot, keychain: true, credentials: store.client)
    XCTAssertEqual(store.value(KeychainService.openAIAPIKey), "preserved-key")
    XCTAssertTrue(f.defaults.bool(forKey: LegacyMigration.credentialsCompletedKey))
  }
}
