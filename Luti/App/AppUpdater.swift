import Combine
import Foundation
import Sparkle

/// One updater for the entire app lifetime. Sparkle owns scheduling, download
/// verification and installation; AppDelegate owns graceful runtime shutdown.
@MainActor final class AppUpdater: ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false
  private let controller: SPUStandardUpdaterController

  init(startingUpdater: Bool? = nil) {
    let environment = ProcessInfo.processInfo.environment
    let isTestOrPreview = environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || NSClassFromString("XCTestCase") != nil
      || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    controller = SPUStandardUpdaterController(
      startingUpdater: startingUpdater ?? !isTestOrPreview,
      updaterDelegate: nil,
      userDriverDelegate: nil)
    controller.updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
    controller.updater.publisher(for: \.automaticallyChecksForUpdates)
      .assign(to: &$automaticallyChecksForUpdates)
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller.updater.automaticallyChecksForUpdates = enabled
  }

  func checkForUpdates() {
    guard canCheckForUpdates else { return }
    controller.checkForUpdates(nil)
  }
}
