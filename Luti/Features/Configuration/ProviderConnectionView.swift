import AppKit
import SwiftUI

extension ConnectionProviderID {
  var symbol: String {
    switch self {
    case .cloudflare: "network"
    case .openAI: "lock.icloud"
    case .ngrok: "link"
    }
  }

  var iconTone: MDIconTone {
    switch self {
    case .cloudflare: .orange
    case .openAI: .green
    case .ngrok: .purple
    }
  }
}

/// Provider details follow the same single-level section hierarchy as the
/// surrounding settings pages. Lists and lightweight callouts provide the
/// surfaces; the section itself never adds another card around them.
struct ProviderDetailCard<Content: View>: View {
  let title: String
  let symbol: String
  var tone: MDIconTone = .purple
  @ViewBuilder let content: Content

  var body: some View {
    MDSection(title: title) {
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct ProviderInfoCallout: View {
  let text: String
  var symbol = "info.circle"
  var tone: MDIconTone = .yellow

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tone.foreground)
        .frame(width: 20)
        .accessibilityHidden(true)

      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.container, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct ProviderInfoText: View {
  let text: String
  var symbol = "info.circle"

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .frame(width: 22)
        .accessibilityHidden(true)

      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 4)
  }
}

private struct ProviderSetupStep: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(String(number))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(MDTheme.onPrimaryContainer)
        .frame(width: 26, height: 26)
        .background(MDTheme.primaryContainer, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(MDTheme.onSurface)

        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// OpenAI and ngrok share one card-oriented detail hierarchy.
/// Confirmation sheets are the only modal surfaces.
struct ProviderConnectionView: View {
  @Bindable var model: AppModel
  @Bindable var clients: OAuthClientModel
  let provider: ConnectionProviderID
  let openClient: (String) -> Void
  @State private var address = ""
  @State private var credential = ""
  @State private var confirmSave = false
  @State private var confirmClearConfiguration = false

  private var changed: Bool {
    address.trimmed != model.savedProviderAddress(provider) || !credential.isEmpty
  }

  private var state: ConnectionSnapshot {
    model.providerSnapshot(provider)
  }

  var body: some View {
    MDPage {
      ProviderStatusSection(model: model, provider: provider)

      if let url = model.configuredMCPServerURL(provider) {
        ProviderMCPURLRow(
          value: url.absoluteString,
          accessibilityID: "copy-provider-url-" + provider.rawValue)
      }

      if let message = model.providerConnectionError(provider)
        ?? (state.state == .failed ? state.message : nil)
      {
        ProviderInfoCallout(
          text: message,
          symbol: "exclamationmark.triangle",
          tone: .red)
          .textSelection(.enabled)
      }

      configurationCard

      if !model.isConnectionProviderConfigured(provider) {
        setupGuideCard
      }

      if provider.usesOAuth {
        if clients.clients.isEmpty {
          if state.state.isActive {
            ProviderInfoText(
              text: L10n.text("connection.authorizeAfterProviderReady"),
              symbol: "person.crop.circle.badge.checkmark")
          }
        } else {
          ProviderAuthorizationSection(clients: clients, openClient: openClient)
        }
      }
    }
    .onAppear {
      address = model.savedProviderAddress(provider)
      clients.reload()
    }
    .onDisappear { credential = "" }
    .sheet(isPresented: $confirmSave) {
      MDConfirmDialog(
        title: L10n.text("connection.changeOriginOrCredentials"),
        message: L10n.text("connection.authorizationResetMessage"),
        confirmTitle: L10n.text("connection.saveAndResetAuthorizations"),
        icon: "exclamationmark.triangle.fill",
        confirm: save)
    }
    .sheet(isPresented: $confirmClearConfiguration) {
      MDConfirmDialog(
        title: L10n.text("connection.clearConfigurationConfirmation"),
        message: L10n.text("connection.clearConfigurationMessage"),
        confirmTitle: L10n.text("connection.clearConfiguration"),
        icon: "trash.fill"
      ) {
        if model.clearProviderSettings(provider) {
          address = ""
          credential = ""
          clients.reload()
        }
      }
    }
  }

  private var configurationCard: some View {
    ProviderDetailCard(
      title: L10n.text("connection.configuration"),
      symbol: "slider.horizontal.3",
      tone: .purple
    ) {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 16) {
          MDInput(title: provider == .openAI ? "Tunnel ID" : L10n.text("connection.publicURL")) {
            TextField(
              provider == .openAI ? "tunnel_…" : "https://your-domain.ngrok-free.app",
              text: $address)
              .autocorrectionDisabled()
              .accessibilityIdentifier("provider-address-" + provider.rawValue)
          }

          MDInput(title: provider == .openAI ? "Runtime API Key" : "Authtoken") {
            SecureField(L10n.text("connection.savedLeaveBlankKeepCurrentToken"), text: $credential)
              .autocorrectionDisabled()
              .accessibilityIdentifier("provider-credential-" + provider.rawValue)
          }

          MDTrailingActions {
            if !model.savedProviderAddress(provider).isEmpty {
              Button(role: .destructive) {
                confirmClearConfiguration = true
              } label: {
                Text(L10n.text("connection.clearConfiguration"))
                  .frame(minWidth: 104)
              }
              .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
              .accessibilityIdentifier("clear-provider-configuration-" + provider.rawValue)
            }

            Button {
              if model.isConnectionProviderConfigured(provider), changed {
                confirmSave = true
              } else {
                save()
              }
            } label: {
              Text(L10n.text("connection.saveConfiguration"))
                .frame(minWidth: 104)
            }
            .buttonStyle(MDConnectedButtonStyle(
              kind: .filled,
              position: model.savedProviderAddress(provider).isEmpty ? .single : .last))
            .disabled(!changed)
            .accessibilityIdentifier("save-provider-" + provider.rawValue)
          }
        }
        .disabled(!model.canEditConnection(provider))

        if !model.canEditConnection(provider) {
          ProviderInfoCallout(
            text: L10n.text("connection.disconnectToEdit"),
            symbol: "lock",
            tone: .gray)
        }

        if !model.settingsMessage.isEmpty {
          InlineNotice(
            text: model.settingsMessage,
            icon: "exclamationmark.triangle",
            color: MDTheme.error)
            .textSelection(.enabled)
        }

      }
    }
  }

  private var setupGuideCard: some View {
    ProviderDetailCard(
      title: L10n.text("connection.setupGuide"),
      symbol: "list.number",
      tone: .blue
    ) {
      if provider == .openAI {
        VStack(alignment: .leading, spacing: 16) {
          ProviderSetupStep(
            number: 1,
            title: L10n.text("provider.openai.step1.title"),
            detail: L10n.text("provider.openai.step1.detail"))
          ProviderSetupStep(
            number: 2,
            title: L10n.text("provider.openai.step2.title"),
            detail: L10n.text("provider.openai.step2.detail"))
          ProviderSetupStep(
            number: 3,
            title: L10n.text("provider.openai.step3.title"),
            detail: L10n.text("provider.openai.step3.detail"))
          ProviderSetupStep(
            number: 4,
            title: L10n.text("provider.openai.step4.title"),
            detail: L10n.text("provider.openai.step4.detail"))
        }

        MDButtonRun {
          Link(destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!) {
            Label(L10n.text("provider.openTunnelSettings"), systemImage: "arrow.up.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))

          Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
            Label(L10n.text("provider.openAPIKeys"), systemImage: "arrow.up.right")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .last))
        }
        .frame(maxWidth: .infinity)
      } else {
        ProviderInfoText(
          text: L10n.text("provider." + provider.rawValue + ".guide"),
          symbol: "info.circle")

        if provider == .ngrok {
          MDButtonRun {
            Link(destination: URL(string: "https://dashboard.ngrok.com/domains")!) {
              Label(L10n.text("provider.openDashboard"), systemImage: "arrow.up.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))

            Link(destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!) {
              Label(L10n.text("provider.openAuthtoken"), systemImage: "arrow.up.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .last))
          }
          .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private func save() {
    if model.saveProviderSettings(provider, address: address, credential: credential) {
      address = model.savedProviderAddress(provider)
      credential = ""
      clients.reload()
    }
  }
}

struct ProviderStatusSection: View {
  @Bindable var model: AppModel
  let provider: ConnectionProviderID

  private var state: ConnectionSnapshot { model.providerSnapshot(provider) }

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.text("connection.providerEnabled"))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(MDTheme.onPrimaryContainer)

        Text(summary)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onPrimaryContainer.opacity(0.72))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      MDSwitch(
        isOn: Binding(
          get: { model.isProviderEnabled(provider) },
          set: { _ = model.setConnectionProviderEnabled(provider, enabled: $0) }),
        label: L10n.text("connection.providerEnabled"))
        .disabled(toggleDisabled)
        .accessibilityIdentifier("provider-enabled-" + provider.rawValue)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
    .background(
      MDTheme.primaryContainer,
      in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var summary: String {
    if !model.isConnectionProviderConfigured(provider) {
      return L10n.text("connection.providerSetupRequired")
    }
    if state.state != .stopped {
      return L10n.text("connection.state." + state.state.rawValue)
    }
    return L10n.text(model.isProviderEnabled(provider) ? "common.enabled" : "common.disabled")
  }

  private var toggleDisabled: Bool {
    if state.state == .starting || state.state == .stopping { return true }
    return !model.isConnectionProviderConfigured(provider)
  }
}

struct ProviderAuthorizationSection: View {
  @Bindable var clients: OAuthClientModel
  let openClient: (String) -> Void

  var body: some View {
    ProviderDetailCard(
      title: L10n.text("connection.aiApps"),
      symbol: "person.2",
      tone: .green
    ) {
      MDList {
        let rows = Array(clients.clients.reversed())
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
          AIClientConnectionRow(
            record: record,
            grants: clients.grants,
            position: MDListRowPosition(index: index, count: rows.count),
            enabled: Binding(
              get: { clients.client(record.id)?.isEnabled ?? false },
              set: { clients.setEnabled($0, for: record.id) }),
            open: { openClient(record.id) })
        }
      }

      if !clients.message.isEmpty {
        InlineNotice(
          text: clients.message,
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
      }
    }
  }
}
