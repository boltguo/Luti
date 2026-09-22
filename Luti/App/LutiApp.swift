import AppKit
import Foundation
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var model: AppModel?
  private var quitting = false
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    if !quitting {
      quitting = true
      Task {
        await model.stop()
        sender.reply(toApplicationShouldTerminate: true)
      }
    }
    return .terminateLater
  }
}

@main @MainActor struct LutiApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var model = AppModel()
  @StateObject private var updater = AppUpdater()
  @State private var language = LanguageSettings.shared
  @State private var loginItem = LoginItemController()
  @State private var selectedTab = AppTab.home

  var body: some Scene {
    // A Window has one instance. Every menu and Dock reopen returns to this window.
    Window("Luti", id: "main") {
      MainWindowView(model: model, loginItem: loginItem, updater: updater, selectedTab: $selectedTab)
        .environment(\.locale, language.locale)
        .onAppear {
          delegate.model = model
          model.beginObserving()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unifiedCompact)
    // Content min == max, so .contentSize makes the window non-resizable.
    .defaultSize(width: 460, height: 736)
    .windowResizability(.contentSize)
    .commands { AppCommands(model: model, updater: updater, selectedTab: $selectedTab) }
    MenuBarExtra {
      RuntimeMenu(model: model, selectedTab: $selectedTab)
        .environment(\.locale, language.locale)
    } label: {
      Image(menuBarAssetName)
        .renderingMode(.template)
        .resizable()
        .interpolation(.high)
        .frame(width: 18, height: 18)
        .accessibilityLabel("Luti")
    }
    .menuBarExtraStyle(.window)
  }
}

private extension LutiApp {
  var menuBarAssetName: String {
    switch model.phase {
    case .stopped:
      "LutiMenuIdle"
    case .preparing, .starting:
      "LutiMenuStarting"
    case .running:
      "LutiMenuRunning"
    case .stopping:
      "LutiMenuStopping"
    case .failed:
      "LutiMenuFailed"
    }
  }
}

private struct AppCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let model: AppModel
  @ObservedObject var updater: AppUpdater
  @Binding var selectedTab: AppTab

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button(L10n.text("menu.checkForUpdates"), action: updater.checkForUpdates)
        .disabled(!updater.canCheckForUpdates)
    }
    CommandGroup(replacing: .newItem) {}
    CommandGroup(replacing: .appSettings) {
      Button(L10n.text("menu.settings")) {
        selectedTab = .settings
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
      }.keyboardShortcut(",", modifiers: .command)
    }
    CommandMenu(L10n.text("menu.pages")) {
      ForEach(AppTab.allCases) { tab in
        Button(tab.title) {
          selectedTab = tab
          openWindow(id: "main")
          NSApplication.shared.activate(ignoringOtherApps: true)
        }.keyboardShortcut(tab.shortcut, modifiers: .command)
      }
    }
    CommandMenu(L10n.text("menu.runtime")) {
      Button(L10n.text("menu.start")) {
        selectedTab = .home
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.requestStart()
      }.disabled(!model.canStart)
      if model.activeJobs > 0 {
        Button(L10n.format("menu.stopRunningTasks", model.activeJobs)) {
          Task { await model.stopActiveJobs() }
        }
      }
      Button(L10n.text("menu.stopLuti")) { Task { await model.stop() } }
        .keyboardShortcut(".", modifiers: .command).disabled(!model.active)
    }
  }
}

private struct RuntimeMenu: View {
  let model: AppModel
  @Binding var selectedTab: AppTab
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      contextSummary
      primaryActions
      RuntimeMenuAction(
        L10n.text("menu.quitLuti"),
        symbol: "xmark",
        tone: .red,
        position: .single,
        role: .destructive
      ) {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(16)
    .frame(width: 312)
    .background(MDTheme.surface)
    .foregroundStyle(MDTheme.onSurface)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Text("Luti")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(MDTheme.onSurface)

      Spacer(minLength: 8)

      HStack(spacing: 6) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
        Text(status)
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(statusColor)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(statusColor.opacity(0.12), in: Capsule())
    }
  }

  private var contextSummary: some View {
    VStack(spacing: 3) {
      RuntimeMenuSummaryRow(
        title: connectionStatus,
        symbol: "link",
        tone: .blue,
        position: .first
      )
      RuntimeMenuSummaryRow(
        title: projectTitle,
        subtitle: model.project == nil ? nil : projectPath,
        symbol: "folder",
        tone: .purple,
        position: .last
      )
    }
  }

  private var primaryActions: some View {
    VStack(spacing: 3) {
      RuntimeMenuAction(
        L10n.text("menu.openLuti"),
        symbol: "macwindow",
        tone: .blue,
        position: .first
      ) {
        showWindow()
      }

      if model.active {
        RuntimeMenuAction(
          L10n.text("menu.stopService"),
          symbol: "power",
          tone: .red,
          position: .last,
          role: .destructive
        ) {
          Task { await model.stop() }
        }
      } else {
        RuntimeMenuAction(
          L10n.text("menu.startService"),
          symbol: "play.fill",
          tone: .green,
          position: .last
        ) {
          selectedTab = .home
          showWindow()
          if model.canStart { model.requestStart() }
        }
      }
    }
  }

  private var projectTitle: String {
    model.project?.lastPathComponent ?? L10n.text("menu.noProjectSelected")
  }

  private var status: String {
    switch model.phase {
    case .stopped: L10n.text("common.stopped")
    case .preparing: L10n.text("common.preparing")
    case .starting: L10n.text("common.starting")
    case .running: L10n.text("common.running")
    case .stopping: L10n.text("common.stopping")
    case .failed: L10n.text("connection.runtimeFailed")
    }
  }

  private var statusColor: Color {
    switch model.phase {
    case .running: MDTheme.success
    case .preparing, .starting, .stopping: MDTheme.warning
    case .failed: MDTheme.error
    case .stopped: MDTheme.onSurfaceVariant
    }
  }

  private var connectionStatus: String {
    if model.phase == .running {
      return model.readyRemoteConnectionCount > 0
        ? L10n.text("connection.localAndRemote") : L10n.text("connection.localAvailable")
    }
    return L10n.text("connection.localFirst")
  }

  private var projectPath: String {
    guard let path = model.project?.path else { return "" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + String(path.dropFirst(home.count))
  }

  private func showWindow() {
    // MenuBarExtra(.window) owns the key window while this action is running.
    // Hide that transient panel before bringing the real app window forward;
    // otherwise the status-card panel remains floating over the main window.
    NSApplication.shared.keyWindow?.orderOut(nil)
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

private struct RuntimeMenuSummaryRow: View {
  let title: String
  var subtitle: String? = nil
  let symbol: String
  let tone: MDIconTone
  let position: MDListRowPosition

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(tone.foreground)
        .frame(width: 32, height: 32)
        .background(tone.container, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(MDTheme.onSurface)
          .lineLimit(1)

        if let subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(subtitle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    .background(MDTheme.surfaceContainerLow, in: position.shape)
  }
}

private struct RuntimeMenuAction: View {
  let title: String
  let symbol: String
  let tone: MDIconTone
  let position: MDListRowPosition
  let role: ButtonRole?
  let action: () -> Void

  init(
    _ title: String,
    symbol: String,
    tone: MDIconTone,
    position: MDListRowPosition,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.symbol = symbol
    self.tone = tone
    self.position = position
    self.role = role
    self.action = action
  }

  var body: some View {
    Button(role: role, action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tone.foreground)
          .frame(width: 32, height: 32)
          .background(tone.container, in: Circle())
          .accessibilityHidden(true)

        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(role == .destructive ? MDTheme.error : MDTheme.onSurface)

        Spacer(minLength: 8)
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 44)
      .background(MDTheme.surfaceContainerLow, in: position.shape)
      .contentShape(position.shape)
    }
    .buttonStyle(RuntimeMenuActionStyle(position: position))
  }
}

private struct RuntimeMenuActionStyle: ButtonStyle {
  let position: MDListRowPosition

  func makeBody(configuration: Configuration) -> some View {
    RuntimeMenuActionBody(configuration: configuration, position: position)
  }
}

private struct RuntimeMenuActionBody: View {
  let configuration: ButtonStyleConfiguration
  let position: MDListRowPosition
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  var body: some View {
    configuration.label
      .overlay(
        position.shape
          .fill(MDTheme.primary.opacity(
            isEnabled ? (configuration.isPressed ? 0.12 : hovered ? 0.06 : 0) : 0
          ))
          .allowsHitTesting(false)
      )
      .opacity(isEnabled ? 1 : 0.38)
      .onHover { hovered = $0 && isEnabled }
  }
}
