import SwiftUI

struct HomeView: View {
  let model: AppModel
  let openProjects: () -> Void
  let openConnection: () -> Void

  var body: some View {
    MDPage {
      runtimeSection
      currentTaskSection

      MDSection(title: L10n.text("common.projects")) {
        MDNavigationRow(
          title: model.activeProject?.name ?? L10n.text("projects.noProjectsYet"),
          symbol: "folder",
          subtitle: model.activeProject?.path ?? L10n.text("projects.chooseLocalFolderProjectWorkspace"),
          prominent: model.activeProject == nil,
          iconTone: .purple,
          action: openProjects)
          .accessibilityIdentifier("home-project")
      }

      connectionSection

      if let error = model.errorText {
        InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
  }

  private var connectionSection: some View {
    MDSection(title: L10n.text("common.connection")) {
      MDNavigationRow(
        title: ConnectionProviderID.openAI.title,
        symbol: ConnectionProviderID.openAI.symbol,
        subtitle: model.savedTunnelID.isEmpty ? nil : model.savedTunnelID,
        detail: L10n.text(model.connectionStatusKey),
        iconTone: ConnectionProviderID.openAI.iconTone,
        accessory: nil,
        action: openConnection)
    }
    .accessibilityIdentifier("home-connection")
  }

  private var runtimeSection: some View {
    VStack(spacing: 22) {
      MDExpressiveIconSurface(
        symbol: runtimeSymbol, size: 92,
        animating: [.preparing, .starting, .stopping].contains(model.phase))
        .accessibilityElement()
        .accessibilityLabel(statusTitle)

      Button {
        if model.active {
          Task { await model.stop() }
        } else if model.activeProject == nil {
          openProjects()
        } else {
          model.requestStart()
        }
      } label: {
        if !model.active && model.activeProject == nil {
          Label(L10n.text("home.chooseProject"), systemImage: "folder.badge.plus")
            .frame(maxWidth: .infinity)
        } else {
          Label(
            model.active ? L10n.text("home.stop") : L10n.text("home.start"),
            systemImage: model.active ? "stop.fill" : "play.fill")
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(MDButtonStyle())
      .controlSize(.large)
      .disabled(model.contextBusy || model.phase == .stopping
        || (!model.active && model.activeProject != nil && !model.canLaunch))
      .accessibilityIdentifier("runtime-toggle")
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 24)
    .background(
      MDTheme.surfaceContainerLow,
      in: RoundedRectangle(cornerRadius: 28, style: .continuous))
  }

  private var currentTaskSection: some View {
    MDSection(title: L10n.text("home.currentTask")) {
      MDList {
        MDListRow(
          title: model.activeJobs > 0
            ? L10n.format("common.runningTasksCount", model.activeJobs)
            : L10n.text("home.idle"),
          symbol: model.activeJobs > 0 ? "bolt.fill" : "checkmark.circle",
          iconTone: model.activeJobs > 0 ? .orange : .green
        ) {
          if model.activeJobs > 0 {
            Button(role: .destructive) {
              Task { await model.stopActiveJobs() }
            } label: {
              Label(L10n.text("home.stopAllTasks"), systemImage: "stop.fill")
            }
            .buttonStyle(MDButtonStyle(kind: .tonal))
            .accessibilityIdentifier("stop-active-tasks")
          }
        }
      }
    }
  }

  private var runtimeSymbol: String {
    switch model.phase {
    case .failed:
      return "exclamationmark"
    case .running, .stopping:
      return "stop.fill"
    case .stopped, .preparing, .starting:
      return model.activeProject != nil ? "play.fill" : "folder.badge.plus"
    }
  }

  private var statusTitle: String {
    switch model.phase {
    case .stopped:
      if model.canLaunch { L10n.text("home.readyStart") }
      else if model.activeProject != nil && !model.connectionConfigured { L10n.text("home.configureTunnel") }
      else if model.activeProject != nil && model.hasUnsavedConnection { L10n.text("home.saveConnection") }
      else { L10n.text("home.notRunning") }
    case .preparing: L10n.text("common.preparing")
    case .starting: L10n.text("common.starting")
    case .running: L10n.text("common.running")
    case .stopping: L10n.text("common.stopping")
    case .failed: L10n.text("connection.runtimeFailed")
    }
  }

}
