import AppKit
import SwiftUI

struct ConfigurationView: View {
  @Bindable var model: AppModel
  @State private var clients: OAuthClientModel
  @State private var selectedClientID: String?

  init(model: AppModel) {
    self.model = model
    _clients = State(initialValue: OAuthClientModel(store: model.authorizationStore(for: .cloudflare)))
  }

  var body: some View {
    VStack(spacing: 0) {
      if let clientID = selectedClientID {
        MDDetailHeader(title: clientTitle(clients.client(clientID))) { selectedClientID = nil }
        RemoteClientDetailView(
          clients: clients,
          clientID: clientID,
          onDeleted: { selectedClientID = nil })
      } else {
        overview
      }
    }
    .onAppear(perform: clients.reload)
    .onChange(of: model.remoteClients) { _, _ in clients.reload() }

  }

  private var overview: some View {
    MDPage {
      MDSection(title: ConnectionProviderID.cloudflare.title) {
        CloudflareConnectionView(
          model: model, clients: clients, openClient: { selectedClientID = $0 })
          .accessibilityIdentifier("provider-cloudflare")
      }
    }
  }

  private func clientTitle(_ record: OAuthClientRecord?) -> String {
    guard let record else { return L10n.text("clients.oauthClient") }
    let platform = record.host ?? RemoteMCPHost.detected(redirectURIs: record.redirectURIs)
    return platform == .custom ? record.name : platform.displayName
  }
}

struct AIClientConnectionRow: View {
  let record: OAuthClientRecord
  let grants: [OAuthStore.Grant]
  let position: MDListRowPosition
  @Binding var enabled: Bool
  let open: () -> Void

  private var platform: RemoteMCPHost {
    record.host ?? RemoteMCPHost.detected(redirectURIs: record.redirectURIs)
  }

  var body: some View {
    MDSplitActionRow(
      title: platform == .custom ? record.name : platform.displayName,
      symbol: platform.symbol,
      subtitle: subtitle,
      position: position,
      iconTone: tone,
      accessory: "chevron.right",
      action: open
    ) {
      MDSwitch(isOn: $enabled, label: L10n.text("clients.remoteAccess"))
        .accessibilityIdentifier("oauth-client-toggle-" + record.id)
    }
    .accessibilityIdentifier("oauth-client-" + record.id)
  }

  private var subtitle: String {
    guard record.isEnabled else { return L10n.text("clients.remoteAccessDisabled") }
    let live = grants.filter { $0.clientID == record.id }.count
    if live > 0 { return L10n.format("clients.authorizedConnectionsCount", live) }
    if platform == .custom { return L10n.text("clients.approvedUnknownPlatform") }
    return L10n.format("clients.detectedPlatformReady", platform.displayName)
  }

  private var tone: MDIconTone {
    switch platform {
    case .chatGPT: .green
    case .claude: .orange
    case .grok: .blue
    case .gemini: .purple
    case .custom: .gray
    }
  }
}
