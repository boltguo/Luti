import AppKit
import SwiftUI

/// Inline Cloudflare setup and origin-bound AI authorizations.
struct CloudflareConnectionView: View {
  @Bindable var model: AppModel
  @Bindable var clients: OAuthClientModel
  let openClient: (String) -> Void

  @State private var confirmAuthorizationResetOnSave = false
  @State private var confirmClearConfiguration = false

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if let url = model.configuredMCPServerURL(.cloudflare) {
        ProviderMCPURLRow(
          value: url.absoluteString,
          accessibilityID: "copy-provider-url-cloudflare")
      }

      if let message = model.providerConnectionError(.cloudflare)
        ?? (state.state == .failed ? state.message : nil)
      {
        ProviderInfoCallout(
          text: message,
          symbol: "exclamationmark.triangle",
          tone: .red)
          .textSelection(.enabled)
      }

      configurationForm

      if !model.cloudflareConfigured {
        CloudflareConnectionHelp()
      }

      if clients.clients.isEmpty {
        if state.state.isActive {
          ProviderInfoText(
            text: L10n.text("connection.authorizeAfterProviderReady"),
            symbol: "person.crop.circle.badge.checkmark")
        }
      } else {
        authorizationSection
      }
    }
    .onAppear(perform: clients.reload)
    .sheet(isPresented: $confirmAuthorizationResetOnSave) {
      MDConfirmDialog(
        title: L10n.text("connection.changeOriginOrCredentials"),
        message: L10n.text("connection.authorizationResetMessage"),
        confirmTitle: L10n.text("connection.saveAndResetAuthorizations"),
        icon: "exclamationmark.triangle.fill"
      ) {
        saveConfiguration(invalidateAuthorizations: true)
      }
    }
    .sheet(isPresented: $confirmClearConfiguration) {
      MDConfirmDialog(
        title: L10n.text("connection.clearConfigurationConfirmation"),
        message: L10n.text("connection.clearConfigurationMessage"),
        confirmTitle: L10n.text("connection.clearConfiguration"),
        icon: "trash.fill"
      ) {
        if model.clearCloudflareConfiguration() { clients.reload() }
      }
    }
  }

  private var state: ConnectionSnapshot {
    model.providerSnapshot(.cloudflare)
  }

  private var authorizationSection: some View {
    ProviderAuthorizationSection(clients: clients, openClient: openClient)
  }

  private var configurationForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 16) {
        MDInput(title: L10n.text("connection.publicURL")) {
          TextField("https://mcp.example.com", text: $model.publicBaseURL)
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.text("connection.publicURL"))
            .accessibilityIdentifier("public-base-url")
        }

        MDInput(title: L10n.text("connection.tunnelToken")) {
          SecureField(
            model.tokenSaved
              ? L10n.text("connection.savedLeaveBlankKeepCurrentToken")
              : L10n.text("connection.pasteCloudflareTunnelToken"),
            text: $model.tokenDraft)
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.text("connection.tunnelToken"))
            .accessibilityIdentifier("tunnel-token")
        }

        MDButtonRun {
          if model.tokenSaved || !model.savedPublicBaseURL.isEmpty {
            Button(role: .destructive) {
              confirmClearConfiguration = true
            } label: {
              Text(L10n.text("connection.clearConfiguration"))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("clear-cloudflare-configuration")
          }

          Button {
            if saveInvalidatesAuthorizations {
              confirmAuthorizationResetOnSave = true
            } else {
              saveConfiguration(invalidateAuthorizations: false)
            }
          } label: {
            Text(L10n.text("connection.saveConfiguration"))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MDConnectedButtonStyle(
            kind: .filled,
            position: model.tokenSaved || !model.savedPublicBaseURL.isEmpty ? .last : .single))
          .frame(maxWidth: .infinity)
          .disabled(!model.hasUnsavedConnection && model.tokenSaved)
          .accessibilityIdentifier("save-configuration")
        }
      }
      .disabled(!model.canEditConnection(.cloudflare))

      if !model.canEditConnection(.cloudflare) {
        ProviderInfoCallout(
          text: L10n.text("connection.disconnectToEdit"),
          symbol: "lock",
          tone: .gray)
      }

      if let message = model.connectionSettingsErrors[.cloudflare] {
        InlineNotice(
          text: message,
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var draftedOrigin: String? {
    let value = model.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = try? ConnectionContract.validatePublicBaseURL(value),
          let host = url.host
    else { return nil }
    return "https://" + host
  }

  private var saveInvalidatesAuthorizations: Bool {
    guard !clients.clients.isEmpty else { return false }
    let changesOrigin =
      !model.savedPublicBaseURL.isEmpty
      && draftedOrigin != nil
      && draftedOrigin != model.savedPublicBaseURL
    let replacesCredential =
      model.tokenSaved
      && !model.tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return changesOrigin || replacesCredential
  }

  private func saveConfiguration(invalidateAuthorizations: Bool) {
    if model.saveSettings() { clients.reload() }
  }
}

private struct CloudflareConnectionHelp: View {
  private var localService: String { "http://127.0.0.1:\(TunnelContract.defaultPort)" }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MDNavigationRow(
        title: L10n.text("connection.cloudflareStep1"),
        symbol: "network",
        subtitle: L10n.text("connection.cloudflareStep1Description"),
        iconTone: .orange,
        accessory: "arrow.up.right"
      ) {
        guard let url = URL(string: "https://dash.cloudflare.com/?to=/:account/tunnels") else { return }
        NSWorkspace.shared.open(url)
      }
      .accessibilityIdentifier("open-cloudflare-tunnel")

      SetupCopyRow(
        title: L10n.text("connection.service"),
        value: localService,
        accessibilityID: "copy-local-service")
    }
  }
}

struct ProviderMCPURLRow: View {
  let value: String
  let accessibilityID: String

  var body: some View {
    SetupCopyRow(
      title: L10n.text("connection.mcpServerURL"),
      value: value,
      accessibilityID: accessibilityID)
  }
}

struct SetupCopyRow: View {
  let title: String
  let value: String
  var enabled = true
  let accessibilityID: String

  var body: some View {
    MDList {
      MDListRow(
        title: title,
        symbol: "link",
        subtitle: value,
        iconTone: .blue,
        subtitleTruncationMode: .middle
      ) {
        ValueCopyButton(title: title, value: value, enabled: enabled, accessibilityID: accessibilityID)
      }
    }
  }
}

private struct ValueCopyButton: View {
  let title: String
  let value: String
  var enabled = true
  let accessibilityID: String
  @State private var copied = false
  @State private var copyFeedbackRevision = 0

  var body: some View {
    Button {
      guard enabled else { return }
      NSPasteboard.general.clearContents()
      copied = NSPasteboard.general.setString(value, forType: .string)
      copyFeedbackRevision += 1
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .foregroundStyle(copied ? MDTheme.success : MDTheme.primary)
        .frame(width: 32, height: 32)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(L10n.format("clients.copy", title))
    .accessibilityIdentifier(accessibilityID)
    .onChange(of: value) { _, _ in
      copied = false
      copyFeedbackRevision += 1
    }
    .task(id: copyFeedbackRevision) {
      guard copied else { return }
      do {
        try await Task.sleep(for: .seconds(3))
        copied = false
      } catch {}
    }
  }
}

#Preview("Connection Help") {
  MDPage {
    CloudflareConnectionHelp()
  }
  .frame(width: 480, height: 520)
}
