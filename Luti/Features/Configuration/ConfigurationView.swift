import AppKit
import SwiftUI

struct ConfigurationView: View {
  @Bindable var model: AppModel
  @State private var clients = OAuthClientModel(store: OAuthStore(url: nil))
  @State private var selectedClientID: String?
  @State private var selectedProvider: ConnectionProviderID?
  @State private var localCopied = false
  @State private var localCopyFailed = false

  var body: some View {
    VStack(spacing: 0) {
      if let clientID = selectedClientID {
        MDDetailHeader(title: clientTitle(clients.client(clientID))) { selectedClientID = nil }
        RemoteClientDetailView(
          clients: clients,
          clientID: clientID,
          onDeleted: { selectedClientID = nil })
      } else if let provider = selectedProvider {
        MDDetailHeader(title: provider.title) { selectedProvider = nil }
        if provider == .cloudflare {
          CloudflareConnectionView(model: model, clients: clients, openClient: { selectedClientID = $0 })
        } else {
          ProviderConnectionView(model: model, clients: clients, provider: provider,
                                 openClient: { selectedClientID = $0 })
            .id(provider)
        }
      } else {
        overview
      }
    }
    .onAppear(perform: clients.reload)
    .onChange(of: model.remoteClients) { _, _ in clients.reload() }
    .onChange(of: model.currentRunID) { _, _ in
      localCopied = false
      localCopyFailed = false
    }
    .task(id: localCopied) {
      guard localCopied else { return }
      do { try await Task.sleep(for: .seconds(2)); localCopied = false } catch {}
    }
  }

  private var overview: some View {
    MDPage {
      localRuntimeSection

      MDSection(title: L10n.text("connection.tunnelProviders")) {
        MDList {
          ForEach(Array(ConnectionProviderID.allCases.enumerated()), id: \.element) { index, provider in
            MDSplitActionRow(title: provider.title, symbol: provider.symbol,
              subtitle: providerSummary(provider),
              position: MDListRowPosition(index: index, count: ConnectionProviderID.allCases.count),
              iconTone: provider.iconTone,
              accessory: "chevron.right", action: { openProvider(provider) }) {
              MDSwitch(isOn: Binding(
                get: { model.isProviderEnabled(provider) },
                set: { enabled in
                  if !model.setConnectionProviderEnabled(provider, enabled: enabled), enabled {
                    openProvider(provider)
                  }
                }), label: L10n.text("connection.providerEnabled"))
                .disabled(model.providerSnapshot(provider).state == .stopping)
                .accessibilityIdentifier(provider.rawValue + "-provider-enabled")
            }
            .accessibilityIdentifier("provider-" + provider.rawValue)
          }
        }
      }
    }
  }

  private var localRuntimeSection: some View {
    MDSection(title: L10n.text("connection.localRuntime")) {
      MDList {
        MDListRow(
          title: "Luti Runtime",
          symbol: "desktopcomputer",
          subtitle: L10n.text(runtimeStatusKey),
          position: .first,
          iconTone: model.phase == .running ? .green : .gray
        ) {
          Text(L10n.text(runtimeStatusKey))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.phase == .running ? MDTheme.success : MDTheme.onSurfaceVariant)
        }

        MDListRow(
          title: "Local MCP",
          symbol: "link",
          subtitle: localMCPSubtitle,
          position: .last,
          iconTone: .blue
        ) {
          if model.phase == .running, model.localEndpoint != nil {
            Button {
              Task {
                localCopied = await model.copyLocalConfiguration()
                localCopyFailed = !localCopied
              }
            } label: {
              Label(
                L10n.text(localCopied ? "connection.copied" : "connection.copyLocalSetup"),
                systemImage: localCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(MDButtonStyle(kind: .text))
            .accessibilityIdentifier("copy-local-configuration")
          }
        }
      }

      if localCopyFailed {
        InlineNotice(
          text: L10n.text("connection.copyFailed"),
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
      }
      if model.phase == .running {
        Text(L10n.text("connection.localCredentialHint"))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }
    }
  }

  private var localMCPSubtitle: String {
    if model.phase == .running, let endpoint = model.localEndpoint {
      return endpoint.absoluteString
    }
    return L10n.text("connection.localCompatibilityHint")
  }

  private var runtimeStatusKey: String {
    switch model.phase {
    case .stopped: "common.stopped"
    case .preparing: "common.preparing"
    case .starting: "common.starting"
    case .running: "common.running"
    case .stopping: "common.stopping"
    case .failed: "connection.runtimeFailed"
    }
  }

  private func openProvider(_ provider: ConnectionProviderID) {
    clients.use(store: model.authorizationStore(for: provider))
    model.settingsMessage = ""
    selectedProvider = provider
  }

  private func providerSummary(_ provider: ConnectionProviderID) -> String {
    let state = model.providerSnapshot(provider).state
    if state.isActive || state == .failed { return L10n.text("connection.state." + state.rawValue) }
    if !model.isConnectionProviderConfigured(provider) { return L10n.text("connection.providerSetupRequired") }
    return model.savedProviderAddress(provider)
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
