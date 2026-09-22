import AppKit
import SwiftUI

struct ProjectsView: View {
  let model: AppModel
  @Binding var selectedProjectID: String?
  @State private var query = ""

  private var visibleProjects: [ApprovedProject] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.approvedProjects.filter {
      term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) || $0.path.localizedCaseInsensitiveContains(term)
    }
  }

  var body: some View {
    Group {
      if let project = model.approvedProjects.first(where: { $0.id == selectedProjectID }) {
        ProjectDetailView(model: model, project: project) { selectedProjectID = nil }
          .id(project.id)
      } else {
        projectList
      }
    }
    .onChange(of: model.approvedProjects.map(\.id)) { _, ids in
      if let selectedProjectID, !ids.contains(selectedProjectID) { self.selectedProjectID = nil }
    }
  }

  private var projectList: some View {
    MDPage {
      HStack {
        Text(L10n.text("common.projects"))
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(L10n.format("projects.enabledCount", model.enabledProjects.count))
          .font(.system(size: 12))
      }.foregroundStyle(MDTheme.onSurfaceVariant)
      if model.approvedProjects.count > 6 || !query.isEmpty {
        MDSearchField(prompt: L10n.text("projects.searchProjects"), text: $query)
          .accessibilityIdentifier("project-search")
      }
      if model.approvedProjects.isEmpty {
        MDEmptyState(
          title: L10n.text("projects.noProjectsYet"),
          message: L10n.text("projects.chooseLocalFolderProjectWorkspace"),
          symbol: "folder.badge.plus")
      } else if visibleProjects.isEmpty {
        MDEmptyState(
          title: L10n.text("projects.noMatchingProjects"),
          symbol: "magnifyingglass")
      } else {
        MDList {
          ForEach(Array(visibleProjects.enumerated()), id: \.element.id) { index, project in
            ProjectListRow(
              model: model,
              project: project,
              position: MDListRowPosition(index: index, count: visibleProjects.count),
              open: { selectedProjectID = project.id }
            )
            .accessibilityIdentifier("project-" + project.id)
          }
        }
      }
      if model.active {
        InlineNotice(text: L10n.text("projects.stopSessionAddProjects"), icon: "lock")
      }
    }
    .overlay(alignment: .bottomTrailing) {
      MDFloatingActionButton(label: L10n.text("projects.addProject"), action: model.chooseProject)
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("add-project")
        .padding(20)
    }
  }

}

private struct ProjectListRow: View {
  let model: AppModel
  let project: ApprovedProject
  let position: MDListRowPosition
  let open: () -> Void
  var body: some View {
    MDSplitActionRow(
      title: project.name,
      symbol: "folder",
      subtitle: project.path,
      position: position,
      iconTone: stableTone,
      accessory: "chevron.right",
      action: open
    ) {
      MDSwitch(
        isOn: Binding(
          get: {
            model.approvedProjects.first(where: { $0.id == project.id })?.enabled ?? false
          },
          set: { model.setProjectEnabled(project.id, enabled: $0) }),
        label: L10n.text("common.enabled"))
        .disabled(model.active || model.contextBusy)
        .accessibilityIdentifier("project-enabled-" + project.id)
    }
    .accessibilityLabel(L10n.text("projects.viewProjectDetails") + " " + project.name)
  }

  private var stableTone: MDIconTone {
    let palette: [MDIconTone] = [.purple, .blue, .green, .orange, .pink, .yellow]
    let hash = project.id.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return palette[Int(hash % UInt64(palette.count))]
  }
}

private struct ProjectDetailView: View {
  private enum Page: Hashable {
    case root
    case context(ProjectContextSelection)
    case recovery
    case clearContext
  }

  let model: AppModel
  let project: ApprovedProject
  let back: () -> Void
  @State private var page: Page = .root
  @State private var snapshot: ProjectSkillSnapshot?
  @State private var loadError: String?
  @State private var refreshID = 0
  @State private var confirmRemoval = false
  @State private var skillQuery = ""
  private var currentProject: ApprovedProject {
    model.approvedProjects.first(where: { $0.id == project.id }) ?? project
  }
  private var filteredSkills: [ProjectSkillItem] {
    let term = skillQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return (snapshot?.skills ?? []).filter {
      term.isEmpty || [$0.name, $0.description, $0.source].contains { $0.localizedCaseInsensitiveContains(term) }
    }
  }

  var body: some View {
    Group {
      switch page {
      case .root:
        rootPage
      case .context(let selection):
        ProjectContextBrowser(
          model: model,
          project: project,
          selection: selection,
          back: { page = .root })
      case .recovery:
        ProjectRecoveryView(
          model: model,
          project: project,
          back: { page = .root })
      case .clearContext:
        ProjectContextClearView(
          model: model,
          project: project,
          close: { page = .root })
      }
    }
    .task(id: refreshID) { await loadSkills() }
    .sheet(isPresented: $confirmRemoval) {
      MDConfirmDialog(
        title: L10n.text("projects.removeProjectConfirmation"),
        message: L10n.text("projects.onlyRemovesProjectListFilesDisk"),
        confirmTitle: L10n.text("projects.removeProject"),
        icon: "trash.fill"
      ) {
        guard !model.active else { return }
        model.removeProject(project.id)
        back()
      }
    }
  }

  private var rootPage: some View {
    VStack(spacing: 0) {
      MDDetailHeader(title: project.name, back: back)
      MDPage {
        MDList {
          MDListRow(
            title: L10n.text("permissionMode.title"),
            symbol: "folder.badge.gearshape",
            subtitle: currentProject.permissionMode == .fullProjectAccess
              ? L10n.text("permissionMode.fullProjectAccessDescription")
              : L10n.text("permissionMode.askDescription"),
            position: .first,
            iconTone: .purple
          ) {
            MDSwitch(
              isOn: Binding(
                get: { currentProject.permissionMode == .fullProjectAccess },
                set: { enabled in
                  model.setProjectPermissionMode(
                    project.id, mode: enabled ? .fullProjectAccess : .ask)
                }
              ),
              label: L10n.text("permissionMode.fullProjectAccess")
            )
            .disabled(model.active || model.contextBusy)
            .accessibilityIdentifier("project-full-access")
          }
          MDListRow(
            title: L10n.text("projects.projectFolder"),
            symbol: "folder",
            subtitle: project.path,
            position: .last,
            iconTone: .purple
          ) { EmptyView() }
        }
        ProjectContextSection(
          model: model,
          project: project,
          openContext: { page = .context($0) },
          openRecovery: { page = .recovery },
          openClearContext: { page = .clearContext })
        skillsSection
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

            Button(role: .destructive) { confirmRemoval = true } label: {
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

  private var skillsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(L10n.text("projects.skills")).font(.system(size: 13, weight: .semibold))
        if let snapshot {
          Text(String(snapshot.skills.count)).font(.system(size: 12)).foregroundStyle(MDTheme.secondary)
        }
        Spacer()
        MDIconActionButton(
          symbol: "arrow.clockwise",
          label: L10n.text("projects.refresh"),
          action: { refreshID += 1 })
          .disabled(snapshot == nil && loadError == nil)
          .accessibilityIdentifier("refresh-skills")
      }
      if let loadError {
        InlineNotice(text: loadError, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      } else if let snapshot {
        if snapshot.skills.isEmpty {
          MDEmptyState(
            title: L10n.text("projects.noProjectSkillsFound"),
            message: L10n.text("projects.scansAgentsSkillsClaudeSkillsCodex"),
            symbol: "doc.text.magnifyingglass")
        } else {
          if snapshot.skills.count > 6 || !skillQuery.isEmpty {
            MDSearchField(prompt: L10n.text("projects.searchSkills"), text: $skillQuery)
          }
          if filteredSkills.isEmpty {
            MDEmptyState(
              title: L10n.text("projects.noMatchingSkills"),
              symbol: "magnifyingglass")
          } else {
            MDList {
              ForEach(Array(filteredSkills.enumerated()), id: \.element.id) { index, skill in
                MDListRow(title: skill.name, symbol: "doc.text",
                          subtitle: skill.description.isEmpty ? nil : skill.description,
                          position: MDListRowPosition(index: index, count: filteredSkills.count),
                          iconTone: skillTone(skill.source)) {
                  Text(skill.source)
                    .font(.system(size: 11))
                    .foregroundStyle(MDTheme.onSurfaceVariant)
                }
                .accessibilityIdentifier("skill-" + skill.path)
              }
            }
          }
        }
      } else {
        MDLoadingState(title: L10n.text("projects.loadingSkills"), size: 40)
      }
    }
  }

  private func skillTone(_ source: String) -> MDIconTone {
    switch source {
    case ".claude": .pink
    case ".codex": .blue
    case ".agents": .green
    default: .gray
    }
  }

  private func loadSkills() async {
    snapshot = nil
    loadError = nil
    do {
      let result = try await ProjectSkillLibrary.scan(project: project)
      guard !Task.isCancelled else { return }
      snapshot = result
    } catch {
      guard !Task.isCancelled else { return }
      loadError = Failure.safe(error).localizedDescription
    }
  }
}
