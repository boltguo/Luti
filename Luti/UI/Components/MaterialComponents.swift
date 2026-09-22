import SwiftUI

/// Material 3 / M3 Expressive color roles.
enum MDTheme {
  static let primary = adaptive(0x6750A4, 0xD0BCFF)
  static let onPrimary = adaptive(0xFFFFFF, 0x381E72)
  static let primaryContainer = adaptive(0xEADDFF, 0x4F378B)
  static let onPrimaryContainer = adaptive(0x21005D, 0xEADDFF)

  // Surface hierarchy sampled from the supplied Material reference.
  static let surface = adaptive(0xFEF7FF, 0x141218)
  static let surfaceContainerLow = adaptive(0xF7F2FA, 0x1D1B20)
  static let surfaceContainer = adaptive(0xF3EDF7, 0x211F26)
  static let surfaceContainerHigh = adaptive(0xECE6F0, 0x2B2930)
  static let surfaceContainerHighest = adaptive(0xE6E0E9, 0x36343B)

  static let onSurface = adaptive(0x1D1B20, 0xE6E0E9)
  static let onSurfaceVariant = adaptive(0x49454F, 0xCAC4D0)
  static let outline = adaptive(0x79747E, 0x938F99)
  static let outlineVariant = adaptive(0xCAC4D0, 0x49454F)

  // Compatibility aliases while feature views move to semantic role names.
  static let container = surfaceContainer
  static let containerHigh = surfaceContainerHigh
  static let secondary = onSurfaceVariant

  static let success = adaptive(0x386A20, 0xAAD38D)
  static let warning = adaptive(0x825500, 0xFFCC80)
  static let error = adaptive(0xB3261E, 0xF2B8B5)
  static let onError = adaptive(0xFFFFFF, 0x601410)
  static let errorContainer = adaptive(0xF9DEDC, 0x8C1D18)
  static let onErrorContainer = adaptive(0x410E0B, 0xF9DEDC)
  static let scrim = Color.black

  // Pastel icon containers follow the Pixel / Material settings pattern:
  // categories keep their own stable accent instead of borrowing selection state.
  static let iconBlue = adaptive(0x0B57D0, 0xA8C7FA)
  static let iconBlueContainer = adaptive(0xD7E9FF, 0x183A5A)
  static let iconPink = adaptive(0xA30D5B, 0xFFB1C8)
  static let iconPinkContainer = adaptive(0xFFD9E7, 0x5A2137)
  static let iconOrange = adaptive(0x8B4500, 0xFFB77A)
  static let iconOrangeContainer = adaptive(0xFFE0C2, 0x5A3214)
  static let iconYellow = adaptive(0x6A5200, 0xE6C85C)
  static let iconYellowContainer = adaptive(0xFFE59A, 0x514000)
  static let iconGreen = adaptive(0x126C2D, 0x9CD59F)
  static let iconGreenContainer = adaptive(0xCFEFCE, 0x214324)
  static let iconGray = adaptive(0x50545A, 0xC7C7CC)
  static let iconGrayContainer = adaptive(0xE4E4E4, 0x39393B)

  private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(red: CGFloat((value >> 16) & 255) / 255,
                     green: CGFloat((value >> 8) & 255) / 255,
                     blue: CGFloat(value & 255) / 255, alpha: 1)
    })
  }
}

enum MDIconTone {
  case purple, blue, pink, orange, yellow, green, gray, red

  var foreground: Color {
    switch self {
    case .purple: MDTheme.onPrimaryContainer
    case .blue: MDTheme.iconBlue
    case .pink: MDTheme.iconPink
    case .orange: MDTheme.iconOrange
    case .yellow: MDTheme.iconYellow
    case .green: MDTheme.iconGreen
    case .gray: MDTheme.iconGray
    case .red: MDTheme.error
    }
  }

  var container: Color {
    switch self {
    case .purple: MDTheme.primaryContainer
    case .blue: MDTheme.iconBlueContainer
    case .pink: MDTheme.iconPinkContainer
    case .orange: MDTheme.iconOrangeContainer
    case .yellow: MDTheme.iconYellowContainer
    case .green: MDTheme.iconGreenContainer
    case .gray: MDTheme.iconGrayContainer
    case .red: MDTheme.errorContainer
    }
  }
}

struct MDPage<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    MDScrollView {
      VStack(alignment: .leading, spacing: 22) { content }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }.background(MDTheme.surface)
  }
}

/// Native vertical scrolling with the scroll indicator intentionally hidden.
///
/// Do not customize NSScrollView / NSScroller here. The content remains fully
/// scrollable by trackpad, mouse wheel and keyboard; only the visual indicator
/// is not shown.
struct MDScrollView<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      content
    }
  }
}

struct MDSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(MDTheme.onSurfaceVariant)
      content
    }
  }
}

struct MDCard<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content }
      .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(MDTheme.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

struct MDEmptyState: View {
  let title: String
  var message: String? = nil
  var symbol = "tray"

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(MDTheme.primary)
        .frame(width: 48, height: 48)
        .background(MDTheme.primaryContainer, in: Circle())
        .accessibilityHidden(true)

      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(MDTheme.onSurface)
        .multilineTextAlignment(.center)

      if let message {
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .padding(.horizontal, 20)
    .background(
      MDTheme.surfaceContainerLow,
      in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

struct MDLoadingState: View {
  var title: String? = nil
  var size: CGFloat = 44

  var body: some View {
    VStack(spacing: 12) {
      MDLoadingIndicator(size: size)
      if let title {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}

/// Compact M3 list geometry. A single row stays a rounded rectangle rather
/// than becoming a capsule; connected rows still expose their grouping.
private enum MDListMetrics {
  static let gap: CGFloat = 3
  static let outerRadius: CGFloat = 20
  static let innerRadius: CGFloat = 6
}

struct MDList<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    VStack(spacing: MDListMetrics.gap) { content }
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum MDListRowPosition {
  case single
  case first
  case middle
  case last

  init(index: Int, count: Int) {
    if count <= 1 {
      self = .single
    } else if index == 0 {
      self = .first
    } else if index == count - 1 {
      self = .last
    } else {
      self = .middle
    }
  }

  var shape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
      bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
      style: .continuous)
  }

  fileprivate var topRadius: CGFloat {
    switch self {
    case .single, .first: MDListMetrics.outerRadius
    case .middle, .last: MDListMetrics.innerRadius
    }
  }

  fileprivate var bottomRadius: CGFloat {
    switch self {
    case .single, .last: MDListMetrics.outerRadius
    case .first, .middle: MDListMetrics.innerRadius
    }
  }
}

struct MDListRowSurface: View {
  let position: MDListRowPosition
  var body: some View { position.shape.fill(MDTheme.surfaceContainerLow) }
}

struct MDListRow<Trailing: View>: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var position: MDListRowPosition = .single
  var prominent = false
  var foreground: Color? = nil
  var iconTone: MDIconTone = .purple
  var textLineLimit = 2
  var subtitleTruncationMode: Text.TruncationMode = .middle
  var leadingWidth: CGFloat = 36
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(foreground ?? iconTone.foreground)
        .frame(width: 36, height: 36)
        .background(iconTone.container, in: Circle())
        .frame(width: leadingWidth)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(foreground ?? MDTheme.onSurface)
          .lineLimit(textLineLimit)
          .truncationMode(.tail)
          .help(title)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .lineLimit(textLineLimit)
            .truncationMode(subtitleTruncationMode)
            .help(subtitle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      trailing.fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .background(MDListRowSurface(position: position))
  }
}

/// Navigation is one full-row action. Never nest a trailing button inside it.
struct MDSplitActionRow<Trailing: View>: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var position: MDListRowPosition = .single
  var iconTone: MDIconTone = .purple
  var accessory: String? = nil
  var action: (() -> Void)? = nil
  @ViewBuilder let trailing: Trailing
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 0) {
      leading
        .padding(.trailing, 12)
        .onHover { isHovered = $0 }

      Rectangle()
        .fill(MDTheme.outlineVariant)
        .frame(width: 1, height: 32)
        .padding(.trailing, 12)
        .accessibilityHidden(true)

      trailing.fixedSize(horizontal: true, vertical: false)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    .background(MDListRowSurface(position: position))
    .overlay(
      position.shape
        .fill(MDTheme.primary.opacity(isHovered ? 0.05 : 0))
        .allowsHitTesting(false)
    )
    .contentShape(position.shape)
  }

  @ViewBuilder private var leading: some View {
    if let action {
      Button(action: action) { label }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      label
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var label: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(iconTone.foreground)
        .frame(width: 36, height: 36)
        .background(iconTone.container, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(MDTheme.onSurface)
          .lineLimit(2)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let accessory {
        Image(systemName: accessory)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(MDTheme.onSurfaceVariant)
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }
}

struct MDNavigationRow: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var detail: String? = nil
  var position: MDListRowPosition = .single
  var prominent = false
  var foreground: Color? = nil
  var iconTone: MDIconTone = .purple
  var accessory: String? = "chevron.right"
  let action: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      MDListRow(title: title, symbol: symbol, subtitle: subtitle, position: position,
                prominent: prominent, foreground: foreground, iconTone: iconTone) {
        HStack(spacing: 8) {
          if let detail {
            Text(detail).font(.system(size: 12, weight: prominent ? .semibold : .regular))
              .foregroundStyle(foreground ?? (prominent ? MDTheme.primary : MDTheme.onSurfaceVariant))
              .lineLimit(1)
          }
          if let accessory {
            Image(systemName: accessory)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(foreground ?? MDTheme.onSurfaceVariant)
              .accessibilityHidden(true)
          }
        }
      }
      .contentShape(position.shape)
    }
    .buttonStyle(MDRowButtonStyle(position: position, isFocused: isFocused))
    .focusable().focusEffectDisabled().focused($isFocused)
  }
}

private struct MDRowButtonStyle: ButtonStyle {
  let position: MDListRowPosition
  var isFocused = false
  func makeBody(configuration: Configuration) -> some View {
    MDRowButtonBody(configuration: configuration, position: position, isFocused: isFocused)
  }
}

private struct MDRowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let position: MDListRowPosition
  let isFocused: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  var body: some View {
    configuration.label
      .overlay(position.shape.fill(MDTheme.primary.opacity(
        isEnabled ? (configuration.isPressed ? 0.12 : isFocused ? 0.08 : isHovered ? 0.06 : 0) : 0))
        .allowsHitTesting(false))
      .opacity(isEnabled ? 1 : 0.38)
      .onHover { isHovered = $0 }
  }
}

/// Compact desktop mapping of the Pixel / M3 small top app bar.
///
/// Pixel settings pages place the title directly after the circular back action;
/// centering the title in the whole window makes short and long titles jump
/// horizontally between pages, so detail titles stay leading-aligned.
struct MDDetailHeader<Trailing: View>: View {
  let title: String
  let back: () -> Void
  @ViewBuilder let trailing: Trailing

  init(
    title: String,
    back: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.back = back
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 12) {
      Button(action: back) {
        Image(systemName: "chevron.left")
          .font(.system(size: 18, weight: .semibold))
          .frame(width: 40, height: 40)
      }
      .buttonStyle(MDIconButtonStyle())
      .keyboardShortcut("[", modifiers: .command)
      .accessibilityLabel(L10n.text("common.back"))
      .accessibilityIdentifier("detail-back")

      Text(title)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(MDTheme.onSurface)
        .lineLimit(1).truncationMode(.middle).help(title)

      Spacer(minLength: 0)
      trailing
    }
    .frame(height: 64)
    .padding(.horizontal, 20)
    .background(MDTheme.surface)
  }
}

extension MDDetailHeader where Trailing == EmptyView {
  init(title: String, back: @escaping () -> Void) {
    self.init(title: title, back: back) { EmptyView() }
  }
}

private struct MDIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(MDTheme.onSurfaceVariant)
      .background(MDTheme.surfaceContainerHigh, in: Circle())
      .overlay(Circle().fill(MDTheme.primary.opacity(configuration.isPressed ? 0.12 : 0)))
      .contentShape(Circle())
  }
}

/// Secondary content can expand without becoming another large rounded list item.
struct MDDisclosure<Content: View>: View {
  let title: String
  var symbol = "info.circle"
  @ViewBuilder let content: Content
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: symbol).frame(width: 24)
          Text(title).font(.system(size: 14, weight: .semibold))
          Spacer()
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(MDFlatActionStyle())
      .accessibilityValue(expanded ? L10n.text("ui.expanded") : L10n.text("ui.collapsed"))
      if expanded { content }
    }
  }
}

private struct MDFlatActionStyle: ButtonStyle {
  @State private var hovered = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(MDTheme.onSurface)
      .background(MDTheme.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0),
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .onHover { hovered = $0 }
  }
}

struct MDRow<Trailing: View>: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  @ViewBuilder let trailing: Trailing
  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(MDTheme.primary)
        .frame(width: 24).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(MDTheme.onSurface)
        if let subtitle {
          Text(subtitle).font(.system(size: 12)).foregroundStyle(MDTheme.onSurfaceVariant)
            .lineLimit(2).truncationMode(.middle).help(subtitle)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      trailing.fixedSize(horizontal: true, vertical: false)
    }.frame(minHeight: 36)
  }
}

struct MDDivider: View {
  var body: some View { Rectangle().fill(MDTheme.outlineVariant).frame(height: 1) }
}

struct MDFloatingActionButton: View {
  let label: String
  var symbol = "plus"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 56, height: 56)
    }
    .buttonStyle(MDFloatingActionButtonStyle())
    .accessibilityLabel(label)
  }
}

struct MDIconActionButton: View {
  let symbol: String
  let label: String
  var destructive = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 40, height: 40)
    }
    .buttonStyle(MDIconActionButtonStyle(destructive: destructive))
    .accessibilityLabel(label)
  }
}

private struct MDIconActionButtonStyle: ButtonStyle {
  let destructive: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    let shape = Circle()
    configuration.label
      .foregroundStyle(destructive ? MDTheme.error : MDTheme.primary)
      .background(
        destructive ? MDTheme.errorContainer : MDTheme.surfaceContainerHigh,
        in: shape)
      .overlay(
        shape.fill(
          MDTheme.primary.opacity(
            configuration.isPressed ? 0.12 : hovered ? 0.06 : 0)))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
      .onHover { hovered = $0 && isEnabled }
  }
}

private struct MDFloatingActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    return configuration.label
      .foregroundStyle(MDTheme.onPrimaryContainer)
      .background(MDTheme.primaryContainer, in: shape)
      .overlay(shape.fill(MDTheme.onPrimaryContainer.opacity(configuration.isPressed ? 0.10 : 0)))
      .shadow(color: MDTheme.onSurface.opacity(0.18), radius: 8, y: 3)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
  }
}

/// Material content inside the native macOS sheet shell.
///
/// macOS owns modality, focus and the outer window corner. Luti owns every
/// visible interior surface. Filling the sheet background directly avoids the
/// white corner wedges caused by placing a second rounded card inside it.
struct MDModalSurface<Content: View>: View {
  let width: CGFloat
  @ViewBuilder let content: Content

  init(width: CGFloat = 430, @ViewBuilder content: () -> Content) {
    self.width = width
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      content
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 30)
    .frame(width: width, alignment: .leading)
    .background(MDTheme.surfaceContainerHigh)
    .presentationBackground(MDTheme.surfaceContainerHigh)
  }
}

struct MDModalHeader: View {
  let title: String
  var message: String? = nil
  let symbol: String
  var tone: MDIconTone = .purple

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: symbol)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(tone.foreground)
        .frame(width: 44, height: 44)
        .background(tone.container, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(MDTheme.onSurface)
          .fixedSize(horizontal: false, vertical: true)

        if let message, !message.isEmpty {
          Text(message)
            .font(.system(size: 13))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct MDTrailingActions<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      MDButtonRun { content }
    }
  }
}

struct MDModalActions<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    MDTrailingActions { content }
      .padding(.top, 4)
  }
}

/// Destructive / irreversible confirmation. Feature views must not fall back to
/// the platform action-sheet-looking confirmationDialog because it breaks the
/// M3E modal hierarchy used by the rest of Luti.
struct MDConfirmDialog: View {
  let title: String
  let message: String
  let confirmTitle: String
  var icon = "exclamationmark.triangle.fill"
  var destructive = true
  let confirm: () -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MDModalSurface {
      MDModalHeader(
        title: title,
        message: message,
        symbol: icon,
        tone: destructive ? .red : .purple)

      MDModalActions {
        Button {
          dismiss()
        } label: {
          Text(L10n.text("common.cancel"))
            .frame(minWidth: 104)
        }
        .buttonStyle(MDConnectedButtonStyle(kind: .tonal, position: .first))
        .keyboardShortcut(.cancelAction)

        Button(role: destructive ? .destructive : nil) {
          dismiss()
          confirm()
        } label: {
          Text(confirmTitle)
            .frame(minWidth: 104)
        }
        .buttonStyle(MDConnectedButtonStyle(kind: .filled, position: .last))
        .keyboardShortcut(.defaultAction)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

/// M3 Expressive indeterminate loading mark. It follows the same seven-family
/// morph cadence as the m3e reference instead of using the macOS spinner.
struct MDLoadingIndicator: View {
  var size: CGFloat = 48
  var contained = false
  var foreground: Color? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date()

  var body: some View {
    ZStack {
      if contained {
        Circle().fill(MDTheme.primaryContainer)
      }

      if reduceMotion {
        MDExpressiveLoadingShape(phase: 0)
          .fill(foreground ?? (contained ? MDTheme.onPrimaryContainer : MDTheme.primary))
      } else {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
          let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
          MDExpressiveLoadingShape(phase: elapsed / 0.65)
            .fill(foreground ?? (contained ? MDTheme.onPrimaryContainer : MDTheme.primary))
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Runtime hero surface: the pale M3 expressive container morphs continuously,
/// while the semantic action/state icon stays stable in the center.
struct MDExpressiveIconSurface: View {
  let symbol: String
  var size: CGFloat = 92

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date()

  var body: some View {
    ZStack {
      if reduceMotion {
        MDExpressiveLoadingShape(phase: 0)
          .fill(MDTheme.primaryContainer)
      } else {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
          let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
          MDExpressiveLoadingShape(phase: elapsed / 0.65)
            .fill(MDTheme.primaryContainer)
        }
      }

      Image(systemName: symbol)
        .font(.system(size: 25, weight: .semibold))
        .foregroundStyle(MDTheme.onPrimaryContainer)
        .accessibilityHidden(true)
    }
    .frame(width: size, height: size)
  }
}

private struct MDExpressiveLoadingShape: Shape {
  var phase: Double

  func path(in rect: CGRect) -> Path {
    let shapeCount = 7
    let whole = Int(floor(phase))
    let from = ((whole % shapeCount) + shapeCount) % shapeCount
    let to = (from + 1) % shapeCount
    let raw = phase - floor(phase)
    let t = 0.5 - 0.5 * cos(.pi * raw)
    let rotation = phase * 140 * .pi / 180
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let scale = min(rect.width, rect.height) * 0.395
    let samples = 96

    var path = Path()
    for index in 0..<samples {
      let angle = Double(index) / Double(samples) * 2 * .pi
      let a = radius(for: from, angle: angle)
      let b = radius(for: to, angle: angle)
      let radius = a + (b - a) * t
      let x = radius * cos(angle)
      let y = radius * sin(angle)
      let rx = x * cos(rotation) - y * sin(rotation)
      let ry = x * sin(rotation) + y * cos(rotation)
      let point = CGPoint(
        x: center.x + CGFloat(rx) * scale,
        y: center.y + CGFloat(ry) * scale
      )
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }

  private func radius(for shape: Int, angle: Double) -> Double {
    switch shape {
    case 0: return 0.80 + 0.16 * cos(8 * angle)
    case 1: return 0.86 + 0.10 * cos(9 * angle)
    case 2: return 0.88 + 0.10 * cos(5 * angle)
    case 3: return ellipseRadius(a: 1.0, b: 0.64, angle: angle - .pi / 4)
    case 4: return 0.76 + 0.20 * cos(12 * angle)
    case 5: return 0.84 + 0.12 * cos(4 * angle)
    default: return ellipseRadius(a: 1.0, b: 0.74, angle: angle)
    }
  }

  private func ellipseRadius(a: Double, b: Double, angle: Double) -> Double {
    let x = b * cos(angle)
    let y = a * sin(angle)
    return (a * b) / sqrt(x * x + y * y)
  }
}

struct MDButtonStyle: ButtonStyle {
  enum Kind { case filled, tonal, text }
  var kind: Kind = .filled
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, kind == .text ? 10 : 18).frame(minHeight: 40)
      .foregroundStyle(foreground(for: configuration.role))
      .background(background(for: configuration.role), in: Capsule())
      .overlay(Capsule().fill(MDTheme.onSurface.opacity(configuration.isPressed ? 0.10 : 0)))
      .opacity(isEnabled ? 1 : 0.38)
      .contentShape(Capsule())
  }
  fileprivate func foreground(for role: ButtonRole?) -> Color {
    if role == .destructive {
      switch kind {
      case .filled: return MDTheme.onError
      case .tonal: return MDTheme.onErrorContainer
      case .text: return MDTheme.error
      }
    }
    return kind == .filled ? MDTheme.onPrimary : MDTheme.primary
  }
  fileprivate func background(for role: ButtonRole?) -> Color {
    switch kind {
    case .filled: role == .destructive ? MDTheme.error : MDTheme.primary
    case .tonal: role == .destructive ? MDTheme.errorContainer : MDTheme.primaryContainer
    case .text: .clear
    }
  }
}

enum MDButtonGroupPosition {
  case single, first, middle, last

  fileprivate var leadingRadius: CGFloat {
    switch self {
    case .single, .first: 22
    case .middle, .last: 8
    }
  }

  fileprivate var trailingRadius: CGFloat {
    switch self {
    case .single, .last: 22
    case .first, .middle: 8
    }
  }
}

struct MDButtonRun<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 3) { content }
  }
}

struct MDConnectedButtonStyle: ButtonStyle {
  var kind: MDButtonStyle.Kind = .tonal
  let position: MDButtonGroupPosition
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: position.leadingRadius,
      bottomLeadingRadius: position.leadingRadius,
      bottomTrailingRadius: position.trailingRadius,
      topTrailingRadius: position.trailingRadius,
      style: .continuous
    )
    let base = MDButtonStyle(kind: kind)

    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, kind == .text ? 10 : 18)
      .frame(minHeight: 44)
      .foregroundStyle(base.foreground(for: configuration.role))
      .background(base.background(for: configuration.role), in: shape)
      .overlay(shape.fill(MDTheme.onSurface.opacity(configuration.isPressed ? 0.10 : 0)))
      .opacity(isEnabled ? 1 : 0.38)
      .contentShape(shape)
  }
}

struct MDInput<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @FocusState private var isFocused: Bool

  var body: some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 14))
      .focused($isFocused)
      .foregroundStyle(MDTheme.onSurface)
      .padding(.horizontal, 16)
      .frame(minHeight: 56)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(MDTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(isFocused ? MDTheme.primary : MDTheme.outline, lineWidth: isFocused ? 2 : 1)
      }
      .overlay(alignment: .topLeading) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isFocused ? MDTheme.primary : MDTheme.onSurfaceVariant)
          .padding(.horizontal, 5)
          .background(MDTheme.surface)
          .offset(x: 12, y: -7)
      }
      .padding(.top, 7)
  }
}

struct MDSearchField: View {
  let prompt: String
  @Binding var text: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(MDTheme.onSurface)
        .accessibilityHidden(true)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($isFocused)
      if !text.isEmpty {
        Button { text = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(MDTheme.onSurfaceVariant)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("ui.clearSearch"))
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 44)
    .background(MDTheme.surfaceContainerHigh, in: Capsule())
    .overlay {
      Capsule().strokeBorder(isFocused ? MDTheme.primary : .clear, lineWidth: 2)
    }
  }
}

struct MDRadioMark: View {
  let isSelected: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(isSelected ? MDTheme.primary : MDTheme.onSurfaceVariant, lineWidth: 2)
        .frame(width: 20, height: 20)

      Circle()
        .fill(MDTheme.primary)
        .frame(width: 10, height: 10)
        .scaleEffect(isSelected ? 1 : 0.001)
        .opacity(isSelected ? 1 : 0)
    }
    .frame(width: 40, height: 40)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
    .accessibilityHidden(true)
  }
}

struct MDSwitch: View {
  @Binding var isOn: Bool
  var label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      if reduceMotion {
        isOn.toggle()
      } else {
        withAnimation(.easeInOut(duration: 0.16)) {
          isOn.toggle()
        }
      }
    } label: {
      ZStack(alignment: .leading) {
        Capsule()
          .fill(isOn ? MDTheme.primary : MDTheme.surfaceContainerHighest)

        Capsule()
          .strokeBorder(isOn ? .clear : MDTheme.outline, lineWidth: 2)

        ZStack {
          Circle()
            .fill(isOn ? MDTheme.onPrimary : MDTheme.outline)

          if isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(MDTheme.onPrimaryContainer)
              .transition(.scale(scale: 0.75).combined(with: .opacity))
          }
        }
        .frame(width: isOn ? 24 : 16, height: isOn ? 24 : 16)
        .offset(x: isOn ? 22 : 4)
      }
      .frame(width: 52, height: 32)
      .contentShape(Capsule())
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isOn)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(isOn ? L10n.text("common.enabled") : L10n.text("common.disabled"))
  }
}

struct InlineNotice: View {
  let text: String
  var icon = "info.circle"
  var color: Color = MDTheme.onSurfaceVariant
  var body: some View {
    Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
      .font(.system(size: 12)).foregroundStyle(color)
  }
}

#Preview("Material 3") {
  MDPage {
    MDSection(title: L10n.text("ui.project")) {
      MDCard {
        MDRow(title: "Luti", symbol: "folder", subtitle: "~/Projects/Luti") {
          Button(L10n.text("ui.change")) {}.buttonStyle(MDButtonStyle(kind: .tonal))
        }
      }
    }
  }.frame(width: 540, height: 500)
}
