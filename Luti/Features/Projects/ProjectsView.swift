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
  @State private var showingActivity = false

  var body: some View {
    if showingActivity {
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

      MDListRow(
        title: L10n.text("projects.projectFolder"),
        symbol: "folder",
        subtitle: project.path,
        iconTone: .purple
      ) { EmptyView() }

      MDNavigationRow(
        title: L10n.text("context.activity"), symbol: "list.bullet.rectangle",
        subtitle: L10n.text("context.activityDescription"), iconTone: .green
      ) {
        showingActivity = true
      }
      .accessibilityIdentifier("project-activity")

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
}
