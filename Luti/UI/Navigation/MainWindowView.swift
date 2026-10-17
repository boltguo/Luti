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
  @Environment(\.openWindow) private var openWindow
  @Bindable var model: AppModel
  let loginItem: LoginItemController
  @ObservedObject var updater: AppUpdater
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
          })
        case .configuration: ConfigurationView(model: model)
        case .projects: ProjectsView(model: model)
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
    .sheet(item: Binding(get: { approval }, set: { _ in })) { item in
      switch item {
      case .connection(let request):
        ApprovalView(
          request: request,
          queued: max(0, model.cloudflare.authorization.pending.count - 1)
        ) { allow in
          Task { await model.cloudflare.decide(request.id, allow: allow) }
        }
      case .operation(let request):
        OperationApprovalView(
          request: request,
          queued: max(0, model.pendingOperationApprovals.count - 1)
        ) { allow in
          model.resolveOperationApproval(request.id, approved: allow)
        }
      }
    }
    .onChange(of: approval?.id) { _, id in
      if id != nil { openWindow(id: "main") }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { loginItem.refresh(); LanguageSettings.shared.refreshSystemLanguage() }
    }
  }

  /// One native sheet at a time; connection requests come first.
  private var approval: NativeApproval? {
    if let request = model.cloudflare.authorization.pending.first { return .connection(request) }
    return model.pendingOperationApprovals.first.map(NativeApproval.operation)
  }
}

private enum NativeApproval: Identifiable {
  case connection(OAuthPending)
  case operation(PendingOperationApproval)

  var id: String {
    switch self {
    case .connection(let request): "connection:" + request.id.uuidString
    case .operation(let request): "operation:" + request.id.uuidString
    }
  }
}

/// Native on purpose: only the person at the Mac can reach this sheet, so
/// a remote AI cannot approve its own dangerous operation.
private struct OperationApprovalView: View {
  let request: PendingOperationApproval
  let queued: Int
  let decide: (Bool) -> Void

  var body: some View {
    MDModalSurface(width: 430) {
      MDModalHeader(
        title: L10n.text("operationApproval.title"),
        message: L10n.text(reasonKey),
        symbol: "exclamationmark.shield",
        tone: .orange)

      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text("operationApproval.command"))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
        Text(request.summary)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.onSurface)
          .textSelection(.enabled)
          .lineLimit(6)
        Text(L10n.text("operationApproval.project"))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .padding(.top, 4)
        Text(request.projectPath)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MDTheme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      if queued > 0 {
        Text(L10n.format("approval.moreRequestsWaiting", queued))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }

      MDModalActions {
        Button {
          decide(false)
        } label: {
          Text(L10n.text("approval.deny"))
            .frame(minWidth: 104)
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
        .accessibilityIdentifier("operation-approval-deny")

        // No default action: Return must never approve a destructive operation.
        Button {
          decide(true)
        } label: {
          Text(L10n.text("operationApproval.allowOnce"))
            .frame(minWidth: 104)
        }
        .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
        .accessibilityIdentifier("operation-approval-allow")
      }
    }
    .accessibilityIdentifier("operation-approval-sheet")
  }

  private var reasonKey: String {
    switch request.code {
    case "git_mutation", "project_script_git_mutation": "operationApproval.reason.git"
    case "opaque_shell", "inline_code": "operationApproval.reason.code"
    default: "operationApproval.reason.destructive"
    }
  }
}

private struct ApprovalView: View {
  let request: OAuthPending
  let queued: Int
  let decide: (Bool) -> Void

  var body: some View {
    MDModalSurface(width: 430) {
      MDModalHeader(
        title: L10n.text("approval.allowConnection"),
        message: L10n.format("approval.requestingAccessMac", request.client.name),
        symbol: "person.badge.key",
        tone: .purple)

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(request.client.name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(MDTheme.onSurface)
            .lineLimit(1)
          Spacer()
          Text(request.verification)
            .font(.system(size: 20, weight: .bold, design: .monospaced))
            .foregroundStyle(MDTheme.primary)
            .textSelection(.enabled)
        }
        Text(request.redirect)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MDTheme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

      Text(L10n.text("cloudflare.verify"))
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)

      Text(L10n.text("cloudflare.access"))
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)

      if queued > 0 {
        Text(L10n.format("approval.moreRequestsWaiting", queued))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }

      MDModalActions {
        Button {
          decide(false)
        } label: {
          Text(L10n.text("cloudflare.deny"))
            .frame(minWidth: 104)
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
        .accessibilityIdentifier("approval-deny")

        Button {
          decide(true)
        } label: {
          Text(L10n.text("cloudflare.allow"))
            .frame(minWidth: 104)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
        .accessibilityIdentifier("approval-allow")
      }
    }
    .accessibilityIdentifier("approval-sheet")
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
