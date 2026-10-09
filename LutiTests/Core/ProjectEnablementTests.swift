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

  func testLegacyMigrationRetainsSelectedIdentityAndIgnoresOldPermissionFields() throws {
    let f = try Fixture(); defer { f.remove() }
    let legacy: JSONValue = .array([
      ["id": "a", "name": "First", "path": .string(f.root.appendingPathComponent("a").path), "enabled": true],
      ["id": "b", "name": "Selected", "path": .string(f.root.path), "enabled": false, "permissionMode": "ask"],
    ])
    f.defaults.set(try legacy.data(), forKey: "approvedProjects")
    f.defaults.set("b", forKey: "activeProjectID")
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertEqual(model.activeProject?.id, "b")
    XCTAssertEqual(model.activeProject?.path, f.root.path)
    XCTAssertTrue(model.canStart)
    XCTAssertNil(f.defaults.data(forKey: "approvedProjects"))
    XCTAssertNil(f.defaults.string(forKey: "activeProjectID"))
    let saved = try XCTUnwrap(f.defaults.data(forKey: "selectedFolder"))
    XCTAssertEqual(try JSONDecoder().decode(ApprovedProject.self, from: saved), model.activeProject)
    let reopened = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    XCTAssertEqual(reopened.activeProject, model.activeProject)
  }

  func testMigrationWithoutKnownSelectionRetainsFirstSavedFolder() throws {
    let f = try Fixture(); defer { f.remove() }
    let first = ApprovedProject(id: "a", url: f.root)
    let second = ApprovedProject(id: "b", url: f.root.appendingPathComponent("b"))
    for selected in [nil, "missing"] as [String?] {
      f.defaults.removeObject(forKey: "selectedFolder")
      f.defaults.set(try JSONEncoder().encode([first, second]), forKey: "approvedProjects")
      f.defaults.set(selected, forKey: "activeProjectID")
      let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
      XCTAssertEqual(model.activeProject, first)
      XCTAssertTrue(model.canStart)
    }
  }

  func testInvalidOrEmptyConfigurationClearsSelectionWithoutResurrectingLegacyFolders() throws {
    let f = try Fixture(); defer { f.remove() }
    for value in [nil, Data(), Data("not JSON".utf8), Data("[]".utf8)] as [Data?] {
      f.defaults.removeObject(forKey: "selectedFolder")
      f.defaults.set(value, forKey: "approvedProjects")
      f.defaults.set("stale", forKey: "activeProjectID")
      let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
      XCTAssertNil(model.activeProject)
      XCTAssertFalse(model.canStart)
      XCTAssertNil(f.defaults.object(forKey: "approvedProjects"))
      XCTAssertNil(f.defaults.object(forKey: "activeProjectID"))
    }
    f.defaults.set(Data("broken".utf8), forKey: "selectedFolder")
    f.defaults.set(try JSONEncoder().encode([ApprovedProject(url: f.root)]), forKey: "approvedProjects")
    XCTAssertNil(AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults).activeProject)
  }

  func testRemoveKeepsSourceAndActivityForReattachment() throws {
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
}
