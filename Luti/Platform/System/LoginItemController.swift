import Foundation
import Observation
import ServiceManagement

@MainActor protocol LoginItemServicing {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
  func openSettings()
}

@MainActor struct SystemLoginItemService: LoginItemServicing {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable final class LoginItemController {
  private(set) var status: SMAppService.Status
  private(set) var errorMessage: String?
  @ObservationIgnored private let service: any LoginItemServicing

  // The system is the source of truth. Opening the app never registers a login item.
  init(service: any LoginItemServicing = SystemLoginItemService()) {
    self.service = service
    status = service.status
  }

  var isRequested: Bool { status == .enabled || status == .requiresApproval }

  func refresh() { status = service.status }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    refresh()
    guard enabled != isRequested else { return }
    do {
      if enabled { try service.register() } else { try service.unregister() }
    } catch {
      errorMessage = L10n.format("login.error", error.localizedDescription)
    }
    refresh()
  }

  func openSettings() { service.openSettings() }
}
