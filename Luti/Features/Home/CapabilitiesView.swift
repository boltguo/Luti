import SwiftUI

/// Secondary capability diagnostics. Keep this out of Home so normal
/// execution stays focused on Runtime, current task, Project and Connection.
struct CapabilitiesView: View {
  let model: AppModel

  var body: some View {
    MDSection(title: L10n.text("settings.capabilityDiagnostics")) {
      MDList {
        row(
          L10n.text("capability.projectFiles"),
          symbol: "folder",
          value: model.project == nil ? L10n.text("common.notSelected") : L10n.text("common.ready"),
          ready: model.project != nil,
          position: .first,
          tone: .purple)

        row(
          L10n.text("capability.commandExecution"),
          symbol: "terminal",
          value: executionStatus,
          ready: model.phase == .running,
          position: .middle,
          tone: .green)

        row(
          L10n.text("capability.browserAutomation"),
          symbol: "globe",
          value: browserStatus,
          ready: BrowserInstallation.installed && BrowserInstallation.chromeAvailable,
          position: .middle,
          tone: .blue)

        row(
          L10n.text("capability.desktopControl"),
          symbol: "rectangle.and.hand.point.up.left",
          value: desktopStatus,
          ready: model.permissions.screen && model.permissions.accessibility,
          position: .last,
          tone: .pink)
      }
    }
  }

  private var executionStatus: String {
    switch model.phase {
    case .stopped: return L10n.text("capability.startRequired")
    case .preparing, .starting: return L10n.text("capability.starting")
    case .running:
      if model.activeJobs > 0 {
        return L10n.format("common.runningTasksCount", model.activeJobs)
      }
      switch model.executionPolicy.profile {
      case .readOnly:
        return L10n.text("capability.readOnly")
      case .workspace, .isolated:
        return L10n.text("capability.sandboxPending")
      case .fullLocal:
        return L10n.text("capability.fullLocalNotSandboxed")
      }
    case .stopping: return L10n.text("common.stopping")
    case .failed: return L10n.text("capability.retryNeeded")
    }
  }

  private var browserStatus: String {
    guard BrowserInstallation.chromeAvailable else {
      return L10n.text("capability.chromeRequired")
    }
    return BrowserInstallation.installed
      ? L10n.text("common.ready")
      : L10n.text("capability.preparesFirstUse")
  }

  private var desktopStatus: String {
    if model.permissions.screen && model.permissions.accessibility {
      return L10n.text("common.granted")
    }
    if model.permissions.screen || model.permissions.accessibility {
      return L10n.text("capability.partiallyAllowed")
    }
    return L10n.text("capability.notAllowed")
  }

  private func row(
    _ title: String,
    symbol: String,
    value: String,
    ready: Bool,
    position: MDListRowPosition,
    tone: MDIconTone
  ) -> some View {
    MDListRow(
      title: title,
      symbol: symbol,
      subtitle: value,
      position: position,
      iconTone: tone
    ) {
      Circle()
        .fill(ready ? MDTheme.success : MDTheme.outline)
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)
    }
  }
}
