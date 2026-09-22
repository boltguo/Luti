import ServiceManagement
import XCTest

@testable import Luti

@MainActor final class LoginItemControllerTests: XCTestCase {
  func testOpeningSettingsDoesNotRegisterALoginItem() async {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    controller.refresh()
    controller.openSettings()
    XCTAssertFalse(controller.isRequested)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
  }

  func testEnableAndDisableFollowSystemStatus() async {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    XCTAssertEqual(controller.status, .enabled)
    XCTAssertTrue(controller.isRequested)
    controller.setEnabled(false)
    XCTAssertEqual(controller.status, .notRegistered)
    XCTAssertFalse(controller.isRequested)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.unregisterCount, 1)
  }

  func testPendingApprovalCanBeCancelled() async {
    let service = FakeLoginItemService()
    service.registrationStatus = .requiresApproval
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    XCTAssertEqual(controller.status, .requiresApproval)
    XCTAssertTrue(controller.isRequested)
    controller.setEnabled(false)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(controller.status, .notRegistered)
  }

  func testFailedRegistrationShowsErrorAndKeepsActualState() async {
    let service = FakeLoginItemService()
    service.shouldFail = true
    let controller = LoginItemController(service: service)
    controller.setEnabled(true)
    XCTAssertNotNil(controller.errorMessage)
    XCTAssertFalse(controller.isRequested)
    service.shouldFail = false
    controller.setEnabled(true)
    XCTAssertNil(controller.errorMessage)
    XCTAssertTrue(controller.isRequested)
  }

  func testFailedRemovalKeepsEnabledState() async {
    let service = FakeLoginItemService()
    service.status = .enabled
    service.shouldFail = true
    let controller = LoginItemController(service: service)
    controller.setEnabled(false)
    XCTAssertNotNil(controller.errorMessage)
    XCTAssertTrue(controller.isRequested)
  }

  func testExternalChangesAreRefreshedBeforeUpdating() async {
    let service = FakeLoginItemService()
    let controller = LoginItemController(service: service)
    service.status = .enabled
    controller.setEnabled(true)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertTrue(controller.isRequested)
    service.status = .notRegistered
    controller.refresh()
    XCTAssertFalse(controller.isRequested)
  }
}

@MainActor private final class FakeLoginItemService: LoginItemServicing {
  var status: SMAppService.Status = .notRegistered
  var registrationStatus: SMAppService.Status = .enabled
  var shouldFail = false
  var registerCount = 0
  var unregisterCount = 0
  var openSettingsCount = 0
  private enum Failure: Error { case rejected }

  func register() throws {
    registerCount += 1
    if shouldFail { throw Failure.rejected }
    status = registrationStatus
  }
  func unregister() throws {
    unregisterCount += 1
    if shouldFail { throw Failure.rejected }
    status = .notRegistered
  }
  func openSettings() { openSettingsCount += 1 }
}
