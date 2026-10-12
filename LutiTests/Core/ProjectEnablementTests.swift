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
}
