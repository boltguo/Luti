import AppKit
import SwiftUI

struct ProjectsView: View {
  let model: AppModel
  @State private var selectedProjectID: String?

  var body: some View {
    if let project = model.approvedProjects.first(where: { $0.id == selectedProjectID }) {
      ProjectDetailView(model: model, project: project, back: { selectedProjectID = nil })
        .id(project.id)
    } else {
      projectList
    }
  }

  private var projectList: some View {
    MDPage {
      MDSection(title: L10n.text("common.projects")) {
        if model.approvedProjects.isEmpty {
          MDEmptyState(
            title: L10n.text("projects.noProjectsYet"),
            message: L10n.text("projects.chooseLocalFolderProjectWorkspace"),
            symbol: "folder.badge.plus")
            .accessibilityIdentifier("project-empty-state")
        } else {
          MDList {
            ForEach(Array(model.approvedProjects.enumerated()), id: \.element.id) { index, project in
              let current = model.activeProject?.id == project.id
              MDSplitActionRow(
                title: project.name, symbol: "folder", subtitle: project.path,
                position: MDListRowPosition(index: index, count: model.approvedProjects.count),
                iconTone: current ? .purple : .blue,
                accessory: "chevron.right", action: { selectedProjectID = project.id }
              ) {
                Button { model.selectProject(project.id) } label: {
                  HStack(spacing: 0) {
                    MDRadioMark(isSelected: current)
                    Text(L10n.text(current ? "projects.current" : "projects.use"))
                      .font(.system(size: 12, weight: current ? .semibold : .regular))
                  }
                  .foregroundStyle(current ? MDTheme.primary : MDTheme.onSurfaceVariant)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.active)
                .opacity(model.active && !current ? 0.38 : 1)
                .accessibilityLabel(L10n.format("projects.useProject", project.name))
                .accessibilityValue(L10n.text(current ? "projects.selected" : "common.notSelected"))
                .accessibilityIdentifier("select-project-" + project.id)
              }
              .disabled(model.contextBusy)
              .accessibilityIdentifier("project-" + project.id)
            }
          }
        }
      }

      if model.active {
        InlineNotice(text: L10n.text("projects.stopRuntimeToEditProject"), icon: "lock")
      }
      Color.clear.frame(height: 56)
    }
    .overlay(alignment: .bottomTrailing) {
      MDFloatingActionButton(label: L10n.text("projects.addProject"), action: model.chooseProject)
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("add-project")
        .padding(20)
    }
  }
}

struct ProjectDetailView: View {
  let model: AppModel
  let project: ApprovedProject
  let back: () -> Void
  @State private var showingMemory = false
  @State private var showingActivity = false
  @State private var memoryCount: Int?

  var body: some View {
    if showingMemory {
      ProjectMemoryView(model: model, project: project, back: { showingMemory = false })
    } else if showingActivity {
      ProjectActivityView(model: model, project: project, back: { showingActivity = false })
    } else {
      rootPage
    }
  }

  private var rootPage: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: project.name, back: back)
        .accessibilityIdentifier("project-title")

      MDPage {
        permissionModeRow

        MDListRow(
          title: L10n.text("projects.projectFolder"),
          symbol: "folder",
          subtitle: project.path,
          iconTone: .purple
        ) { EmptyView() }

        MDList {
          MDNavigationRow(
            title: L10n.text("context.memory"), symbol: "brain",
            subtitle: L10n.text("context.memoryDescription"),
            detail: memoryCount.map(String.init), position: .first, iconTone: .blue
          ) {
            showingMemory = true
          }
          .accessibilityIdentifier("project-memory")

          MDNavigationRow(
            title: L10n.text("context.activity"), symbol: "list.bullet.rectangle",
            subtitle: L10n.text("context.activityDescription"), position: .last, iconTone: .green
          ) {
            showingActivity = true
          }
          .accessibilityIdentifier("project-activity")
        }

        MDSection(title: L10n.text("projects.projectActions")) {
          MDButtonRun {
            Button {
              NSWorkspace.shared.selectFile(project.path, inFileViewerRootedAtPath: "")
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(L10n.text("projects.showFinder"))
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                  .font(.system(size: 10, weight: .semibold))
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
            .frame(maxWidth: .infinity)

            Button(role: .destructive) { model.removeProject(project.id) } label: {
              HStack(spacing: 8) {
                Image(systemName: "trash")
                Text(L10n.text("projects.removeProject"))
                Spacer(minLength: 4)
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .last))
            .frame(maxWidth: .infinity)
            .disabled(model.active || model.contextBusy)
            .accessibilityIdentifier("remove-project")
          }
        }
        if model.active {
          InlineNotice(text: L10n.text("projects.stopRuntimeToEditProject"), icon: "lock")
        }
      }
    }
    .task(id: model.lastCall) {
      await reloadMemoryCount()
    }
  }

  private var permissionModeRow: some View {
    let full = project.permissionMode == .fullProjectAccess
    return MDListRow(
      title: L10n.text(full ? "permissionMode.fullProjectAccess" : "permissionMode.ask"),
      symbol: full ? "exclamationmark.shield" : "checkmark.shield",
      subtitle: L10n.text(
        full ? "permissionMode.fullProjectAccessDescription" : "permissionMode.askDescription"),
      iconTone: full ? .orange : .green
    ) {
      MDSwitch(
        isOn: Binding(
          get: { full },
          set: { model.setPermissionMode($0 ? .fullProjectAccess : .ask, for: project.id) }),
        label: L10n.text("permissionMode.fullProjectAccess"))
        .disabled(model.contextBusy)
        .accessibilityIdentifier("project-full-access")
    }
  }

  private func reloadMemoryCount() async {
    let root = model.contextDataRoot
    let count = try? await Task.detached(priority: .utility) {
      try ProjectMemoryStore(project: project, dataRoot: root).snapshot().memoryCount
    }.value
    guard !Task.isCancelled else { return }
    memoryCount = count
  }
}
