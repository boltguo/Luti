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
  @Binding var selectedTab: AppTab
  @State private var settingsPage = SettingsPage.root

  var body: some View {
    VStack(spacing: 0) {
      MDNavigation(selection: $selectedTab)
      Group {
        switch selectedTab {
        case .home:
          HomeView(model: model, openProjects: {
            selectedTab = .projects
          }, openConnection: {
            selectedTab = .configuration
          })
        case .configuration: ConfigurationView(model: model)
        case .projects: ProjectsView(model: model)
        case .settings:
          SettingsView(model: model, loginItem: loginItem, page: $settingsPage)
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
    .sheet(item: Binding(get: { model.pendingApprovals.first }, set: { _ in })) { request in
      ApprovalView(request: request, queued: max(0, model.pendingApprovals.count - 1)) { approved in
        model.resolveApproval(request.id, approved: approved)
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
