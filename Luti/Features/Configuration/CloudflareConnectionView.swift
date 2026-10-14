import AppKit
import SwiftUI

struct CloudflareConnectionView: View {
  let model: AppModel
  @Bindable var connection: CloudflareConnectionModel
  @State private var confirmClear = false
  @State private var copied = false
  @State private var copyRevision = 0

  init(model: AppModel) {
    self.model = model
    connection = model.cloudflare
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      MDListRow(
        title: L10n.text("cloudflare.enabled"),
        symbol: ConnectionProviderID.cloudflare.symbol,
        iconTone: ConnectionProviderID.cloudflare.iconTone
      ) {
        MDSwitch(
          isOn: $connection.enabled,
          label: L10n.text("cloudflare.enabled")
        )
        .disabled(model.active || connection.saving)
        .accessibilityIdentifier("cloudflare-enabled")
      }

      if let message = connection.error
        ?? (connection.connection.state == .failed ? connection.connection.message : nil),
        !message.isEmpty
      {
        ProviderInfoCallout(text: message, symbol: "exclamationmark.triangle", tone: .red)
          .textSelection(.enabled)
      } else if connection.connection.state == .reconnecting, !connection.connection.message.isEmpty {
        ProviderInfoCallout(text: connection.connection.message, symbol: "arrow.triangle.2.circlepath")
          .textSelection(.enabled)
      }

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 16) {
          MDInput(title: L10n.text("cloudflare.domain")) {
            TextField("https://mcp.example.com", text: $connection.domain)
              .autocorrectionDisabled()
              .accessibilityIdentifier("cloudflare-domain")
          }
          MDInput(title: "Tunnel Token") {
            SecureField(connection.tokenSaved
              ? L10n.text("connection.savedLeaveBlankKeepCurrentToken") : L10n.text("cloudflare.token"),
              text: $connection.tokenDraft)
              .autocorrectionDisabled()
              .accessibilityIdentifier("cloudflare-token")
          }
          MDButtonRun {
            if connection.configured {
              Button(role: .destructive) { confirmClear = true } label: {
                Text(L10n.text("connection.clearConfiguration")).frame(maxWidth: .infinity)
              }
              .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
            }
            Button { Task { await connection.save() } } label: {
              Text(L10n.text("connection.saveConfiguration")).frame(maxWidth: .infinity)
            }
            .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: connection.configured ? .last : .single))
            .disabled(!connection.hasUnsavedChanges)
            .accessibilityIdentifier("cloudflare-save")
          }
        }
        .disabled(model.active || connection.saving)

        if model.active {
          ProviderInfoCallout(text: L10n.text("connection.stopToEdit"), symbol: "lock", tone: .gray)
        }
      }

      if connection.configured {
        MDListRow(
          title: connection.endpoint,
          symbol: connection.connection.state == .ready ? "checkmark.circle" : "link",
          subtitle: L10n.text(connection.statusKey),
          iconTone: connection.connection.state == .ready ? .green : .yellow,
          textLineLimit: 1
        ) {
          MDIconActionButton(
            symbol: copied ? "checkmark" : "doc.on.doc",
            label: L10n.text("cloudflare.copy")
          ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(connection.endpoint, forType: .string)
            copied = true
            copyRevision += 1
          }
        }
        .accessibilityIdentifier("cloudflare-endpoint")
        .task(id: copyRevision) {
          guard copied else { return }
          try? await Task.sleep(for: .seconds(2))
          copied = false
        }
      } else {
        CloudflareSetupGuide()
      }

      authorizations
    }
    .sheet(isPresented: $confirmClear) {
      MDConfirmDialog(title: L10n.text("connection.clearConfigurationConfirmation"),
        message: L10n.text("cloudflare.clearNotice"), confirmTitle: L10n.text("connection.clearConfiguration"), icon: "trash.fill") {
          Task { await connection.clear() }
        }
    }
  }

  private var authorizations: some View {
    MDSection(title: L10n.text("cloudflare.apps")) {
      if connection.authorization.applications.isEmpty {
        MDEmptyState(
          title: L10n.text("cloudflare.noAppsTitle"),
          message: L10n.text("cloudflare.noApps"),
          symbol: "app.connected.to.app.below.fill")
      } else {
        MDList {
          ForEach(Array(connection.authorization.applications.enumerated()), id: \.element.id) { index, app in
            MDListRow(
              title: app.name,
              symbol: "app.connected.to.app.below.fill",
              subtitle: app.callbackHost,
              position: MDListRowPosition(index: index, count: connection.authorization.applications.count),
              iconTone: .purple
            ) {
              Button(L10n.text("cloudflare.revoke"), role: .destructive) {
                Task { await connection.revoke(app.id) }
              }
              .buttonStyle(MDButtonStyle(kind: .tonal))
            }
          }
        }
      }
    }
    .accessibilityIdentifier("cloudflare-authorizations")
  }
}

private struct CloudflareSetupGuide: View {
  var body: some View {
    MDDisclosure(title: L10n.text("connection.setupGuide")) {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(1...4, id: \.self) { step in
          SetupStep(
            number: step,
            title: L10n.text("provider.cloudflare.step\(step).title"),
            detail: L10n.text("provider.cloudflare.step\(step).detail"))
        }
      }

      MDButtonRun {
        Link(destination: URL(string: "https://dash.cloudflare.com/?to=/:account/tunnels")!) {
          Label(L10n.text("provider.openCloudflareDashboard"), systemImage: "arrow.up.right")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .single))
      }
      .frame(maxWidth: .infinity)
    }
  }
}
