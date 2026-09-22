import SwiftUI

struct HomeView: View {
  let model: AppModel
  let openProjects: () -> Void
  let openConnection: () -> Void

  var body: some View {
    MDPage {
      runtimeSection
      currentTaskSection

      HomeQuickChoice(
        title: L10n.text("common.projects"),
        emptyTitle: L10n.text("projects.noProjectsEnabled"),
        emptySubtitle: L10n.text("projects.enableProjectFromProjects"),
        symbol: "folder",
        iconTone: .purple,
        choices: model.enabledProjects.map {
          HomeQuickChoice.Choice(id: $0.id, title: $0.name, subtitle: $0.path)
        },
        selectedID: model.activeProjectID,
        selectionEnabled: !model.active && !model.contextBusy,
        select: model.setActiveProject,
        manage: openProjects
      )
      .accessibilityIdentifier("home-project")

      connectionSection

      if let error = model.errorText {
        InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
  }

  private var connectionSection: some View {
    MDSection(title: L10n.text("common.connection")) {
      if model.availableConnectionProviders.isEmpty {
        MDNavigationRow(
          title: L10n.text("connection.noEnabledProvider"),
          symbol: "link",
          subtitle: L10n.text("connection.enableProviderFromConnection"),
          prominent: true,
          iconTone: .blue,
          action: openConnection)
      } else {
        MDList {
          ForEach(
            Array(model.availableConnectionProviders.enumerated()),
            id: \.element
          ) { index, provider in
            MDListRow(
              title: providerTitle(provider),
              symbol: provider.symbol,
              subtitle: providerSubtitle(provider),
              position: MDListRowPosition(
                index: index, count: model.availableConnectionProviders.count),
              iconTone: provider.iconTone,
              textLineLimit: 1,
              subtitleTruncationMode: .tail,
              leadingWidth: 40
            ) {
              Text(providerStatus(provider))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(providerStatusColor(provider))
                .lineLimit(1)
            }
            .frame(height: 60)
          }
        }
      }
    }
    .accessibilityIdentifier("home-connection")
  }

  private var runtimeSection: some View {
    VStack(spacing: 22) {
      MDExpressiveIconSurface(symbol: runtimeSymbol, size: 92)
        .accessibilityElement()
        .accessibilityLabel(statusTitle)

      Button {
        if model.active {
          Task { await model.stop() }
        } else if model.activeProject?.enabled != true {
          openProjects()
        } else {
          model.requestStart()
        }
      } label: {
        if !model.active && model.activeProject?.enabled != true {
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
      .disabled(model.contextBusy || model.phase == .stopping)
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
          subtitle: model.activeJobs > 0
            ? L10n.text("home.taskRunningDescription")
            : L10n.text("home.idleDescription"),
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

  private func providerTitle(_ id: ConnectionProviderID) -> String {
    id.title
  }

  private func providerSubtitle(_ id: ConnectionProviderID) -> String? {
    let address = model.savedProviderAddress(id)
    return address.isEmpty ? nil : address
  }

  private func providerStatus(_ id: ConnectionProviderID) -> String {
    let state = model.providerSnapshot(id).state
    if model.phase == .running || state != .stopped {
      return L10n.text("connection.state." + state.rawValue)
    }
    return L10n.text("common.enabled")
  }

  private func providerStatusColor(_ id: ConnectionProviderID) -> Color {
    switch model.providerSnapshot(id).state {
    case .ready: MDTheme.success
    case .failed: MDTheme.error
    case .starting, .reconnecting, .stopping: MDTheme.warning
    case .stopped: MDTheme.onSurfaceVariant
    }
  }

  private var runtimeSymbol: String {
    switch model.phase {
    case .failed:
      return "exclamationmark"
    case .running, .stopping:
      return "stop.fill"
    case .stopped, .preparing, .starting:
      return model.activeProject?.enabled == true ? "play.fill" : "folder.badge.plus"
    }
  }

  private var statusTitle: String {
    switch model.phase {
    case .stopped: model.canStart ? L10n.text("home.readyStart") : L10n.text("home.notRunning")
    case .preparing: L10n.text("common.preparing")
    case .starting: L10n.text("common.starting")
    case .running: L10n.text("common.running")
    case .stopping: L10n.text("common.stopping")
    case .failed: L10n.text("connection.runtimeFailed")
    }
  }

  private var statusDescription: String? {
    switch model.phase {
    case .stopped:
      if model.activeProject?.enabled != true { return L10n.text("home.addProjectGetStarted") }
      return nil
    case .preparing: return L10n.text("connection.preparingLocal")
    case .starting: return L10n.text("connection.startingLocal")
    case .running: return nil
    case .stopping: return L10n.text("home.disconnectingStoppingSessionsTasks")
    case .failed: return L10n.text("home.checkErrorDetailsTryingAgain")
    }
  }
}

private struct HomeQuickChoice: View {
  struct Choice: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
  }

  let title: String
  let emptyTitle: String
  let emptySubtitle: String
  let symbol: String
  let iconTone: MDIconTone
  let choices: [Choice]
  let selectedID: String?
  let selectionEnabled: Bool
  let select: (String) -> Void
  let manage: () -> Void

  @State private var expanded = false

  private var selected: Choice? {
    choices.first(where: { $0.id == selectedID }) ?? choices.first
  }

  var body: some View {
    MDSection(title: title) {
      if choices.isEmpty {
        MDNavigationRow(
          title: emptyTitle,
          symbol: symbol,
          subtitle: emptySubtitle,
          prominent: true,
          iconTone: iconTone,
          action: manage)
      } else if choices.count == 1, let choice = choices.first {
        MDListRow(
          title: choice.title,
          symbol: symbol,
          subtitle: choice.subtitle,
          iconTone: iconTone,
          textLineLimit: 1,
          subtitleTruncationMode: .tail,
          leadingWidth: 40
        ) {
          EmptyView()
        }
        .frame(height: 60)
      } else if expanded {
        expandedList
      } else if let selected {
        Button {
          guard selectionEnabled else { return }
          expanded = true
        } label: {
          MDListRow(
            title: selected.title,
            symbol: symbol,
            subtitle: selected.subtitle,
            iconTone: iconTone,
            textLineLimit: 1,
            subtitleTruncationMode: .tail,
            leadingWidth: 40
          ) {
            Image(systemName: "chevron.down")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(MDTheme.onSurfaceVariant)
              .accessibilityHidden(true)
          }
          .frame(height: 60)
        }
        .buttonStyle(.plain)
        .disabled(!selectionEnabled)
        .accessibilityLabel(title + ": " + selected.title)
        .accessibilityValue(L10n.text(expanded ? "ui.expanded" : "ui.collapsed"))
      }
    }
  }

  @ViewBuilder private var expandedList: some View {
    MDList {
      ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
        let isSelected = choice.id == selected?.id
        let position = MDListRowPosition(index: index, count: choices.count)
        Button {
          guard selectionEnabled else { return }
          select(choice.id)
          expanded = false
        } label: {
          HStack(spacing: 12) {
            MDRadioMark(isSelected: isSelected)
              .frame(width: 40, height: 40)

            choiceText(choice)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(height: 60)
          .background(MDListRowSurface(position: position))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectionEnabled)
        .accessibilityLabel(choice.title)
        .accessibilityValue(
          isSelected
            ? L10n.text("projects.selected")
            : L10n.text("common.notSelected"))
      }
    }
  }

  private func choiceText(_ choice: Choice) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(choice.title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(MDTheme.onSurface)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(choice.title)
      if let subtitle = choice.subtitle {
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(subtitle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
