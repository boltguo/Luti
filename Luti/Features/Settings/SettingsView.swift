import AppKit
import ServiceManagement
import SwiftUI

enum SettingsPage: String, CaseIterable {
  case root, language, capabilities, components

  @MainActor var title: String {
    switch self {
    case .root: L10n.text("common.settings")
    case .language: L10n.text("settings.displayLanguage")
    case .capabilities: L10n.text("settings.capabilityDiagnostics")
    case .components: L10n.text("settings.thirdPartyComponents")
    }
  }
}

struct SettingsView: View {
  let model: AppModel
  let loginItem: LoginItemController
  @ObservedObject var updater: AppUpdater
  @Binding var page: SettingsPage
  @Bindable private var language = LanguageSettings.shared

  var body: some View {
    VStack(spacing: 0) {
      if page != .root {
        MDDetailHeader(title: page.title) { page = .root }
      }

      switch page {
      case .root:
        overview
      case .language:
        languageSettings
      case .capabilities:
        capabilityDiagnostics
      case .components:
        components
      }
    }
    .onAppear { loginItem.refresh() }
  }

  private var overview: some View {
    MDPage {
      MDSection(title: L10n.text("settings.general")) {
        MDList {
          MDNavigationRow(
            title: L10n.text("settings.displayLanguage"),
            symbol: "globe",
            detail: languageTitle(language.selection),
            position: .first,
            iconTone: .blue
          ) {
            page = .language
          }
          .accessibilityIdentifier("language-settings")

          MDListRow(
            title: L10n.text("settings.defaultFullProjectAccess"),
            symbol: "folder.badge.gearshape",
            subtitle: L10n.text("settings.defaultFullProjectAccessDescription"),
            position: .middle,
            iconTone: .purple
          ) {
            MDSwitch(
              isOn: Binding(
                get: { model.defaultFullProjectAccess },
                set: { model.setDefaultFullProjectAccess($0) }),
              label: L10n.text("settings.defaultFullProjectAccess"))
              .accessibilityIdentifier("default-full-project-access")
          }

          MDListRow(
            title: L10n.text("settings.launchLogin"),
            symbol: "power",
            position: .middle,
            iconTone: .green
          ) {
            MDSwitch(
              isOn: Binding(
                get: { loginItem.isRequested },
                set: { loginItem.setEnabled($0) }),
              label: L10n.text("settings.launchLogin"))
              .accessibilityIdentifier("launch-at-login")
          }

          MDNavigationRow(
            title: L10n.text("settings.systemLoginItems"),
            symbol: "gearshape",
            detail: loginStatus,
            position: .last,
            iconTone: .gray,
            action: loginItem.openSettings)
            .accessibilityIdentifier("system-login-items")
        }
      }

      if loginItem.status == .requiresApproval {
        InlineNotice(
          text: L10n.text("settings.allowLutiSystemSettingsLoginItems"),
          icon: "exclamationmark.circle",
          color: MDTheme.warning)
      }
      if let error = loginItem.errorMessage {
        InlineNotice(
          text: error,
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
          .textSelection(.enabled)
      }

      MDSection(title: L10n.text("settings.updates")) {
        MDList {
          MDListRow(
            title: L10n.text("settings.automaticUpdateChecks"),
            symbol: "arrow.triangle.2.circlepath",
            position: .first,
            iconTone: .blue
          ) {
            MDSwitch(
              isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }),
              label: L10n.text("settings.automaticUpdateChecks"))
              .accessibilityIdentifier("automatic-update-checks")
          }

          MDNavigationRow(
            title: L10n.text("menu.checkForUpdates"),
            symbol: "arrow.down.circle",
            position: .last,
            iconTone: .green,
            action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
            .accessibilityIdentifier("check-for-updates")
        }
      }

      PermissionsSettingsBlock(model: model)

      MDSection(title: L10n.text("settings.diagnostics")) {
        MDNavigationRow(
          title: L10n.text("settings.capabilityDiagnostics"),
          symbol: "wrench.and.screwdriver",
          subtitle: L10n.text("settings.capabilityDiagnosticsDescription"),
          iconTone: .orange
        ) {
          page = .capabilities
        }
        .accessibilityIdentifier("settings-capabilities")
      }

      MDSection(title: L10n.text("settings.helpAndSupport")) {
        MDList {
          MDNavigationRow(
            title: L10n.text("settings.sourceCode"),
            symbol: "chevron.left.forwardslash.chevron.right",
            position: .first,
            iconTone: .blue,
            accessory: "arrow.up.right"
          ) {
            NSWorkspace.shared.open(URL(string: "https://github.com/boltguo/Luti")!)
          }
          .accessibilityIdentifier("settings-source-code")

          MDNavigationRow(
            title: L10n.text("settings.supportLuti"),
            symbol: "cup.and.saucer",
            position: .last,
            iconTone: .orange,
            accessory: "arrow.up.right"
          ) {
            NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/boltguo")!)
          }
          .accessibilityIdentifier("settings-support-luti")
        }
      }

      MDSection(title: L10n.text("settings.about")) {
        MDList {
          ComponentVersionRow(
            name: "Luti",
            symbol: "terminal",
            version: version,
            position: .first,
            tone: .purple)

          MDNavigationRow(
            title: L10n.text("settings.thirdPartyComponents"),
            symbol: "shippingbox",
            position: .last,
            iconTone: .blue
          ) {
            page = .components
          }
          .accessibilityIdentifier("settings-third-party-components")
        }
      }
    }
    .onAppear { loginItem.refresh() }
  }

  private var languageSettings: some View {
    MDPage {
      MDSection(title: L10n.text("settings.displayLanguage")) {
        MDList {
          ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element.id) { index, option in
            let position = MDListRowPosition(index: index, count: AppLanguage.allCases.count)
            Button {
              language.selection = option
            } label: {
              HStack(spacing: 16) {
                Text(languageTitle(option))
                  .font(.system(size: 14, weight: .medium))
                  .foregroundStyle(MDTheme.onSurface)
                  .frame(maxWidth: .infinity, alignment: .leading)

                MDRadioMark(isSelected: language.selection == option)
                  .frame(width: 40, height: 40)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
              .background(MDListRowSurface(position: position))
              .contentShape(position.shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(languageTitle(option))
            .accessibilityValue(
              language.selection == option
                ? L10n.text("projects.selected")
                : L10n.text("common.notSelected"))
            .accessibilityIdentifier("language-option-" + option.rawValue)
          }
        }
      }
    }
  }

  private func languageTitle(_ option: AppLanguage) -> String {
    switch option {
    case .system: L10n.text("settings.system")
    case .chinese: L10n.text("settings.simplifiedChinese")
    case .english: "English"
    case .japanese: L10n.text("settings.japanese")
    }
  }

  private var capabilityDiagnostics: some View {
    MDPage {
      CapabilitiesView(model: model)
    }
  }

  private var components: some View {
    MDPage {
      MDSection(title: L10n.text("settings.thirdPartyComponents")) {
        MDList {
          ComponentVersionRow(
            name: "Playwright",
            symbol: "globe",
            version: BrowserInstallation.playwrightVersion,
            position: .first,
            tone: .blue)
          ComponentVersionRow(
            name: "Cloudflare Tunnel",
            symbol: "link",
            version: TunnelContract.version,
            position: .middle,
            tone: .purple)
          ComponentVersionRow(
            name: "OpenAI tunnel-client",
            symbol: "lock.icloud",
            version: ConnectionExecutables.openAIVersion,
            position: .middle,
            tone: .green)
          ComponentVersionRow(
            name: "ngrok",
            symbol: "network",
            version: ConnectionExecutables.ngrokVersion,
            position: .middle,
            tone: .blue)
          ComponentVersionRow(
            name: "SwiftNIO",
            symbol: "network",
            version: "2.103.0",
            position: .last,
            tone: .orange)
        }
      }
    }
  }

  private var version: String {
    let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? Identity.version
    guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      !build.isEmpty
    else { return marketing }
    return "\(marketing) (\(build))"
  }

  private var loginStatus: String {
    switch loginItem.status {
    case .enabled: L10n.text("common.enabled")
    case .requiresApproval: L10n.text("settings.awaitingApproval")
    case .notRegistered: L10n.text("common.disabled")
    case .notFound: L10n.text("settings.notRegistered")
    @unknown default: L10n.text("settings.viewStatus")
    }
  }
}

private struct PermissionsSettingsBlock: View {
  let model: AppModel

  var body: some View {
    MDSection(title: L10n.text("settings.systemPermissions")) {
      MDList {
        permission(
          L10n.text("settings.screenRecording"),
          symbol: "rectangle.on.rectangle",
          subtitle: L10n.text("settings.captureObserveScreen"),
          granted: model.permissions.screen,
          position: .first,
          tone: .blue,
          action: PermissionManager.requestScreen)
        permission(
          L10n.text("settings.accessibility"),
          symbol: "hand.point.up.left",
          subtitle: L10n.text("settings.controlWindowsKeyboardMouse"),
          granted: model.permissions.accessibility,
          position: .middle,
          tone: .pink,
          action: PermissionManager.requestAccessibility)
        MDNavigationRow(
          title: L10n.text("settings.systemPermissionSettings"),
          symbol: "gearshape",
          position: .last,
          iconTone: .gray,
          action: PermissionManager.openSettings)
      }
    }
  }

  @ViewBuilder private func permission(
    _ title: String,
    symbol: String,
    subtitle: String,
    granted: Bool,
    position: MDListRowPosition,
    tone: MDIconTone,
    action: @escaping () -> Void
  ) -> some View {
    if granted {
      MDListRow(
        title: title,
        symbol: symbol,
        subtitle: subtitle,
        position: position,
        iconTone: tone
      ) {
        Text(L10n.text("common.granted"))
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MDTheme.success)
      }
    } else {
      MDNavigationRow(
        title: title,
        symbol: symbol,
        subtitle: subtitle,
        detail: L10n.text("settings.allow"),
        position: position,
        iconTone: tone,
        action: action)
    }
  }
}

private struct ComponentVersionRow: View {
  let name: String
  let symbol: String
  let version: String
  let position: MDListRowPosition
  let tone: MDIconTone

  var body: some View {
    MDListRow(
      title: name,
      symbol: symbol,
      position: position,
      iconTone: tone
    ) {
      Text(version)
        .font(.system(size: 13).monospacedDigit())
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .textSelection(.enabled)
    }
  }
}
