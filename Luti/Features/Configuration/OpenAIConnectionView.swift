import SwiftUI

/// Inline OpenAI Secure MCP Tunnel setup and connection control.
struct OpenAIConnectionView: View {
  @Bindable var model: AppModel
  @State private var confirmClearConfiguration = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      MDListRow(
        title: L10n.text("openai.enabled"),
        symbol: ConnectionProviderID.openAI.symbol,
        iconTone: ConnectionProviderID.openAI.iconTone
      ) {
        MDSwitch(
          isOn: $model.openAIEnabled,
          label: L10n.text("openai.enabled")
        )
        .disabled(!model.canEditConnection)
        .accessibilityIdentifier("openai-enabled")
      }

      if let message = model.connectionError
        ?? (model.connection.state == .failed ? model.connection.message : nil)
      {
        ProviderInfoCallout(text: message, symbol: "exclamationmark.triangle", tone: .red)
          .textSelection(.enabled)
      } else if model.connection.state == .reconnecting, !model.connection.message.isEmpty {
        ProviderInfoCallout(text: model.connection.message, symbol: "arrow.triangle.2.circlepath")
          .textSelection(.enabled)
      }

      configurationForm

      if !model.connectionConfigured {
        OpenAISetupGuide()
      }
    }
    .sheet(isPresented: $confirmClearConfiguration) {
      MDConfirmDialog(
        title: L10n.text("connection.clearConfigurationConfirmation"),
        message: L10n.text("connection.clearConfigurationMessage"),
        confirmTitle: L10n.text("connection.clearConfiguration"),
        icon: "trash.fill"
      ) {
        Task { await model.clearConnection() }
      }
    }
  }

  private var configurationForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 16) {
        MDInput(title: "Tunnel ID") {
          TextField("tunnel_…", text: $model.tunnelID)
            .autocorrectionDisabled()
            .accessibilityLabel("Tunnel ID")
            .accessibilityIdentifier("openai-tunnel-id")
        }

        MDInput(title: "Runtime API Key") {
          SecureField(
            model.apiKeySaved
              ? L10n.text("connection.savedLeaveBlankKeepCurrentToken")
              : L10n.text("connection.pasteAPIKey"),
            text: $model.apiKeyDraft)
            .autocorrectionDisabled()
            .accessibilityLabel("Runtime API Key")
            .accessibilityIdentifier("openai-api-key")
        }

        MDButtonRun {
          if hasSavedConfiguration {
            Button(role: .destructive) {
              confirmClearConfiguration = true
            } label: {
              Text(L10n.text("connection.clearConfiguration"))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
            .frame(maxWidth: .infinity)
            .disabled(model.savingConnection)
            .accessibilityIdentifier("clear-connection-configuration")
          }

          Button {
            Task { await model.saveConnection() }
          } label: {
            Text(L10n.text("connection.saveConfiguration"))
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MDConnectedButtonStyle(
            kind: .filled, position: hasSavedConfiguration ? .last : .single))
          .frame(maxWidth: .infinity)
          .disabled(!model.hasUnsavedConnection || model.savingConnection)
          .accessibilityIdentifier("save-configuration")
        }
      }
      .disabled(!model.canEditConnection)

      if !model.canEditConnection && !model.savingConnection {
        ProviderInfoCallout(
          text: L10n.text("connection.stopToEdit"),
          symbol: "lock",
          tone: .gray)
      }

      if let message = model.connectionSettingsError {
        InlineNotice(text: message, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var hasSavedConfiguration: Bool {
    model.apiKeySaved || !model.savedTunnelID.isEmpty
  }
}

private struct OpenAISetupGuide: View {
  var body: some View {
    MDDisclosure(title: L10n.text("connection.setupGuide")) {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(1...4, id: \.self) { step in
          SetupStep(
            number: step,
            title: L10n.text("provider.openai.step\(step).title"),
            detail: L10n.text("provider.openai.step\(step).detail"))
        }
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
    }
  }
}

#Preview("Setup Guide") {
  MDPage {
    OpenAISetupGuide()
  }
  .frame(width: 480, height: 520)
}
