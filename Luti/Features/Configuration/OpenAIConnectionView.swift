import SwiftUI

/// Inline OpenAI Secure MCP Tunnel setup and connection control.
struct OpenAIConnectionView: View {
  @Bindable var model: AppModel
  @State private var confirmClearConfiguration = false

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if let message = model.connectionError
        ?? (model.connection.state == .failed ? model.connection.message : nil)
      {
        ProviderInfoCallout(text: message, symbol: "exclamationmark.triangle", tone: .red)
          .textSelection(.enabled)
      }

      if model.phase == .running && model.connectionConfigured {
        connectionControl
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

  /// Reconnect or disconnect the tunnel alone; the runtime and its jobs keep running.
  private var connectionControl: some View {
    let connected = [.ready, .reconnecting].contains(model.connection.state)
    return Button {
      if connected {
        Task { await model.disconnectRemote() }
      } else {
        model.connectRemote()
      }
    } label: {
      Label(
        L10n.text(connected ? "connection.disconnect" : "connection.connect"),
        systemImage: connected ? "stop.fill" : "arrow.clockwise")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(MDButtonStyle(kind: .tonal))
    .disabled(model.connectionBusy || (!connected && !model.canConnect))
    .accessibilityIdentifier("connection-toggle")
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

      if !model.canEditConnection {
        ProviderInfoCallout(
          text: L10n.text("connection.disconnectToEdit"),
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
    ProviderDetailCard(title: L10n.text("connection.setupGuide")) {
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

private struct SetupStep: View {
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

#Preview("Setup Guide") {
  MDPage {
    OpenAISetupGuide()
  }
  .frame(width: 480, height: 520)
}
