import XCTest
@testable import Luti

@MainActor final class ProjectEnablementTests: XCTestCase {
  func testAddingOneFolderRejectsAnotherUntilRemoved() throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let model = AppModel(contextDataRoot: first.contextDataRoot, defaults: first.defaults)
    XCTAssertNil(model.activeProject)
    XCTAssertFalse(model.canStart)
    XCTAssertFalse(model.canLaunch)
    XCTAssertFalse(model.apiKeySaved)
    XCTAssertEqual(model.tunnelID, "")
    model.addProject(first.root)
    let selected = try XCTUnwrap(model.activeProject)
    XCTAssertEqual(selected.path, first.root.path)
    XCTAssertTrue(model.canStart)
    model.addProject(second.root)
    XCTAssertEqual(model.activeProject, selected)
  }

  func testNewFolderStartsInSafeModeAndKeepsFullAccessAcrossRelaunch() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    model.addProject(f.root)
    XCTAssertEqual(model.activeProject?.permissionMode, .ask)
    model.setPermissionMode(.fullProjectAccess)
    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertEqual(reopened.activeProject?.permissionMode, .fullProjectAccess)
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

  func testRelaunchRestoresCurrentSettingsCredentialsAndActivity() async throws {
    let f = try Fixture(); defer { f.remove() }
    let selected = ApprovedProject(url: f.root)
    let encoded = try JSONEncoder().encode(selected)
    let tunnel = "tunnel_0123456789abcdef0123456789abcdef"
    let key = "sk-" + String(repeating: "a", count: 40)
    let store = FixtureKeychain(values: [KeychainService.openAIAPIKey: key])
    f.defaults.set(encoded, forKey: "selectedFolder")
    f.defaults.set(tunnel, forKey: "connection.openai.tunnelID")
    let directory = LocalLogStore.activityDirectory(for: f.root, dataRoot: f.contextDataRoot)
    let event = ActivityEvent(id: UUID(), startedAt: Date(), finishedAt: Date(), tool: "read_files",
      target: "source.txt", status: "ok", summary: "Read", durationSeconds: 0)
    LocalLogStore.appendActivity(event, directory: directory)

    for _ in 0..<2 {
      let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults, credentials: store.client)
      await model.activityLoad?.value
      XCTAssertEqual(model.activeProject, selected)
      XCTAssertEqual(model.tunnelID, tunnel)
      XCTAssertEqual(model.savedTunnelID, tunnel)
      XCTAssertTrue(model.apiKeySaved)
      XCTAssertTrue(model.canLaunch)
      XCTAssertEqual(model.phase, .stopped)
      XCTAssertEqual(model.activity.map(\.id), [event.id])
      XCTAssertEqual(f.defaults.data(forKey: "selectedFolder"), encoded)
      XCTAssertEqual(store.value(KeychainService.openAIAPIKey), key)
      XCTAssertTrue(store.readInteractions.isEmpty, "Launch only checks whether the current key exists.")
    }
  }
}
