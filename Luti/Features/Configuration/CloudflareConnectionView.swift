import AppKit
import SwiftUI

struct CloudflareConnectionView: View {
  let model: AppModel
  @Bindable var connection: CloudflareConnectionModel
  @State private var confirmClear = false

  init(model: AppModel) {
    self.model = model
    connection = model.cloudflare
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Toggle(L10n.text("cloudflare.enabled"), isOn: $connection.enabled)
        .disabled(model.active || connection.saving)
        .accessibilityIdentifier("cloudflare-enabled")

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
          Button { Task { await connection.save(project: model.project) } } label: {
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
      if let error = connection.error {
        InlineNotice(text: error, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }

      if connection.configured {
        HStack {
          Label(L10n.text(connection.statusKey), systemImage: connection.connection.state == .ready ? "checkmark.circle" : "cloud")
          Spacer()
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(connection.endpoint, forType: .string)
          } label: { Label(L10n.text("cloudflare.copy"), systemImage: "doc.on.doc") }
            .buttonStyle(.borderless)
        }
        Text(connection.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          .accessibilityIdentifier("cloudflare-endpoint")
        Text(L10n.text("cloudflare.connectGuide"))
          .font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
      } else {
        Text(L10n.text("cloudflare.setup"))
          .font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
      }
      HStack(alignment: .top) {
        Text(L10n.text("cloudflare.originService")).font(.footnote)
        Text(CloudflareContract.localService).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
      }
      Link(L10n.text("cloudflare.dashboard"), destination: URL(string: "https://one.dash.cloudflare.com/")!)
        .font(.footnote)

      Divider()
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
    VStack(alignment: .leading, spacing: 16) {
      if !connection.authorization.pending.isEmpty {
        Text(L10n.text("cloudflare.pending")).font(.headline)
        Text(L10n.text("cloudflare.verify"))
          .font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
        ForEach(connection.authorization.pending) { request in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(request.client.name).font(.headline)
              Spacer()
              Text(request.verification).font(.system(.title3, design: .monospaced).weight(.semibold))
            }
            Text(request.redirect).font(.footnote).textSelection(.enabled)
            Text(L10n.text("cloudflare.access")).font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
            MDButtonRun {
              Button { Task { await connection.decide(request.id, allow: false) } } label: {
                Text(L10n.text("cloudflare.deny")).frame(maxWidth: .infinity)
              }.buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
              Button { Task { await connection.decide(request.id, allow: true) } } label: {
                Text(L10n.text("cloudflare.allow")).frame(maxWidth: .infinity)
              }.buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
            }
          }
          .padding(16)
          .background(MDTheme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
        }
      }
      Text(L10n.text("cloudflare.apps")).font(.headline)
      Text(model.activeProject?.name ?? L10n.text("projects.noProjectsYet"))
        .font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
      if connection.authorization.applications.isEmpty {
        Text(L10n.text("cloudflare.noApps")).font(.footnote).foregroundStyle(MDTheme.onSurfaceVariant)
      }
      ForEach(connection.authorization.applications) { app in
        HStack(spacing: 12) {
          Image(systemName: "app.connected.to.app.below.fill").foregroundStyle(MDTheme.primary)
          VStack(alignment: .leading, spacing: 4) {
            Text(app.name).font(.body.weight(.medium))
            Text(app.callbackHost).font(.caption).foregroundStyle(MDTheme.onSurfaceVariant)
          }
          Spacer()
          Button(L10n.text("cloudflare.revoke"), role: .destructive) {
            Task { await connection.revoke(app.id) }
          }.buttonStyle(.borderless)
        }
      }
    }
    .accessibilityIdentifier("cloudflare-authorizations")
  }
}
