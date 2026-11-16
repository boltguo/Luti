import AppKit
import SwiftUI

extension ConnectionProviderID {
  @MainActor var displayTitle: String { self == .vps ? L10n.text("vps.title") : title }
  var symbol: String { self == .openAI ? "lock.icloud" : self == .vps ? "server.rack" : "cloud" }
  var iconTone: MDIconTone { self == .openAI ? .green : .yellow }
}

struct SetupStep: View {
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
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
