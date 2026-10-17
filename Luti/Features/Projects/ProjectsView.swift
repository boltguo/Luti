import AppKit
import SwiftUI

struct ProjectsView: View {
  let model: AppModel

  var body: some View {
    if let project = model.activeProject {
      ProjectDetailView(model: model, project: project)
        .id(project.id)
    } else {
      MDPage {
        Button(action: model.chooseProject) {
          MDEmptyState(
            title: L10n.text("projects.chooseFolder"),
            message: L10n.text("projects.chooseLocalFolderProjectWorkspace"),
            symbol: "folder.badge.plus")
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("project-empty-state")
        }
        .buttonStyle(.plain)
        .disabled(model.active || model.contextBusy)
        .accessibilityLabel(L10n.text("projects.chooseFolder"))
        .accessibilityIdentifier("add-project")
      }
    }
  }
}

private struct ProjectDetailView: View {
  let model: AppModel
  let project: ApprovedProject
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
    MDPage {
      Text(project.name)
        .font(.system(size: 22, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("project-title")

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
          set: { model.setPermissionMode($0 ? .fullProjectAccess : .ask) }),
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
