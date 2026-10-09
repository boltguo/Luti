import AppKit
import SwiftUI

extension ConnectionProviderID {
  var symbol: String { "network" }
  var iconTone: MDIconTone { .orange }
}

/// Provider details follow the same single-level section hierarchy as the
/// surrounding settings pages. Lists and lightweight callouts provide the
/// surfaces; the section itself never adds another card around them.
struct ProviderDetailCard<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    MDSection(title: title) {
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct ProviderInfoCallout: View {
  let text: String
  var symbol = "info.circle"
  var tone: MDIconTone = .yellow

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(tone.foreground)
        .frame(width: 20)
        .accessibilityHidden(true)

      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(textColor)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.container, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var textColor: Color {
    switch tone {
    case .red: MDTheme.onErrorContainer
    default: MDTheme.onSurfaceVariant
    }
  }
}

struct ProviderInfoText: View {
  let text: String
  var symbol = "info.circle"

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .frame(width: 22)
        .accessibilityHidden(true)

      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 4)
  }
}

struct ProviderAuthorizationSection: View {
  @Bindable var clients: OAuthClientModel
  let openClient: (String) -> Void

  var body: some View {
    ProviderDetailCard(
      title: L10n.text("connection.aiApps")
    ) {
      MDList {
        let rows = Array(clients.clients.reversed())
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
          AIClientConnectionRow(
            record: record,
            grants: clients.grants,
            position: MDListRowPosition(index: index, count: rows.count),
            enabled: Binding(
              get: { clients.client(record.id)?.isEnabled ?? false },
              set: { clients.setEnabled($0, for: record.id) }),
            open: { openClient(record.id) })
        }
      }

      if !clients.message.isEmpty {
        InlineNotice(
          text: clients.message,
          icon: "exclamationmark.triangle",
          color: MDTheme.error)
      }
    }
  }
}
