import AppKit
import SwiftUI

extension ConnectionProviderID {
  var symbol: String { "lock.icloud" }
  var iconTone: MDIconTone { .green }
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
