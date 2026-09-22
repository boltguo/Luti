import AppKit
import SwiftUI

/// Provider-specific setup, health and origin-bound Host authorizations live here.
struct CloudflareConnectionView: View {
  @Bindable var model: AppModel
  @Bindable var clients: OAuthClientModel
  let openClient: (String) -> Void

  @State private var confirmAuthorizationResetOnSave = false
  @State private var confirmClearConfiguration = false

  var body: some View {
    MDPage {
      providerStatus

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

      configurationCard

      if !model.cloudflareConfigured {
        setupGuideCard
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

  private var providerStatus: some View {
    ProviderStatusSection(model: model, provider: .cloudflare)
  }

  private var authorizationSection: some View {
    ProviderAuthorizationSection(clients: clients, openClient: openClient)
  }

  private var configurationCard: some View {
    ProviderDetailCard(
      title: L10n.text("connection.configuration"),
      symbol: "slider.horizontal.3",
      tone: .purple
    ) {
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

        MDTrailingActions {
          if model.tokenSaved || !model.savedPublicBaseURL.isEmpty {
            Button(role: .destructive) {
              confirmClearConfiguration = true
            } label: {
              Text(L10n.text("connection.clearConfiguration"))
                .frame(minWidth: 104)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
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
              .frame(minWidth: 104)
          }
          .buttonStyle(MDConnectedButtonStyle(
            kind: .filled,
            position: model.tokenSaved || !model.savedPublicBaseURL.isEmpty ? .last : .single))
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

      if !model.settingsMessage.isEmpty {
        InlineNotice(
          text: model.settingsMessage,
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
          .textSelection(.enabled)
      }

    }
  }

  private var setupGuideCard: some View {
    ProviderDetailCard(
      title: L10n.text("connection.setupGuide"),
      symbol: "list.number",
      tone: .blue
    ) {
      CloudflareConnectionHelp()
    }
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
      ProviderInfoText(
        text: L10n.text("connection.cloudflareStep1Description"),
        symbol: "info.circle")

      Button {
        guard let url = URL(string: "https://dash.cloudflare.com/?to=/:account/tunnels") else { return }
        NSWorkspace.shared.open(url)
      } label: {
        Label(L10n.text("connection.cloudflareStep1"), systemImage: "arrow.up.right")
      }
      .buttonStyle(MDButtonStyle(kind: .tonal))

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
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
      .background(MDListRowSurface(position: .single))
  }
}

struct SetupCopyRow: View {
  let title: String
  let value: String
  var enabled = true
  let accessibilityID: String
  @State private var copied = false
  @State private var copyFeedbackRevision = 0

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MDTheme.onSurfaceVariant)
        Text(value)
          .font(.system(size: 12).monospaced())
          .foregroundStyle(enabled ? MDTheme.onSurface : MDTheme.onSurfaceVariant)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
      }
      Spacer(minLength: 10)
      Button {
        guard enabled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        copyFeedbackRevision += 1
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .foregroundStyle(copied ? MDTheme.success : MDTheme.primary)
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .accessibilityLabel(L10n.format("clients.copy", title))
      .accessibilityIdentifier(accessibilityID)
    }
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
