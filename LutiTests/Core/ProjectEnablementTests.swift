import XCTest

@testable import Luti

@MainActor final class ProjectEnablementTests: XCTestCase {
  func testAddingProjectsEnablesAllAndKeepsOneActiveProject() throws {
    let first = try Fixture(), second = try Fixture()
    defer { first.remove(); second.remove() }
    let model = AppModel(contextDataRoot: first.contextDataRoot, defaults: first.defaults)

    model.addApprovedProjects([first.root, second.root])

    XCTAssertEqual(model.approvedProjects.count, 2)
    XCTAssertEqual(model.enabledProjects.count, 2)
    XCTAssertTrue(model.approvedProjects.allSatisfy(\.enabled))
    XCTAssertEqual(model.activeProjectID, model.approvedProjects.first?.id)
  }

  func testPersistedMultipleEnabledProjectsSurviveMigrationUnchanged() throws {
    let f = try Fixture(); defer { f.remove() }
    let a = ApprovedProject(id: "a", url: f.root.appendingPathComponent("a"), enabled: true)
    let b = ApprovedProject(id: "b", url: f.root.appendingPathComponent("b"), enabled: true)
    let c = ApprovedProject(id: "c", url: f.root.appendingPathComponent("c"), enabled: false)
    f.defaults.set(try JSONEncoder().encode([a, b, c]), forKey: "approvedProjects")
    f.defaults.set("b", forKey: "activeProjectID")

    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)

    XCTAssertEqual(model.enabledProjects.map(\.id), ["a", "b"])
    XCTAssertEqual(model.activeProjectID, "b")
    XCTAssertEqual(model.approvedProjects.map(\.enabled), [true, true, false])

    let persisted = try XCTUnwrap(f.defaults.data(forKey: "approvedProjects"))
    XCTAssertEqual(try JSONDecoder().decode([ApprovedProject].self, from: persisted).map(\.enabled),
                   [true, true, false])
  }

  func testDisablingActiveProjectSelectsAnotherEnabledProject() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let a = ApprovedProject(id: "a", url: f.root.appendingPathComponent("a"))
    let b = ApprovedProject(id: "b", url: f.root.appendingPathComponent("b"))
    model.approvedProjects = [a, b]
    model.activeProjectID = "a"

    model.setProjectEnabled("a", enabled: false)
    XCTAssertEqual(model.enabledProjects.map(\.id), ["b"])
    XCTAssertEqual(model.activeProjectID, "b")

    model.setProjectEnabled("b", enabled: false)
    XCTAssertTrue(model.enabledProjects.isEmpty)
    XCTAssertNil(model.activeProjectID)

    model.setProjectEnabled("a", enabled: true)
    XCTAssertEqual(model.enabledProjects.map(\.id), ["a"])
    XCTAssertEqual(model.activeProjectID, "a")
  }

  func testEnabledMutationStillObeysRuntimeAndContextBusySafety() throws {
    let f = try Fixture(); defer { f.remove() }
    let model = AppModel(contextDataRoot: f.contextDataRoot, defaults: f.defaults)
    let project = ApprovedProject(id: "a", url: f.root)
    model.approvedProjects = [project]
    model.activeProjectID = project.id

    model.phase = .running
    model.setProjectEnabled(project.id, enabled: false)
    XCTAssertTrue(model.approvedProjects[0].enabled)

    model.phase = .stopped
    model.contextBusy = true
    model.setProjectEnabled(project.id, enabled: false)
    XCTAssertTrue(model.approvedProjects[0].enabled)

    model.contextBusy = false
    model.setProjectEnabled(project.id, enabled: false)
    XCTAssertFalse(model.approvedProjects[0].enabled)
  }

  func testRouterListsEveryEnabledProjectAndSwitchesOnlyWithinThatSet() async throws {
    let first = try Fixture(), second = try Fixture(), third = try Fixture()
    defer { first.remove(); second.remove(); third.remove() }
    let a = ApprovedProject(id: "a", url: first.root, enabled: true)
    let b = ApprovedProject(id: "b", url: second.root, enabled: true)
    let c = ApprovedProject(id: "c", url: third.root, enabled: false)
    let router = try ToolRouter(
      workspace: first.files, jobs: JobManager(helper: Fixture.helper),
      images: ImageStore(), computer: NoComputerBackend(), activity: ActivityStore(),
      executionPolicy: .readOnly, approvedProjects: [a, b, c], activeProjectID: a.id,
      contextDataRoot: first.contextDataRoot)
    addTeardownBlock { await router.stop() }

    let list = await router.callInCurrentProject("projects", arguments: ["action": "list"])
    XCTAssertEqual(list.data["projects"].array?.compactMap { $0["id"].string }, ["a", "b"])
    XCTAssertEqual(list.data["projects"].array?.filter { $0["active"] == true }.count, 1)

    let switched = await router.callInCurrentProject(
      "projects", arguments: ["action": "switch", "projectId": "b"])
    XCTAssertEqual(switched.data["changed"], true)
    XCTAssertEqual(switched.data["project"]["id"], "b")

    let blocked = await router.callInCurrentProject(
      "projects", arguments: ["action": "switch", "projectId": "c"])
    XCTAssertTrue(blocked.isError)
    XCTAssertEqual(blocked.data["error"], "project_not_enabled")
    let current = await router.callInCurrentProject("projects", arguments: ["action": "current"])
    XCTAssertEqual(current.data["project"]["id"], "b")
  }

  func testRuntimeCannotStartWithOnlyDisabledApprovedProjects() throws {
    let f = try Fixture(); defer { f.remove() }
    let disabled = ApprovedProject(id: "disabled", url: f.root, enabled: false)
    XCTAssertThrowsError(try ToolRouter(
      workspace: f.files, jobs: JobManager(helper: Fixture.helper),
      images: ImageStore(), computer: NoComputerBackend(), activity: ActivityStore(),
      approvedProjects: [disabled], activeProjectID: disabled.id, contextDataRoot: f.contextDataRoot
    )) { error in
      XCTAssertEqual((error as? Failure)?.code, "project_not_enabled")
    }
  }
}
