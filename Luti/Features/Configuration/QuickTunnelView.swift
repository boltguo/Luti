import SwiftUI

/// Session-scoped remote access for quickly trying a web MCP host.
/// It has no saved configuration, no auto-start switch and no stable hostname.
struct QuickTunnelView: View {
  @Bindable var model: AppModel
  @Bindable var clients: OAuthClientModel
  let openClient: (String) -> Void

  private var state: ConnectionSnapshot { model.providerSnapshot(.quick) }

  var body: some View {
    MDPage {
      statusCard

      ProviderInfoCallout(
        text: L10n.text("quick.temporaryNotice"),
        symbol: "exclamationmark.triangle.fill",
        tone: .red)

      if let url = model.configuredMCPServerURL(.quick) {
        ProviderMCPURLRow(
          value: url.absoluteString,
          accessibilityID: "copy-provider-url-quick")
      }

      if let message = model.providerConnectionError(.quick)
        ?? (state.state == .failed ? state.message : nil)
      {
        ProviderInfoCallout(
          text: message,
          symbol: "exclamationmark.triangle",
          tone: .red)
          .textSelection(.enabled)
      }

      if model.phase != .running {
        ProviderInfoCallout(
          text: L10n.text("quick.runtimeRequired"),
          symbol: "play.circle",
          tone: .gray)
      }

      MDTrailingActions {
        if state.state.isActive || state.state == .failed {
          Button(role: .destructive) {
            Task {
              await model.stopQuickTunnel()
              clients.reload()
            }
          } label: {
            Text(L10n.text("quick.stop"))
              .frame(minWidth: 120)
          }
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .single))
          .disabled(state.state == .stopping)
          .accessibilityIdentifier("stop-quick-tunnel")
        } else {
          Button {
            model.startQuickTunnel()
          } label: {
            Text(L10n.text("quick.start"))
              .frame(minWidth: 120)
          }
          .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .single))
          .disabled(!model.canStartQuickTunnel)
          .accessibilityIdentifier("start-quick-tunnel")
        }
      }

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
    .onAppear(perform: clients.reload)
  }

  private var statusCard: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(L10n.text("quick.statusTitle"))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(MDTheme.onPrimaryContainer)

        Text(statusSummary)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onPrimaryContainer.opacity(0.72))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Label(
        L10n.text("connection.state." + state.state.rawValue),
        systemImage: statusSymbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor.opacity(0.10), in: Capsule())
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
    .background(
      MDTheme.primaryContainer,
      in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var statusSummary: String {
    if state.state == .ready, state.publicOrigin != nil {
      return L10n.text("quick.readySummary")
    }
    if state.state == .reconnecting, state.publicOrigin != nil {
      return L10n.text("quick.reconnectingSummary")
    }
    if state.state == .starting {
      return L10n.text("quick.startingSummary")
    }
    if model.phase != .running, state.state == .stopped {
      return L10n.text("quick.runtimeRequired")
    }
    if state.state == .stopped || state.state == .failed {
      return L10n.text("quick.rowSubtitle")
    }
    return L10n.text("connection.state." + state.state.rawValue)
  }

  private var statusSymbol: String {
    switch state.state {
    case .ready: "checkmark.circle.fill"
    case .starting, .reconnecting: "arrow.triangle.2.circlepath"
    case .stopping: "stop.circle"
    case .failed: "exclamationmark.triangle.fill"
    case .stopped: "bolt.horizontal.icloud"
    }
  }

  private var statusColor: Color {
    switch state.state {
    case .ready: MDTheme.success
    case .failed: MDTheme.error
    case .starting, .reconnecting, .stopping: MDTheme.warning
    case .stopped: MDTheme.onPrimaryContainer
    }
  }
}
