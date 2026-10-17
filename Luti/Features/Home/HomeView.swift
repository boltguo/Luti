import SwiftUI

struct HomeView: View {
  let model: AppModel
  let openProjects: () -> Void

  var body: some View {
    MDPage {
      runtimeSection
      if model.toolListChanged { toolListNotice }
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

  private struct EnabledConnectionItem: Identifiable {
    let id: ConnectionProviderID
    let status: String
  }

  private var enabledConnections: [EnabledConnectionItem] {
    var items: [EnabledConnectionItem] = []
    if model.openAIEnabled {
      items.append(EnabledConnectionItem(
        id: .openAI,
        status: L10n.text(model.connectionStatusKey)))
    }
    if model.cloudflare.enabled {
      items.append(EnabledConnectionItem(
        id: .cloudflare,
        status: L10n.text(model.cloudflare.authorization.pending.isEmpty
          ? model.cloudflare.statusKey : "cloudflare.pending")))
    }
    return items
  }

  private var connectionSection: some View {
    MDSection(title: L10n.text("common.connection")) {
      MDList {
        if enabledConnections.isEmpty {
          MDListRow(
            title: L10n.text("common.disabled"),
            symbol: "link",
            iconTone: .gray
          ) {
            Text(L10n.text("connection.notConfigured"))
              .font(.system(size: 12))
              .foregroundStyle(MDTheme.onSurfaceVariant)
              .lineLimit(1)
          }
        } else {
          ForEach(Array(enabledConnections.enumerated()), id: \.element.id) { index, item in
            MDListRow(
              title: item.id.title,
              symbol: item.id.symbol,
              position: MDListRowPosition(index: index, count: enabledConnections.count),
              iconTone: item.id.iconTone
            ) {
              Text(item.status)
                .font(.system(size: 12))
                .foregroundStyle(MDTheme.onSurfaceVariant)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .accessibilityIdentifier("home-connection")
  }

  private var runtimeSection: some View {
    VStack(spacing: 22) {
      MDExpressiveIconSurface(
        symbol: runtimeSymbol, size: 92,
        animating: true)
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

      if !model.active && model.activeProject != nil {
        Text(L10n.text("home.accessNotice"))
          .font(.footnote)
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 24)
    .background(
      MDTheme.surfaceContainerLow,
      in: RoundedRectangle(cornerRadius: 28, style: .continuous))
  }

  private var toolListNotice: some View {
    MDListRow(
      title: L10n.text("home.toolsUpdated"),
      symbol: "arrow.triangle.2.circlepath",
      subtitle: L10n.text("home.toolsUpdatedDescription"),
      iconTone: .orange,
      textLineLimit: 3,
      subtitleTruncationMode: .tail
    ) {
      MDIconActionButton(symbol: "xmark", label: L10n.text("common.close")) {
        model.dismissToolListNotice()
      }
      .accessibilityIdentifier("dismiss-tools-updated")
    }
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
      else if model.activeProject != nil && !model.anyConnectionConfigured { L10n.text("home.configureTunnel") }
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
