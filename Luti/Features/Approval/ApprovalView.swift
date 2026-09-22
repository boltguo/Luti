import SwiftUI

/// The one place a connection is granted.
///
/// It is native on purpose. The browser that started the flow may belong to
/// someone else entirely, so an HTML "Allow" button would prove nothing; this
/// window can only be reached by whoever is sitting at the Mac.
struct OperationApprovalView: View {
  let request: PendingOperationApproval
  let decide: (Bool) -> Void

  var body: some View {
    MDModalSurface(width: 430) {
      MDModalHeader(
        title: L10n.text("operationApproval.title"),
        message: L10n.text("operationApproval.explanation"),
        symbol: "exclamationmark.shield",
        tone: .orange)

      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text("operationApproval.command")).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
        Text(request.summary)
          .font(.system(size: 11).monospaced())
          .textSelection(.enabled)
          .lineLimit(6)
        Text(request.reason)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.warning)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.text("operationApproval.project")).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
        Text(request.projectPath)
          .font(.system(size: 11).monospaced())
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .textSelection(.enabled)
          .lineLimit(2).truncationMode(.middle)
      }

      Text(L10n.text("operationApproval.oneShot"))
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)

      MDModalActions {
        Button { decide(false) } label: {
          Text(L10n.text("approval.deny"))
            .frame(minWidth: 104)
        }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
          .accessibilityIdentifier("operation-approval-deny")

        Button { decide(true) } label: {
          Text(L10n.text("operationApproval.allowOnce"))
            .frame(minWidth: 104)
        }
          .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
          .accessibilityIdentifier("operation-approval-allow")
      }
    }
    .accessibilityIdentifier("operation-approval-sheet")
  }
}

struct ApprovalView: View {
  let request: PendingAuthorization
  let queued: Int
  let decide: (Bool) -> Void

  var body: some View {
    MDModalSurface(width: 430) {
      MDModalHeader(
        title: L10n.text("approval.allowConnection"),
        message: L10n.format("approval.requestingAccessMac", request.clientName),
        symbol: "person.badge.key",
        tone: .purple)

      if request.isDynamicallyRegistered {
        Text(
          request.clientPlatform == .custom
            ? L10n.text("approval.dynamicClientUnverified")
            : L10n.format("approval.dynamicClientDetected", request.clientPlatform.displayName)
        )
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(
          request.clientPlatform == .custom ? MDTheme.warning : MDTheme.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text("approval.receivePermissions")).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
        MDList {
          ForEach(Array(request.sortedScopes.enumerated()), id: \.element) { index, scope in
            MDListRow(
              title: scope.title, symbol: scope.symbol,
              position: MDListRowPosition(index: index, count: request.sortedScopes.count),
              iconTone: tone(scope)
            ) {
              Text(scope.rawValue).font(.system(size: 11).monospaced())
                .foregroundStyle(MDTheme.onSurfaceVariant)
            }
          }
        }
      }

      // Scopes are admission, not authority. Saying so here stops Allow from
      // reading as "this client may now do all of that", which it is not.
      Text(L10n.text("approval.accessRemainsLimitedCurrentProjectTool"))
        .font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)

      Text(request.redirectURI).font(.system(size: 11).monospaced())
        .foregroundStyle(MDTheme.onSurfaceVariant).textSelection(.enabled)
        .lineLimit(2).truncationMode(.middle)

      if queued > 0 {
        Text(L10n.format("approval.moreRequestsWaiting", queued))
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
      }

      MDModalActions {
        Button { decide(false) } label: {
          Text(L10n.text("approval.deny"))
            .frame(minWidth: 104)
        }
          .keyboardShortcut(.cancelAction)
          .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
          .accessibilityIdentifier("approval-deny")

        Button { decide(true) } label: {
          Text(L10n.text("approval.allow"))
            .frame(minWidth: 104)
        }
          .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
          .accessibilityIdentifier("approval-allow")
      }
    }
    .accessibilityIdentifier("approval-sheet")
  }

  private func tone(_ scope: OAuthScope) -> MDIconTone {
    switch scope {
    case .projectRead: .blue
    case .projectWrite: .purple
    case .processRun: .orange
    case .browserUse: .green
    case .computerRead: .yellow
    case .computerControl: .pink
    }
  }
}
