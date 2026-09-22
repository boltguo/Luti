import AppKit
import SwiftUI

/// Durable OAuth clients appear here only after the Mac owner approved their first
/// authorization request. Dynamic registration itself never creates one of these rows.
@MainActor @Observable final class OAuthClientModel {
  var clients: [OAuthClientRecord] = []
  var grants: [OAuthStore.Grant] = []
  var message = ""
  @ObservationIgnored private var store: OAuthStore

  init(store: OAuthStore = .shared) {
    self.store = store
    reload()
  }

  func use(store: OAuthStore) {
    self.store = store
    message = ""
    reload()
  }

  func reload() {
    clients = store.approvedClients
    grants = store.activeGrants()
  }

  func client(_ id: String) -> OAuthClientRecord? {
    clients.first { $0.id == id }
  }

  func setEnabled(_ enabled: Bool, for id: String) {
    perform { try store.setEnabled(enabled, for: id) }
  }

  func revoke(_ authorization: UUID) {
    store.revokeAuthorization(authorization)
    reload()
  }

  func delete(_ id: String) {
    perform { try store.deleteClient(id) }
  }

  /// OAuth clients and grants are bound to the current public origin. When the
  /// provider origin or credentials are reset, keep no stale authorization that
  /// could be mistaken for access to the replacement origin.
  func invalidateOriginAuthorizations() {
    perform { try store.reset() }
  }

  private func perform(_ body: () throws -> Void) {
    do {
      try body()
      message = ""
    } catch {
      message = Failure.safe(error).message
    }
    reload()
  }
}

struct RemoteClientDetailView: View {
  @Bindable var clients: OAuthClientModel
  let clientID: String
  let onDeleted: () -> Void

  var body: some View {
    MDPage {
      if let record = clients.client(clientID) {
        ClientDetail(record: record, clients: clients, onDeleted: onDeleted)
      } else {
        InlineNotice(
          text: L10n.text("clients.clientNoLongerExists"),
          icon: "exclamationmark.triangle", color: MDTheme.warning)
      }
    }
    .onAppear(perform: clients.reload)
  }
}

private struct ClientDetail: View {
  let record: OAuthClientRecord
  @Bindable var clients: OAuthClientModel
  let onDeleted: () -> Void
  @State private var confirmDelete = false

  private var grants: [OAuthStore.Grant] {
    clients.grants.filter { $0.clientID == record.id }
  }

  private var platform: RemoteMCPHost {
    record.host ?? RemoteMCPHost.detected(redirectURIs: record.redirectURIs)
  }

  var body: some View {
    Group {
      MDSection(title: L10n.text("clients.connectionIdentity")) {
        MDList {
          MDListRow(
            title: L10n.text("clients.platform"), symbol: platform.symbol,
            subtitle: platform == .custom
              ? L10n.text("clients.platformUnverified")
              : L10n.format("clients.platformDetected", platform.displayName),
            position: .first, iconTone: platformTone
          ) {
            Text(platform == .custom ? record.name : platform.displayName)
              .font(.system(size: 12, weight: .medium))
          }
          CopyRow(
            title: "Client ID", value: record.id, position: .middle, tone: .purple)
          MDListRow(
            title: L10n.text("clients.authentication"), symbol: "key",
            subtitle: record.authMethod.rawValue, position: .last,
            iconTone: record.authMethod == .none ? .blue : .orange
          ) { EmptyView() }
        }
      }

      MDSection(title: L10n.text("clients.callbackURLs")) {
        MDList {
          ForEach(Array(record.redirectURIs.enumerated()), id: \.element) { index, uri in
            MDListRow(
              title: uri, symbol: "arrow.uturn.backward",
              position: MDListRowPosition(index: index, count: record.redirectURIs.count),
              iconTone: .orange
            ) { EmptyView() }
          }
        }
      }

      MDSection(title: L10n.text("clients.accessControl")) {
        MDList {
          MDListRow(
            title: L10n.text("clients.remoteAccess"), symbol: "network",
            subtitle: record.isEnabled
              ? L10n.text("clients.remoteAccessEnabled")
              : L10n.text("clients.remoteAccessDisabled"),
            position: .single, iconTone: record.isEnabled ? .green : .gray
          ) {
            MDSwitch(
              isOn: Binding(
                get: { record.isEnabled },
                set: { clients.setEnabled($0, for: record.id) }),
              label: L10n.text("clients.remoteAccess"))
              .accessibilityIdentifier("oauth-client-toggle-" + record.id)
          }
        }
      }

      MDSection(title: L10n.text("clients.authorizedConnections")) {
        if grants.isEmpty {
          Text(L10n.text("clients.noAuthorizations"))
            .font(.system(size: 12))
            .foregroundStyle(MDTheme.onSurfaceVariant)
        } else {
          MDList {
            ForEach(Array(grants.enumerated()), id: \.element.id) { index, grant in
              MDListRow(
                title: grant.scopes.map(\.rawValue).joined(separator: " "),
                symbol: "checkmark.seal",
                subtitle: L10n.format(
                  "clients.authorized",
                  grant.createdAt.formatted(date: .abbreviated, time: .shortened)),
                position: MDListRowPosition(index: index, count: grants.count),
                iconTone: .green
              ) {
                Button(L10n.text("clients.revoke")) { clients.revoke(grant.id) }
                  .buttonStyle(MDButtonStyle(kind: .text))
                  .accessibilityIdentifier("revoke-grant")
              }
            }
          }
        }
      }

      MDNavigationRow(
        title: L10n.text("clients.deleteClient"), symbol: "trash",
        foreground: MDTheme.error, iconTone: .red, accessory: nil
      ) {
        confirmDelete = true
      }
      .accessibilityIdentifier("delete-oauth-client")

      if !clients.message.isEmpty {
        InlineNotice(
          text: clients.message, icon: "exclamationmark.triangle", color: MDTheme.error)
          .textSelection(.enabled)
      }
    }
    .sheet(isPresented: $confirmDelete) {
      MDConfirmDialog(
        title: L10n.text("clients.deleteClientConfirm"),
        message: L10n.text("clients.deleteClientMessage"),
        confirmTitle: L10n.text("clients.deleteClient"),
        icon: "trash.fill"
      ) {
        clients.delete(record.id)
        if clients.message.isEmpty { onDeleted() }
      }
    }
  }

  private var platformTone: MDIconTone {
    switch platform {
    case .chatGPT: .green
    case .claude: .orange
    case .grok: .blue
    case .gemini: .purple
    case .custom: .gray
    }
  }
}

/// A value the Mac's owner may need to inspect or copy. Dynamic registration means
/// credentials are no longer manually moved between apps, so this is informational.
private struct CopyRow: View {
  let title: String
  let value: String
  let position: MDListRowPosition
  let tone: MDIconTone
  @State private var copied = false

  var body: some View {
    MDListRow(title: title, symbol: "doc.on.doc", position: position, iconTone: tone) {
      HStack(spacing: 8) {
        Text(Budget.prefix(value, bytes: 28))
          .font(.system(size: 11).monospaced()).foregroundStyle(MDTheme.onSurfaceVariant)
          .lineLimit(1).truncationMode(.middle)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(value, forType: .string)
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copied ? MDTheme.success : MDTheme.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("clients.copy", title))
      }
    }
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
