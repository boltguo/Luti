import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
  case home, configuration, projects, settings
  var id: Self { self }
  @MainActor var title: String {
    switch self {
    case .home: L10n.text("navigation.home")
    case .configuration: L10n.text("common.connection")
    case .projects: L10n.text("common.projects")
    case .settings: L10n.text("common.settings")
    }
  }
  var shortcut: KeyEquivalent {
    switch self {
    case .home: "1"
    case .configuration: "2"
    case .projects: "3"
    case .settings: "4"
    }
  }
}

struct MainWindowView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var model: AppModel
  let loginItem: LoginItemController
  @ObservedObject var updater: AppUpdater
  @Binding var selectedTab: AppTab
  @State private var selectedProjectID: String?
  @State private var settingsPage = SettingsPage.root

  var body: some View {
    VStack(spacing: 0) {
      MDNavigation(selection: $selectedTab)
      Group {
        switch selectedTab {
        case .home:
          HomeView(model: model, openProjects: {
            selectedProjectID = nil
            selectedTab = .projects
          }, openConnection: {
            selectedTab = .configuration
          })
        case .configuration: ConfigurationView(model: model)
        case .projects: ProjectsView(model: model, selectedProjectID: $selectedProjectID)
        case .settings:
          SettingsView(model: model, loginItem: loginItem, updater: updater, page: $settingsPage)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MDTheme.surface)
    .foregroundStyle(MDTheme.onSurface)
    .tint(MDTheme.primary)
    // Fixed size, deliberately not resizable. These are content points; the
    // compact toolbar adds 40 on top, so the window frame is 460x760. MDPage
    // scrolls, so pinning the height never clips a tab.
    .frame(width: 460, height: 736)
    .toolbar {
      if #available(macOS 26.0, *) {
        ToolbarItem(placement: .navigation) {
          Text("Luti").font(.headline).foregroundStyle(MDTheme.onSurfaceVariant)
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .navigation) {
          Text("Luti").font(.headline).foregroundStyle(MDTheme.onSurfaceVariant)
        }
      }
    }
    .sheet(isPresented: $model.showConsent) { ExecutionConsentView(model: model) }
    // Connection admission and high-risk local operations share one native queue.
    // The browser/remote Host cannot answer either dialog on behalf of the Mac user.
    .sheet(item: Binding(get: { model.nextNativeApproval }, set: { _ in })) { approval in
      switch approval {
      case .connection(let request):
        ApprovalView(request: request, queued: max(0, model.pendingApprovals.count - 1)) { approved in
          model.resolveApproval(request.id, approved: approved)
        }
      case .operation(let request):
        OperationApprovalView(request: request) { approved in
          model.resolveOperationApproval(request.id, approved: approved)
        }
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { loginItem.refresh(); LanguageSettings.shared.refreshSystemLanguage() }
    }
  }
}

private struct MDNavigation: View {
  @Binding var selection: AppTab
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Namespace private var indicator

  var body: some View {
    HStack(spacing: 0) {
      ForEach(AppTab.allCases) { tab in
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { selection = tab }
        } label: {
          Text(tab.title)
            .font(.system(size: 14, weight: selection == tab ? .semibold : .medium))
            .foregroundStyle(selection == tab ? MDTheme.primary : MDTheme.onSurfaceVariant)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
              if selection == tab {
                UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                  .fill(MDTheme.primary)
                  .frame(width: 56, height: 4)
                  .matchedGeometryEffect(id: "tab-indicator", in: indicator)
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
        .accessibilityIdentifier("tab-" + tab.rawValue)
      }
    }
    .padding(.horizontal, 8)
    .background(MDTheme.surface)
    .overlay(alignment: .bottom) { MDTheme.outlineVariant.frame(height: 1) }
    .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("navigation.pageNavigation"))
  }
}

private struct ExecutionConsentView: View {
  @Bindable var model: AppModel

  var body: some View {
    MDModalSurface(width: 430) {
      MDModalHeader(
        title: L10n.text("navigation.allowLocalExecution"),
        message: L10n.text("navigation.fileToolsAccessOnlySelectedProject"),
        symbol: "hand.raised",
        tone: .purple)

      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text("permissionMode.title"))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .textCase(.uppercase)

        MDList {
          MDListRow(
            title: permissionModeTitle,
            symbol: model.activeProject?.permissionMode == .fullProjectAccess
              ? "folder.badge.gearshape" : "hand.raised",
            subtitle: permissionModeDescription,
            iconTone: model.activeProject?.permissionMode == .fullProjectAccess ? .purple : .yellow
          ) { EmptyView() }
        }
      }

      if let path = model.project?.path, !path.isEmpty {
        HStack(spacing: 10) {
          Image(systemName: "folder")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MDTheme.onSurfaceVariant)
          Text(path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          MDTheme.surfaceContainerLow,
          in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      }

      Label(
        L10n.text("navigation.screenshotsClipboardAccessUIActionsMay"),
        systemImage: "info.circle")
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)

      MDModalActions {
        Button {
          model.showConsent = false
        } label: {
          Text(L10n.text("common.cancel"))
            .frame(minWidth: 104)
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))

        Button(action: model.startWithLocalConsent) {
          Text(L10n.text("navigation.allowStart"))
            .frame(minWidth: 104)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
      }
    }
  }

  private var permissionModeTitle: String {
    model.activeProject?.permissionMode == .fullProjectAccess
      ? L10n.text("permissionMode.fullProjectAccess")
      : L10n.text("permissionMode.ask")
  }

  private var permissionModeDescription: String {
    model.activeProject?.permissionMode == .fullProjectAccess
      ? L10n.text("permissionMode.fullProjectAccessDescription")
      : L10n.text("permissionMode.askDescription")
  }
}
