import SwiftUI

/// Material 3 / M3 Expressive color roles.
enum MDTheme {
  static let primary = adaptive(0x6750A4, 0xD0BCFF)
  static let onPrimary = adaptive(0xFFFFFF, 0x381E72)
  static let primaryContainer = adaptive(0xEADDFF, 0x4F378B)
  static let onPrimaryContainer = adaptive(0x21005D, 0xEADDFF)
  static let secondaryContainer = adaptive(0xE8DEF8, 0x4A4458)
  static let onSecondaryContainer = adaptive(0x1D192B, 0xE8DEF8)

  // Surface hierarchy aligned with AOSP ColorLightTokens / ColorDarkTokens.
  static let surface = adaptive(0xFEF7FF, 0x141218)
  static let surfaceContainerLowest = adaptive(0xFFFFFF, 0x0F0D13)
  static let surfaceContainerLow = adaptive(0xF7F2FA, 0x1D1B20)
  static let surfaceContainer = adaptive(0xF3EDF7, 0x211F26)
  static let surfaceContainerHigh = adaptive(0xECE6F0, 0x2B2930)
  static let surfaceContainerHighest = adaptive(0xE6E0E9, 0x36343B)
  static let surfaceVariant = adaptive(0xE7E0EC, 0x49454F)

  static let onSurface = adaptive(0x1D1B20, 0xE6E0E9)
  static let onSurfaceVariant = adaptive(0x49454F, 0xCAC4D0)
  static let outline = adaptive(0x79747E, 0x938F99)
  static let outlineVariant = adaptive(0xCAC4D0, 0x49454F)

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

/// AOSP Material 3 shape corner scale.
enum MDShape {
  static let extraSmall: CGFloat = 4
  static let small: CGFloat = 8
  static let medium: CGFloat = 12
  static let large: CGFloat = 16
  static let largeIncreased: CGFloat = 20
  static let extraLarge: CGFloat = 28
}

/// AOSP Material 3 Expressive spring physics (`ExpressiveMotionTokens`).
enum MDMotion {
  static let fastSpatial: Animation = .spring(
    Spring(mass: 1, stiffness: 800, damping: 2 * 0.6 * sqrt(800)))
  static let defaultSpatial: Animation = .spring(
    Spring(mass: 1, stiffness: 380, damping: 2 * 0.8 * sqrt(380)))
  static let slowSpatial: Animation = .spring(
    Spring(mass: 1, stiffness: 200, damping: 2 * 0.8 * sqrt(200)))
  static let fastEffects: Animation = .spring(
    Spring(mass: 1, stiffness: 3800, damping: 2 * 1.0 * sqrt(3800)))
  static let defaultEffects: Animation = .spring(
    Spring(mass: 1, stiffness: 1600, damping: 2 * 1.0 * sqrt(1600)))

  /// Analytical spring displacement matching m3e's `evaluateSpringDisplacement`.
  static func springDisplacement(stiffness: Double, dampingRatio: Double, timeSec: Double) -> Double {
    guard timeSec > 0 else { return 0 }
    let omega0 = sqrt(stiffness)
    if dampingRatio < 1 - 1e-6 {
      let dampFactor = sqrt(1 - dampingRatio * dampingRatio)
      let omegaD = omega0 * dampFactor
      let envelope = exp(-dampingRatio * omega0 * timeSec)
      let cosTerm = cos(omegaD * timeSec)
      let sinTerm = (dampingRatio / dampFactor) * sin(omegaD * timeSec)
      return 1 - envelope * (cosTerm + sinTerm)
    }
    if abs(dampingRatio - 1) <= 1e-6 {
      return 1 - (1 + omega0 * timeSec) * exp(-omega0 * timeSec)
    }
    let root = sqrt(dampingRatio * dampingRatio - 1)
    let r1 = -omega0 * (dampingRatio - root)
    let r2 = -omega0 * (dampingRatio + root)
    return 1 - (r2 * exp(r1 * timeSec) - r1 * exp(r2 * timeSec)) / (r2 - r1)
  }
}

struct MDPage<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    MDScrollView {
      VStack(alignment: .leading, spacing: 20) { content }
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

private struct MDContainerSurfaceKey: EnvironmentKey {
  static let defaultValue: Color = MDTheme.surface
}

extension EnvironmentValues {
  var mdContainerSurface: Color {
    get { self[MDContainerSurfaceKey.self] }
    set { self[MDContainerSurfaceKey.self] = newValue }
  }
}

struct MDCard<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) { content }
      .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(
        MDTheme.surfaceContainerLow,
        in: RoundedRectangle(cornerRadius: MDShape.large, style: .continuous))
      .environment(\.mdContainerSurface, MDTheme.surfaceContainerLow)
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
        .foregroundStyle(MDTheme.onSecondaryContainer)
        .frame(width: 56, height: 56)
        .background(
          MDTheme.secondaryContainer,
          in: MDExpressivePolygonShape(cubics: M3EMorphGeometry.cookie9Sided, scaleFactor: 0.96))
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
      in: RoundedRectangle(cornerRadius: MDShape.large, style: .continuous))
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

/// Segmented M3 Expressive list geometry aligned with AOSP `ListTokens` and `ListItemDefaults`.
private enum MDListMetrics {
  static let gap: CGFloat = 2
  static let outerRadius: CGFloat = MDShape.large
  static let innerRadius: CGFloat = MDShape.extraSmall
  static let hoveredInnerRadius: CGFloat = MDShape.medium
  static let activeRadius: CGFloat = MDShape.large
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

  var shape: UnevenRoundedRectangle { shape() }

  func shape(
    selected: Bool = false,
    isPressed: Bool = false,
    isHovered: Bool = false
  ) -> UnevenRoundedRectangle {
    let top: CGFloat = if selected || isPressed {
      MDListMetrics.activeRadius
    } else if isHovered {
      max(topRadius, MDListMetrics.hoveredInnerRadius)
    } else {
      topRadius
    }
    let bottom: CGFloat = if selected || isPressed {
      MDListMetrics.activeRadius
    } else if isHovered {
      max(bottomRadius, MDListMetrics.hoveredInnerRadius)
    } else {
      bottomRadius
    }
    return UnevenRoundedRectangle(
      topLeadingRadius: top, bottomLeadingRadius: bottom,
      bottomTrailingRadius: bottom, topTrailingRadius: top,
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
  var selected = false
  var isPressed = false
  var isHovered = false

  var body: some View {
    let fill: Color = if selected {
      MDTheme.secondaryContainer
    } else if isPressed {
      MDTheme.surfaceContainerHighest
    } else if isHovered {
      MDTheme.surfaceContainerHigh
    } else {
      MDTheme.surfaceContainerLow
    }
    position.shape(selected: selected, isPressed: isPressed, isHovered: isHovered)
      .fill(fill)
  }
}

struct MDListRow<Trailing: View>: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var position: MDListRowPosition = .single
  var selected = false
  var prominent = false
  var foreground: Color? = nil
  var iconTone: MDIconTone = .purple
  var textLineLimit = 2
  var subtitleTruncationMode: Text.TruncationMode = .middle
  var leadingWidth: CGFloat = 36
  var showSurface = true
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
          .foregroundStyle(foreground ?? (selected ? MDTheme.onSecondaryContainer : MDTheme.onSurface))
          .lineLimit(textLineLimit)
          .truncationMode(.tail)
          .help(title)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(selected ? MDTheme.onSecondaryContainer.opacity(0.82) : MDTheme.onSurfaceVariant)
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
    .background {
      if showSurface {
        MDListRowSurface(position: position, selected: selected)
      }
    }
  }
}

/// Navigation is one full-row action. Never nest a trailing button inside it.
struct MDSplitActionRow<Trailing: View>: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var position: MDListRowPosition = .single
  var selected = false
  var iconTone: MDIconTone = .purple
  var accessory: String? = nil
  var action: (() -> Void)? = nil
  @ViewBuilder let trailing: Trailing
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  @State private var isHovered = false
  @State private var isPressed = false

  var body: some View {
    let rowShape = position.shape(selected: selected, isPressed: isPressed, isHovered: isHovered)
    let stateTint = selected ? MDTheme.onSecondaryContainer : MDTheme.onSurface
    let stateOpacity = selected
      ? (isEnabled ? (isPressed ? 0.10 : isFocused ? 0.10 : isHovered ? 0.08 : 0) : 0)
      : (isEnabled && isFocused && !isPressed && !isHovered ? 0.08 : 0)
    HStack(spacing: 0) {
      leading
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

      Rectangle()
        .fill(selected ? MDTheme.onSecondaryContainer.opacity(0.22) : MDTheme.outlineVariant)
        .frame(width: 1, height: 32)
        .padding(.trailing, 12)
        .accessibilityHidden(true)

      trailing
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 16)
    }
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .background(MDListRowSurface(position: position, selected: selected, isPressed: isPressed, isHovered: isHovered))
    .overlay(
      rowShape.fill(stateTint.opacity(stateOpacity))
        .allowsHitTesting(false))
    .clipShape(rowShape)
    .contentShape(rowShape)
    .onHover { isHovered = $0 && isEnabled }
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
    .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: selected)
    .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: isPressed)
  }

  @ViewBuilder private var leading: some View {
    if let action {
      Button(action: action) { label }
        .buttonStyle(MDSplitLeadingButtonStyle { isPressed = $0 })
        .focusable().focusEffectDisabled().focused($isFocused)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    } else {
      label
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
          .foregroundStyle(selected ? MDTheme.onSecondaryContainer : MDTheme.onSurface)
          .lineLimit(2)
          .truncationMode(.tail)
          .help(title)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(selected ? MDTheme.onSecondaryContainer.opacity(0.82) : MDTheme.onSurfaceVariant)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(subtitle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let accessory {
        Image(systemName: accessory)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(selected ? MDTheme.onSecondaryContainer : MDTheme.onSurfaceVariant)
          .accessibilityHidden(true)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, 12)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .opacity(isEnabled ? 1 : 0.38)
    .contentShape(Rectangle())
  }
}

private struct MDSplitLeadingButtonStyle: ButtonStyle {
  let onPressChanged: (Bool) -> Void
  func makeBody(configuration: Configuration) -> some View {
    MDSplitLeadingButtonBody(configuration: configuration, onPressChanged: onPressChanged)
  }
}

private struct MDSplitLeadingButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let onPressChanged: (Bool) -> Void

  var body: some View {
    configuration.label
      .contentShape(Rectangle())
      .onChange(of: configuration.isPressed) { _, pressed in
        onPressChanged(pressed)
      }
  }
}

struct MDNavigationRow: View {
  let title: String
  let symbol: String
  var subtitle: String? = nil
  var detail: String? = nil
  var position: MDListRowPosition = .single
  var selected = false
  var prominent = false
  var foreground: Color? = nil
  var iconTone: MDIconTone = .purple
  var accessory: String? = "chevron.right"
  let action: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    Button(action: action) {
      MDListRow(title: title, symbol: symbol, subtitle: subtitle, position: position,
                selected: selected, prominent: prominent, foreground: foreground,
                iconTone: iconTone, showSurface: false) {
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
      .contentShape(position.shape(selected: selected))
    }
    .buttonStyle(MDRowButtonStyle(position: position, selected: selected, isFocused: isFocused))
    .focusable().focusEffectDisabled().focused($isFocused)
  }
}

struct MDRowButtonStyle: ButtonStyle {
  let position: MDListRowPosition
  var selected = false
  var isFocused = false
  func makeBody(configuration: Configuration) -> some View {
    MDRowButtonBody(configuration: configuration, position: position, selected: selected, isFocused: isFocused)
  }
}

private struct MDRowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let position: MDListRowPosition
  let selected: Bool
  let isFocused: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    let shape = position.shape(selected: selected, isPressed: configuration.isPressed, isHovered: isHovered)
    let stateTint = selected ? MDTheme.onSecondaryContainer : MDTheme.onSurface
    let stateOpacity = selected
      ? (isEnabled ? (configuration.isPressed ? 0.10 : isFocused ? 0.10 : isHovered ? 0.08 : 0) : 0)
      : (isEnabled && isFocused && !configuration.isPressed && !isHovered ? 0.08 : 0)
    configuration.label
      .background(MDListRowSurface(position: position, selected: selected, isPressed: configuration.isPressed, isHovered: isHovered))
      .overlay(shape.fill(stateTint.opacity(stateOpacity)).allowsHitTesting(false))
      .clipShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
      .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: configuration.isPressed)
      .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: selected)
      .onHover { isHovered = $0 && isEnabled }
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
      .buttonStyle(MDIconActionButtonStyle(destructive: false, neutral: true))
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

/// Accordion-style disclosure matching M3 Expressive expandable containers (`Accordion.tsx`).
struct MDDisclosure<Content: View>: View {
  let title: String
  var symbol = "book.pages"
  var iconTone: MDIconTone = .blue
  @ViewBuilder let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expanded = false
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: MDShape.large, style: .continuous)
    let fill = expanded ? MDTheme.surfaceContainer : MDTheme.surfaceContainerLow

    VStack(alignment: .leading, spacing: 0) {
      Button {
        if reduceMotion {
          expanded.toggle()
        } else {
          withAnimation(MDMotion.fastSpatial) {
            expanded.toggle()
          }
        }
      } label: {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(iconTone.foreground)
            .frame(width: 36, height: 36)
            .background(iconTone.container, in: Circle())
            .accessibilityHidden(true)

          Text(title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(MDTheme.onSurface)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

          Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MDTheme.onSurfaceVariant)
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      }
      .buttonStyle(MDDisclosureTriggerStyle(expanded: expanded))
      .accessibilityValue(expanded ? L10n.text("ui.expanded") : L10n.text("ui.collapsed"))

      VStack(alignment: .leading, spacing: 16) {
        content
      }
      .padding(.horizontal, 18)
      .padding(.top, 4)
      .padding(.bottom, 18)
      .fixedSize(horizontal: false, vertical: true)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: MDDisclosureHeightKey.self, value: proxy.size.height)
        })
      .onPreferenceChange(MDDisclosureHeightKey.self) { contentHeight = $0 }
      .frame(height: expanded ? (contentHeight > 0 ? contentHeight : nil) : 0, alignment: .top)
      .opacity(expanded ? 1 : 0)
      .clipped()
      .disabled(!expanded)
      .allowsHitTesting(expanded)
      .accessibilityHidden(!expanded)
    }
    .environment(\.mdContainerSurface, fill)
    .background(fill, in: shape)
    .overlay {
      if expanded {
        shape.strokeBorder(MDTheme.outlineVariant, lineWidth: 1)
      }
    }
    .clipShape(shape)
    .shadow(color: expanded ? MDTheme.onSurface.opacity(0.08) : .clear, radius: 10, y: 3)
  }
}

private struct MDDisclosureHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct MDDisclosureTriggerStyle: ButtonStyle {
  let expanded: Bool

  func makeBody(configuration: Configuration) -> some View {
    MDDisclosureTriggerBody(configuration: configuration, expanded: expanded)
  }
}

private struct MDDisclosureTriggerBody: View {
  let configuration: ButtonStyleConfiguration
  let expanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    let overlayOpacity: Double = configuration.isPressed
      ? 0.08
      : (isHovered ? (expanded ? 0.04 : 0.06) : 0)
    let hoverShape = UnevenRoundedRectangle(
      topLeadingRadius: MDShape.large,
      bottomLeadingRadius: expanded ? 0 : MDShape.large,
      bottomTrailingRadius: expanded ? 0 : MDShape.large,
      topTrailingRadius: MDShape.large,
      style: .continuous)
    configuration.label
      .background(MDTheme.onSurface.opacity(overlayOpacity), in: hoverShape)
      .contentShape(Rectangle())
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: configuration.isPressed)
      .onHover { isHovered = $0 }
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
  var neutral = false

  func makeBody(configuration: Configuration) -> some View {
    MDIconActionButtonBody(configuration: configuration, destructive: destructive, neutral: neutral)
  }
}

private struct MDIconActionButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let destructive: Bool
  let neutral: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    let radius: CGFloat = configuration.isPressed ? MDShape.small : MDShape.largeIncreased
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    let foreground = destructive ? MDTheme.error : (neutral ? MDTheme.onSurfaceVariant : MDTheme.primary)
    let background = destructive ? MDTheme.errorContainer : MDTheme.surfaceContainerHigh

    configuration.label
      .foregroundStyle(foreground)
      .background(background, in: shape)
      .overlay(
        shape.fill(
          (destructive ? MDTheme.error : MDTheme.primary).opacity(
            isEnabled ? (configuration.isPressed ? 0.10 : hovered ? 0.08 : 0) : 0)))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: hovered)
      .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: configuration.isPressed)
      .onHover { hovered = $0 && isEnabled }
  }
}

private struct MDFloatingActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MDFloatingActionButtonBody(configuration: configuration)
  }
}

private struct MDFloatingActionButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    let radius: CGFloat = configuration.isPressed ? MDShape.medium : MDShape.large
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    configuration.label
      .foregroundStyle(MDTheme.onPrimaryContainer)
      .background(MDTheme.primaryContainer, in: shape)
      .overlay(
        shape.fill(
          MDTheme.onPrimaryContainer.opacity(
            isEnabled ? (configuration.isPressed ? 0.10 : hovered ? 0.08 : 0) : 0)))
      .shadow(color: MDTheme.onSurface.opacity(hovered ? 0.22 : 0.18), radius: hovered ? 10 : 8, y: hovered ? 4 : 3)
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: hovered)
      .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: configuration.isPressed)
      .onHover { hovered = $0 && isEnabled }
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
    .environment(\.mdContainerSurface, MDTheme.surfaceContainerHigh)
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

/// M3 Expressive indeterminate loading mark replicating m3e's seven-shape
/// Bezier morph sequence, underdamped morph spring, quarter-turn step, and
/// continuous 4.666s global rotation.
struct MDLoadingIndicator: View {
  var size: CGFloat = 48
  var contained = false
  var foreground: Color? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date()

  private static let activeScaleFactor = 0.6605

  var body: some View {
    ZStack {
      if contained {
        Circle().fill(MDTheme.primaryContainer)
      }

      if reduceMotion {
        MDExpressiveLoadingShape(elapsedMs: 0, scaleFactor: Self.activeScaleFactor)
          .fill(foreground ?? (contained ? MDTheme.onPrimaryContainer : MDTheme.primary))
      } else {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
          let elapsedMs = max(0, timeline.date.timeIntervalSince(startedAt) * 1000)
          MDExpressiveLoadingShape(elapsedMs: elapsedMs, scaleFactor: Self.activeScaleFactor)
            .fill(foreground ?? (contained ? MDTheme.onPrimaryContainer : MDTheme.primary))
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// Runtime hero surface: the pale M3 expressive container morphs with authentic
/// m3e spring physics while `animating`, keeping the semantic icon steady.
struct MDExpressiveIconSurface: View {
  let symbol: String
  var size: CGFloat = 92
  var animating = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var startedAt = Date()

  private static let heroScaleFactor = 0.8343

  var body: some View {
    ZStack {
      if !animating || reduceMotion {
        MDExpressiveLoadingShape(elapsedMs: 0, scaleFactor: Self.heroScaleFactor)
          .fill(MDTheme.primaryContainer)
      } else {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
          let elapsedMs = max(0, timeline.date.timeIntervalSince(startedAt) * 1000)
          MDExpressiveLoadingShape(elapsedMs: elapsedMs, scaleFactor: Self.heroScaleFactor)
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

/// Renders a normalized static AOSP Material 3 shape (e.g. `cookie9Sided` for empty states).
struct MDExpressivePolygonShape: Shape {
  let cubics: [Double]
  var scaleFactor: Double = 0.96

  func path(in rect: CGRect) -> Path {
    M3EMorphGeometry.path(from: cubics, in: rect, scaleFactor: scaleFactor, rotationDeg: 0)
  }
}

private struct MDExpressiveLoadingShape: Shape {
  var elapsedMs: Double
  var scaleFactor: Double

  private static let intervalMs = 650.0
  private static let globalRotationDurationMs = 4666.0
  private static let quarterRotationDeg = 90.0
  private static let morphStiffness = 200.0
  private static let morphDampingRatio = 0.6

  func path(in rect: CGRect) -> Path {
    let pairs = M3EMorphGeometry.loadingPairs
    let totalSteps = Int(floor(elapsedMs / Self.intervalMs))
    let morphIndex = ((totalSteps % pairs.count) + pairs.count) % pairs.count
    let withinStepSec = elapsedMs.truncatingRemainder(dividingBy: Self.intervalMs) / 1000.0
    let morphProgress = MDMotion.springDisplacement(
      stiffness: Self.morphStiffness,
      dampingRatio: Self.morphDampingRatio,
      timeSec: withinStepSec)
    let stepAngle = Double((totalSteps + 1) * 90)
    let globalAngle = (elapsedMs.truncatingRemainder(dividingBy: Self.globalRotationDurationMs)
      / Self.globalRotationDurationMs) * 360.0
    let rotationDeg = (morphProgress * Self.quarterRotationDeg + stepAngle + globalAngle)
      .truncatingRemainder(dividingBy: 360.0)
    let pair = pairs[morphIndex]
    return M3EMorphGeometry.morphedPath(
      start: pair.start,
      end: pair.end,
      progress: morphProgress,
      in: rect,
      scaleFactor: scaleFactor,
      rotationDeg: rotationDeg)
  }
}

/// Pre-aligned normalized AOSP Material 3 `RoundedPolygon` cubic pairs from m3e.
private enum M3EMorphGeometry {
  static func morphedPath(
    start: [Double],
    end: [Double],
    progress: Double,
    in rect: CGRect,
    scaleFactor: Double,
    rotationDeg: Double
  ) -> Path {
    let count = start.count / 8
    guard count > 0, end.count == start.count else { return Path() }

    let size = Double(min(rect.width, rect.height))
    let scaled = size * scaleFactor
    let cx = Double(rect.midX)
    let cy = Double(rect.midY)
    let rad = rotationDeg * .pi / 180.0
    let cosR = cos(rad)
    let sinR = sin(rad)

    @inline(__always)
    func point(_ idx: Int) -> CGPoint {
      let nx = start[idx] + (end[idx] - start[idx]) * progress - 0.5
      let ny = start[idx + 1] + (end[idx + 1] - start[idx + 1]) * progress - 0.5
      let rx = nx * cosR - ny * sinR
      let ry = nx * sinR + ny * cosR
      return CGPoint(x: cx + rx * scaled, y: cy + ry * scaled)
    }

    var path = Path()
    path.move(to: point(0))
    for i in 0..<count {
      let base = i * 8
      path.addCurve(to: point(base + 6), control1: point(base + 2), control2: point(base + 4))
    }
    path.closeSubpath()
    return path
  }

  static func path(
    from cubics: [Double],
    in rect: CGRect,
    scaleFactor: Double,
    rotationDeg: Double
  ) -> Path {
    morphedPath(start: cubics, end: cubics, progress: 0, in: rect, scaleFactor: scaleFactor, rotationDeg: rotationDeg)
  }

  static let loadingPairs: [(start: [Double], end: [Double])] = [
    (pair0Start, pair0End),
    (pair1Start, pair1End),
    (pair2Start, pair2End),
    (pair3Start, pair3End),
    (pair4Start, pair4End),
    (pair5Start, pair5End),
    (pair6Start, pair6End),
  ]

  // softBurst -> cookie9Sided -> pentagon -> pill -> sunny -> cookie4Sided -> oval
  private static let pair0Start: [Double] = [0.1814,0.2686,0.1885,0.2588,0.1922,0.2465,0.1912,0.2337,0.1912,0.2337,0.1906,0.2251,0.1899,0.2165,0.1893,0.208,0.1893,0.208,0.1876,0.1861,0.1859,0.1642,0.1842,0.1424,0.1842,0.1424,0.1813,0.1033,0.2204,0.0748,0.2567,0.0895,0.2567,0.0895,0.2771,0.0978,0.2975,0.1061,0.3179,0.1144,0.3179,0.1144,0.3259,0.1177,0.334,0.121,0.342,0.1242,0.342,0.1242,0.3658,0.134,0.3932,0.125,0.4067,0.1031,0.4067,0.1031,0.4113,0.0957,0.4158,0.0884,0.4203,0.0811,0.4203,0.0811,0.4318,0.0624,0.4433,0.0437,0.4548,0.0251,0.4548,0.0251,0.465,0.0084,0.4823,0,0.4995,0,0.4995,0,0.5168,0,0.5341,0.0083,0.5444,0.0249,0.5444,0.0249,0.5561,0.0436,0.5677,0.0623,0.5793,0.0811,0.5793,0.0811,0.5839,0.0884,0.5885,0.0958,0.593,0.1031,0.593,0.1031,0.6066,0.125,0.634,0.1339,0.6579,0.1241,0.6579,0.1241,0.6658,0.1208,0.6738,0.1175,0.6817,0.1142,0.6817,0.1142,0.702,0.1059,0.7223,0.0975,0.7426,0.0892,0.7426,0.0892,0.7788,0.0743,0.818,0.1027,0.8152,0.1417,0.8152,0.1417,0.8136,0.1637,0.812,0.1857,0.8104,0.2077,0.8104,0.2077,0.8098,0.2163,0.8092,0.225,0.8085,0.2336,0.8085,0.2336,0.8067,0.2593,0.8237,0.2826,0.8487,0.2886,0.8487,0.2886,0.8571,0.2907,0.8654,0.2927,0.8738,0.2947,0.8738,0.2947,0.8951,0.2999,0.9164,0.305,0.9377,0.3102,0.9377,0.3102,0.9758,0.3194,0.9908,0.3655,0.9656,0.3954,0.9656,0.3954,0.9514,0.4123,0.9372,0.4291,0.9229,0.446,0.9229,0.446,0.9174,0.4526,0.9118,0.4592,0.9062,0.4658,0.9062,0.4658,0.8896,0.4855,0.8896,0.5143,0.9063,0.534,0.9063,0.534,0.9119,0.5405,0.9175,0.5471,0.923,0.5536,0.923,0.5536,0.9373,0.5703,0.9515,0.587,0.9657,0.6037,0.9657,0.6037,0.991,0.6336,0.9762,0.6797,0.9381,0.6891,0.9381,0.6891,0.9167,0.6943,0.8953,0.6996,0.8739,0.7049,0.8739,0.7049,0.8655,0.707,0.8571,0.709,0.8487,0.7111,0.8487,0.7111,0.8237,0.7173,0.8068,0.7406,0.8088,0.7663,0.8088,0.7663,0.8094,0.7749,0.8101,0.7835,0.8107,0.792,0.8107,0.792,0.8124,0.8139,0.8141,0.8358,0.8158,0.8576,0.8158,0.8576,0.8187,0.8967,0.7796,0.9252,0.7433,0.9105,0.7433,0.9105,0.7149,0.8989,0.6865,0.8873,0.658,0.8758,0.658,0.8758,0.6342,0.866,0.6068,0.875,0.5933,0.8969,0.5933,0.8969,0.5772,0.9229,0.5612,0.9489,0.5452,0.9749,0.5452,0.9749,0.5361,0.9897,0.5216,0.9979,0.5064,0.9997,0.5064,0.9997,0.4872,1.0018,0.4671,0.9936,0.4556,0.9751,0.4556,0.9751,0.4394,0.949,0.4232,0.923,0.407,0.8969,0.407,0.8969,0.3934,0.875,0.366,0.8661,0.3421,0.8759,0.3421,0.8759,0.3342,0.8792,0.3262,0.8825,0.3183,0.8858,0.3183,0.8858,0.298,0.8941,0.2777,0.9025,0.2574,0.9108,0.2574,0.9108,0.2212,0.9257,0.182,0.8973,0.1848,0.8583,0.1848,0.8583,0.1864,0.8363,0.188,0.8143,0.1896,0.7923,0.1896,0.7923,0.1902,0.7837,0.1908,0.775,0.1915,0.7664,0.1915,0.7664,0.1933,0.7407,0.1763,0.7174,0.1513,0.7114,0.1513,0.7114,0.1429,0.7093,0.1346,0.7073,0.1262,0.7053,0.1262,0.7053,0.1049,0.7001,0.0836,0.695,0.0623,0.6898,0.0623,0.6898,0.0242,0.6806,0.0092,0.6345,0.0344,0.6046,0.0344,0.6046,0.0486,0.5877,0.0628,0.5709,0.0771,0.554,0.0771,0.554,0.0826,0.5474,0.0882,0.5408,0.0938,0.5342,0.0938,0.5342,0.1104,0.5145,0.1104,0.4857,0.0937,0.466,0.0937,0.466,0.0881,0.4595,0.0825,0.4529,0.077,0.4464,0.077,0.4464,0.0627,0.4297,0.0485,0.413,0.0343,0.3963,0.0343,0.3963,0.009,0.3664,0.0238,0.3203,0.0619,0.3109,0.0619,0.3109,0.0833,0.3057,0.1047,0.3004,0.1261,0.2951,0.1261,0.2951,0.1345,0.293,0.1429,0.291,0.1513,0.2889,0.1513,0.2889,0.1638,0.2858,0.1743,0.2784,0.1814,0.2686]
  private static let pair0End: [Double] = [0.1008,0.28,0.1068,0.2697,0.1116,0.2587,0.1151,0.2472,0.1151,0.2472,0.1175,0.2392,0.1193,0.231,0.1205,0.2227,0.1205,0.2227,0.1235,0.2005,0.131,0.1801,0.142,0.1621,0.142,0.1621,0.1599,0.1327,0.1869,0.11,0.2189,0.0974,0.2189,0.0974,0.2386,0.0897,0.2601,0.0859,0.2824,0.0867,0.2824,0.0867,0.2909,0.0871,0.2994,0.0867,0.3077,0.0857,0.3077,0.0857,0.3315,0.0828,0.3543,0.0744,0.3743,0.0614,0.3743,0.0614,0.3813,0.0568,0.388,0.0517,0.3943,0.046,0.3943,0.046,0.4108,0.031,0.4297,0.0202,0.4497,0.0134,0.4497,0.0134,0.466,0.0079,0.483,0.0052,0.5,0.0052,0.5,0.0052,0.517,0.0052,0.5339,0.0079,0.5502,0.0134,0.5502,0.0134,0.5702,0.0201,0.5892,0.031,0.6057,0.046,0.6057,0.046,0.612,0.0517,0.6187,0.0569,0.6257,0.0614,0.6257,0.0614,0.6458,0.0745,0.6686,0.0828,0.6924,0.0857,0.6924,0.0857,0.7007,0.0867,0.7091,0.087,0.7176,0.0867,0.7176,0.0867,0.7398,0.0859,0.7613,0.0897,0.781,0.0974,0.781,0.0974,0.8129,0.1099,0.84,0.1326,0.858,0.1619,0.858,0.1619,0.869,0.18,0.8765,0.2005,0.8795,0.2227,0.8795,0.2227,0.8807,0.2311,0.8825,0.2393,0.885,0.2473,0.885,0.2473,0.892,0.2702,0.9041,0.2912,0.9204,0.3087,0.9204,0.3087,0.9261,0.3148,0.9324,0.3205,0.939,0.3257,0.939,0.3257,0.9567,0.3394,0.9707,0.3561,0.9808,0.3746,0.9808,0.3746,0.9972,0.4048,1.0034,0.4396,0.9983,0.4736,0.9983,0.4736,0.9951,0.4945,0.9877,0.515,0.9758,0.534,0.9758,0.534,0.9712,0.5411,0.9673,0.5486,0.9641,0.5564,0.9641,0.5564,0.9547,0.5784,0.9505,0.6023,0.9518,0.6262,0.9518,0.6262,0.9522,0.6345,0.9533,0.6429,0.9551,0.6511,0.9551,0.6511,0.9598,0.673,0.9598,0.6948,0.9556,0.7154,0.9556,0.7154,0.9488,0.7491,0.9312,0.7798,0.9054,0.8025,0.9054,0.8025,0.8896,0.8165,0.8707,0.8275,0.8494,0.8343,0.8494,0.8343,0.8413,0.8369,0.8335,0.8401,0.826,0.8439,0.826,0.8439,0.8047,0.8548,0.7861,0.8704,0.7717,0.8895,0.7717,0.8895,0.7667,0.8962,0.7622,0.9033,0.7582,0.9108,0.7582,0.9108,0.7478,0.9305,0.7338,0.9472,0.7173,0.9604,0.7173,0.9604,0.6994,0.9746,0.6786,0.9848,0.6566,0.9902,0.6566,0.9902,0.6471,0.9926,0.6374,0.994,0.6277,0.9946,0.6277,0.9946,0.6198,0.995,0.6118,0.9949,0.6039,0.9941,0.6039,0.9941,0.5941,0.9931,0.5842,0.9912,0.5745,0.9884,0.5745,0.9884,0.5695,0.9869,0.5645,0.9851,0.5595,0.9831,0.5595,0.9831,0.5535,0.9806,0.5473,0.9786,0.5411,0.9769,0.5411,0.9769,0.5315,0.9743,0.5217,0.9726,0.5119,0.9719,0.5119,0.9719,0.496,0.9707,0.4801,0.9719,0.4645,0.9755,0.4645,0.9755,0.4564,0.9774,0.4483,0.9799,0.4405,0.9831,0.4405,0.9831,0.4198,0.9915,0.3984,0.9953,0.3773,0.9948,0.3773,0.9948,0.3429,0.9939,0.3097,0.9818,0.2828,0.9604,0.2828,0.9604,0.2663,0.9473,0.2522,0.9306,0.2418,0.9108,0.2418,0.9108,0.2378,0.9033,0.2333,0.8961,0.2283,0.8894,0.2283,0.8894,0.2138,0.8703,0.1953,0.8547,0.1739,0.8439,0.1739,0.8439,0.1665,0.8401,0.1587,0.8369,0.1506,0.8343,0.1506,0.8343,0.1294,0.8275,0.1105,0.8165,0.0947,0.8026,0.0947,0.8026,0.0689,0.7799,0.0512,0.7492,0.0444,0.7156,0.0444,0.7156,0.0402,0.6949,0.0402,0.673,0.0449,0.6511,0.0449,0.6511,0.0467,0.6428,0.0478,0.6345,0.0482,0.6261,0.0482,0.6261,0.0495,0.6022,0.0453,0.5783,0.0359,0.5563,0.0359,0.5563,0.0326,0.5486,0.0287,0.5411,0.0242,0.534,0.0242,0.534,0.0123,0.5151,0.0049,0.4946,0.0018,0.4737,0.0018,0.4737,-0.0034,0.4398,0.0028,0.4049,0.0192,0.3748,0.0192,0.3748,0.0293,0.3562,0.0433,0.3394,0.061,0.3257,0.061,0.3257,0.0677,0.3205,0.0739,0.3148,0.0796,0.3087,0.0796,0.3087,0.0878,0.2999,0.0949,0.2903,0.1008,0.28]
  private static let pair1Start: [Double] = [0.5,0.0052,0.5379,0.0052,0.5757,0.0188,0.6057,0.046,0.6057,0.046,0.6071,0.0473,0.6085,0.0485,0.6099,0.0497,0.6099,0.0497,0.6399,0.075,0.6782,0.0882,0.7176,0.0867,0.7176,0.0867,0.7985,0.0836,0.8686,0.1424,0.8795,0.2227,0.8795,0.2227,0.8849,0.262,0.9049,0.2977,0.9355,0.3228,0.9355,0.3228,0.9366,0.3238,0.9378,0.3248,0.939,0.3257,0.939,0.3257,1.0031,0.3753,1.0189,0.4654,0.9758,0.534,0.9758,0.534,0.9745,0.5359,0.9734,0.5379,0.9722,0.5399,0.9722,0.5399,0.953,0.5735,0.9469,0.6131,0.9551,0.6511,0.9551,0.6511,0.9722,0.7303,0.9265,0.8095,0.8494,0.8343,0.8494,0.8343,0.8126,0.8461,0.7815,0.871,0.7619,0.9041,0.7619,0.9041,0.7606,0.9063,0.7594,0.9085,0.7582,0.9108,0.7582,0.9108,0.7296,0.9651,0.6732,0.9962,0.615,0.9948,0.615,0.9948,0.5964,0.9943,0.5776,0.9905,0.5595,0.9831,0.5595,0.9831,0.5214,0.9675,0.4786,0.9675,0.4405,0.9831,0.4405,0.9831,0.4224,0.9905,0.4036,0.9943,0.385,0.9948,0.385,0.9948,0.3268,0.9962,0.2704,0.9651,0.2418,0.9108,0.2418,0.9108,0.2406,0.9085,0.2394,0.9063,0.2381,0.9041,0.2381,0.9041,0.2185,0.871,0.1874,0.8461,0.1506,0.8343,0.1506,0.8343,0.0735,0.8095,0.0278,0.7303,0.0449,0.6511,0.0449,0.6511,0.0531,0.6131,0.047,0.5735,0.0278,0.5399,0.0278,0.5399,0.0266,0.5379,0.0255,0.5359,0.0242,0.534,0.0242,0.534,-0.0189,0.4654,-0.0031,0.3753,0.061,0.3257,0.061,0.3257,0.0622,0.3248,0.0634,0.3238,0.0645,0.3228,0.0645,0.3228,0.0951,0.2977,0.1151,0.262,0.1205,0.2227,0.1205,0.2227,0.1314,0.1424,0.2015,0.0836,0.2824,0.0867,0.2824,0.0867,0.3218,0.0882,0.3601,0.075,0.3901,0.0497,0.3901,0.0497,0.3915,0.0485,0.3929,0.0473,0.3943,0.046,0.3943,0.046,0.4243,0.0188,0.4621,0.0052,0.5,0.0052]
  private static let pair1End: [Double] = [0.5,0.0296,0.5332,0.0296,0.5663,0.0392,0.5951,0.0583,0.5951,0.0583,0.5965,0.0592,0.5979,0.0601,0.5992,0.0611,0.5992,0.0611,0.6268,0.0806,0.6544,0.1001,0.6821,0.1196,0.6821,0.1196,0.737,0.1583,0.792,0.1971,0.847,0.2359,0.847,0.2359,0.8748,0.2556,0.9027,0.2752,0.9305,0.2949,0.9305,0.2949,0.9316,0.2957,0.9327,0.2965,0.9338,0.2973,0.9338,0.2973,0.989,0.3383,1.0127,0.4093,0.9933,0.4752,0.9933,0.4752,0.9928,0.4771,0.9922,0.479,0.9915,0.4809,0.9915,0.4809,0.9812,0.512,0.9708,0.5431,0.9604,0.5743,0.9604,0.5743,0.9395,0.6369,0.9185,0.6995,0.8976,0.7621,0.8976,0.7621,0.8873,0.793,0.877,0.824,0.8667,0.8549,0.8667,0.8549,0.866,0.857,0.8652,0.8591,0.8644,0.8612,0.8644,0.8612,0.8397,0.9267,0.7768,0.9704,0.7063,0.9704,0.7063,0.9704,0.6734,0.9704,0.6405,0.9704,0.6075,0.9704,0.6075,0.9704,0.5358,0.9704,0.4642,0.9704,0.3925,0.9704,0.3925,0.9704,0.3595,0.9704,0.3266,0.9704,0.2937,0.9704,0.2937,0.9704,0.2232,0.9704,0.1603,0.9267,0.1356,0.8612,0.1356,0.8612,0.1348,0.8591,0.134,0.857,0.1333,0.8549,0.1333,0.8549,0.123,0.824,0.1127,0.793,0.1024,0.7621,0.1024,0.7621,0.0815,0.6995,0.0605,0.6369,0.0396,0.5743,0.0396,0.5743,0.0292,0.5431,0.0188,0.512,0.0085,0.4809,0.0085,0.4809,0.0078,0.479,0.0072,0.4771,0.0067,0.4752,0.0067,0.4752,-0.0127,0.4093,0.011,0.3383,0.0662,0.2973,0.0662,0.2973,0.0673,0.2965,0.0684,0.2957,0.0695,0.2949,0.0695,0.2949,0.0973,0.2752,0.1252,0.2556,0.153,0.2359,0.153,0.2359,0.208,0.1971,0.263,0.1583,0.3179,0.1196,0.3179,0.1196,0.3456,0.1001,0.3732,0.0806,0.4008,0.0611,0.4008,0.0611,0.4021,0.0601,0.4035,0.0592,0.4049,0.0583,0.4049,0.0583,0.4337,0.0392,0.4668,0.0296,0.5,0.0296]
  private static let pair2Start: [Double] = [0.5,0.0296,0.5347,0.0296,0.5695,0.0401,0.5992,0.0611,0.5992,0.0611,0.6046,0.0649,0.61,0.0687,0.6154,0.0725,0.6154,0.0725,0.6243,0.0788,0.6331,0.085,0.642,0.0913,0.642,0.0913,0.6999,0.1322,0.7579,0.173,0.8158,0.2139,0.8158,0.2139,0.854,0.2409,0.8923,0.2679,0.9305,0.2949,0.9305,0.2949,0.9509,0.3093,0.9672,0.3277,0.9789,0.3485,0.9789,0.3485,0.9842,0.3578,0.9885,0.3676,0.9918,0.3778,0.9918,0.3778,1.0025,0.4105,1.003,0.4465,0.9915,0.4809,0.9915,0.4809,0.9716,0.5407,0.9516,0.6005,0.9316,0.6604,0.9316,0.6604,0.9143,0.7121,0.8971,0.7638,0.8798,0.8155,0.8798,0.8155,0.8754,0.8286,0.8711,0.8417,0.8667,0.8549,0.8667,0.8549,0.8436,0.9239,0.7791,0.9704,0.7063,0.9704,0.7063,0.9704,0.6711,0.9704,0.6359,0.9704,0.6006,0.9704,0.6006,0.9704,0.5824,0.9704,0.5641,0.9704,0.5459,0.9704,0.5459,0.9704,0.4618,0.9704,0.3778,0.9704,0.2937,0.9704,0.2937,0.9704,0.2209,0.9704,0.1564,0.9239,0.1333,0.8549,0.1333,0.8549,0.1079,0.7786,0.0824,0.7023,0.0569,0.626,0.0569,0.626,0.0513,0.6092,0.0457,0.5924,0.0401,0.5757,0.0401,0.5757,0.0296,0.5441,0.019,0.5125,0.0085,0.4809,0.0085,0.4809,-0.0145,0.4122,0.0103,0.3366,0.0695,0.2949,0.0695,0.2949,0.0948,0.277,0.1202,0.2591,0.1456,0.2412,0.1456,0.2412,0.2055,0.1989,0.2655,0.1566,0.3254,0.1143,0.3254,0.1143,0.3506,0.0965,0.3757,0.0788,0.4008,0.0611,0.4008,0.0611,0.4305,0.0401,0.4653,0.0296,0.5,0.0296]
  private static let pair2End: [Double] = [0.405,0.0339,0.4491,0.0155,0.4962,0.0043,0.5445,0.001,0.5445,0.001,0.5536,0.0004,0.5627,0.0001,0.5719,0,0.5719,0,0.5866,0.0015,0.6013,0.003,0.616,0.0045,0.616,0.0045,0.7162,0.0148,0.8059,0.0596,0.8732,0.1268,0.8732,0.1268,0.9175,0.1712,0.9521,0.2254,0.9735,0.2859,0.9735,0.2859,0.9845,0.3171,0.992,0.3499,0.9955,0.384,0.9955,0.384,0.997,0.3987,0.9985,0.4134,1,0.4281,1,0.4281,0.9998,0.4694,0.9937,0.51,0.9824,0.549,0.9824,0.549,0.9619,0.6192,0.9239,0.6839,0.8713,0.7365,0.8713,0.7365,0.8264,0.7814,0.7814,0.8264,0.7365,0.8713,0.7365,0.8713,0.725,0.8828,0.7128,0.8937,0.7002,0.9038,0.7002,0.9038,0.6457,0.9473,0.5817,0.9772,0.5137,0.9911,0.5137,0.9911,0.4857,0.9968,0.4571,0.9998,0.4281,1,0.4281,1,0.4134,0.9985,0.3987,0.997,0.384,0.9955,0.384,0.9955,0.3133,0.9882,0.2479,0.9638,0.1919,0.9265,0.1919,0.9265,0.1443,0.8948,0.1035,0.8537,0.0721,0.8059,0.0721,0.8059,0.0356,0.7504,0.0117,0.6857,0.0045,0.616,0.0045,0.616,0.003,0.6013,0.0015,0.5866,0,0.5719,0,0.5719,0.0002,0.5436,0.003,0.5157,0.0085,0.4884,0.0085,0.4884,0.0201,0.4301,0.0434,0.3747,0.077,0.3257,0.077,0.3257,0.0922,0.3036,0.1095,0.2827,0.1287,0.2635,0.1287,0.2635,0.1736,0.2186,0.2186,0.1736,0.2635,0.1287,0.2635,0.1287,0.2825,0.1097,0.3032,0.0925,0.3251,0.0775,0.3251,0.0775,0.3502,0.0602,0.377,0.0456,0.405,0.0339]
  private static let pair3Start: [Double] = [0.8732,0.1268,0.884,0.1377,0.8942,0.1491,0.9039,0.161,0.9039,0.161,0.9244,0.1865,0.942,0.2145,0.9563,0.2443,0.9563,0.2443,0.9622,0.2568,0.9676,0.2695,0.9723,0.2826,0.9723,0.2826,0.9837,0.314,0.9915,0.3471,0.9952,0.3815,0.9952,0.3815,0.9953,0.3823,0.9954,0.3831,0.9955,0.384,0.9955,0.384,0.997,0.3987,0.9985,0.4134,1,0.4281,1,0.4281,1,0.4362,0.9997,0.4443,0.9992,0.4523,0.9992,0.4523,0.9982,0.4695,0.9961,0.4865,0.9931,0.5032,0.9931,0.5032,0.9919,0.5102,0.9905,0.5171,0.9889,0.524,0.9889,0.524,0.9851,0.5406,0.9803,0.5569,0.9747,0.5728,0.9747,0.5728,0.9611,0.6111,0.9422,0.6474,0.9186,0.6806,0.9186,0.6806,0.9045,0.7004,0.8887,0.7191,0.8713,0.7365,0.8713,0.7365,0.8389,0.7689,0.8066,0.8012,0.7742,0.8336,0.7742,0.8336,0.7616,0.8461,0.7491,0.8587,0.7365,0.8713,0.7365,0.8713,0.7284,0.8794,0.7199,0.8872,0.7113,0.8946,0.7113,0.8946,0.6577,0.9404,0.5941,0.9724,0.5261,0.9884,0.5261,0.9884,0.4942,0.9959,0.4614,0.9998,0.4281,1,0.4281,1,0.4134,0.9985,0.3987,0.997,0.384,0.9955,0.384,0.9955,0.3832,0.9954,0.3823,0.9953,0.3815,0.9952,0.3815,0.9952,0.3471,0.9915,0.314,0.9837,0.2826,0.9723,0.2826,0.9723,0.2695,0.9676,0.2568,0.9622,0.2443,0.9563,0.2443,0.9563,0.2145,0.942,0.1865,0.9244,0.161,0.9039,0.161,0.9039,0.1371,0.8846,0.1154,0.8629,0.0961,0.839,0.0961,0.839,0.0756,0.8135,0.058,0.7855,0.0437,0.7557,0.0437,0.7557,0.0378,0.7432,0.0324,0.7305,0.0277,0.7174,0.0277,0.7174,0.0163,0.686,0.0085,0.6529,0.0048,0.6185,0.0048,0.6185,0.0047,0.6177,0.0046,0.6168,0.0045,0.616,0.0045,0.616,0.003,0.6013,0.0015,0.5866,0,0.5719,0,0.5719,0.0002,0.5386,0.0041,0.5058,0.0116,0.4739,0.0116,0.4739,0.0276,0.4059,0.0596,0.3423,0.1054,0.2887,0.1054,0.2887,0.1128,0.2801,0.1206,0.2716,0.1287,0.2635,0.1287,0.2635,0.1413,0.2509,0.1539,0.2384,0.1664,0.2258,0.1664,0.2258,0.1988,0.1934,0.2311,0.1611,0.2635,0.1287,0.2635,0.1287,0.2809,0.1113,0.2996,0.0955,0.3194,0.0814,0.3194,0.0814,0.3526,0.0578,0.3889,0.0389,0.4272,0.0253,0.4272,0.0253,0.4431,0.0197,0.4594,0.0149,0.476,0.0111,0.476,0.0111,0.4829,0.0095,0.4898,0.0081,0.4968,0.0069,0.4968,0.0069,0.5135,0.0039,0.5305,0.0018,0.5477,0.0008,0.5477,0.0008,0.5557,0.0003,0.5638,0,0.5719,0,0.5719,0,0.5866,0.0015,0.6013,0.003,0.616,0.0045,0.616,0.0045,0.6168,0.0046,0.6177,0.0047,0.6185,0.0048,0.6185,0.0048,0.6529,0.0085,0.686,0.0163,0.7174,0.0277,0.7174,0.0277,0.7305,0.0324,0.7432,0.0378,0.7557,0.0437,0.7557,0.0437,0.7855,0.058,0.8135,0.0756,0.839,0.0961,0.839,0.0961,0.8509,0.1058,0.8623,0.116,0.8732,0.1268]
  private static let pair3End: [Double] = [0.8536,0.1464,0.8664,0.1593,0.8748,0.1766,0.8764,0.1958,0.8764,0.1958,0.8795,0.2352,0.8826,0.2746,0.8858,0.314,0.8858,0.314,0.8871,0.3305,0.8936,0.3461,0.9043,0.3588,0.9043,0.3588,0.93,0.3888,0.9556,0.4189,0.9812,0.449,0.9812,0.449,0.9818,0.4497,0.9825,0.4505,0.9831,0.4512,0.9831,0.4512,0.9944,0.4655,1,0.4828,1,0.5,1,0.5,1,0.5182,0.9937,0.5363,0.9812,0.551,0.9812,0.551,0.9556,0.5811,0.93,0.6112,0.9043,0.6412,0.9043,0.6412,0.8936,0.6539,0.8871,0.6695,0.8858,0.686,0.8858,0.686,0.8826,0.7254,0.8795,0.7648,0.8764,0.8042,0.8764,0.8042,0.8733,0.8427,0.8427,0.8733,0.8042,0.8764,0.8042,0.8764,0.7905,0.8774,0.7768,0.8785,0.7632,0.8796,0.7632,0.8796,0.7375,0.8817,0.7118,0.8837,0.686,0.8858,0.686,0.8858,0.676,0.8866,0.6662,0.8893,0.6573,0.8938,0.6573,0.8938,0.6515,0.8966,0.6462,0.9001,0.6412,0.9043,0.6412,0.9043,0.6112,0.93,0.5811,0.9556,0.551,0.9812,0.551,0.9812,0.5363,0.9937,0.5182,1,0.5,1,0.5,1,0.4828,1,0.4655,0.9944,0.4512,0.9831,0.4512,0.9831,0.4505,0.9825,0.4497,0.9818,0.449,0.9812,0.449,0.9812,0.4189,0.9556,0.3888,0.93,0.3588,0.9043,0.3588,0.9043,0.3461,0.8936,0.3305,0.8871,0.314,0.8858,0.314,0.8858,0.2746,0.8826,0.2352,0.8795,0.1958,0.8764,0.1958,0.8764,0.1573,0.8733,0.1267,0.8427,0.1236,0.8042,0.1236,0.8042,0.1205,0.7648,0.1174,0.7254,0.1142,0.686,0.1142,0.686,0.1129,0.6695,0.1064,0.6539,0.0957,0.6412,0.0957,0.6412,0.07,0.6112,0.0444,0.5811,0.0188,0.551,0.0188,0.551,0.0182,0.5503,0.0175,0.5495,0.0169,0.5488,0.0169,0.5488,0.0056,0.5345,0,0.5172,0,0.5,0,0.5,0,0.4818,0.0063,0.4637,0.0188,0.449,0.0188,0.449,0.0444,0.4189,0.07,0.3888,0.0957,0.3588,0.0957,0.3588,0.0999,0.3538,0.1034,0.3485,0.1062,0.3427,0.1062,0.3427,0.1107,0.3338,0.1134,0.324,0.1142,0.314,0.1142,0.314,0.1163,0.2882,0.1183,0.2625,0.1204,0.2368,0.1204,0.2368,0.1215,0.2232,0.1226,0.2095,0.1236,0.1958,0.1236,0.1958,0.1267,0.1573,0.1573,0.1267,0.1958,0.1236,0.1958,0.1236,0.2352,0.1205,0.2746,0.1174,0.314,0.1142,0.314,0.1142,0.3305,0.1129,0.3461,0.1064,0.3588,0.0957,0.3588,0.0957,0.3888,0.07,0.4189,0.0444,0.449,0.0188,0.449,0.0188,0.4637,0.0063,0.4818,0,0.5,0,0.5,0,0.5172,0,0.5345,0.0056,0.5488,0.0169,0.5488,0.0169,0.5495,0.0175,0.5503,0.0182,0.551,0.0188,0.551,0.0188,0.5811,0.0444,0.6112,0.07,0.6412,0.0957,0.6412,0.0957,0.6539,0.1064,0.6695,0.1129,0.686,0.1142,0.686,0.1142,0.7254,0.1174,0.7648,0.1205,0.8042,0.1236,0.8042,0.1236,0.8234,0.1252,0.8407,0.1336,0.8536,0.1464]
  private static let pair4Start: [Double] = [1,0.5,1,0.5182,0.9937,0.5363,0.9812,0.551,0.9812,0.551,0.9556,0.5811,0.93,0.6112,0.9043,0.6412,0.9043,0.6412,0.8936,0.6539,0.8871,0.6695,0.8858,0.686,0.8858,0.686,0.8826,0.7254,0.8795,0.7648,0.8764,0.8042,0.8764,0.8042,0.8748,0.8234,0.8664,0.8407,0.8536,0.8536,0.8536,0.8536,0.8407,0.8664,0.8234,0.8748,0.8042,0.8764,0.8042,0.8764,0.7778,0.8785,0.7514,0.8806,0.7251,0.8827,0.7251,0.8827,0.7177,0.8833,0.7103,0.8838,0.7029,0.8844,0.7029,0.8844,0.6973,0.8849,0.6917,0.8853,0.686,0.8858,0.686,0.8858,0.6695,0.8871,0.6539,0.8936,0.6412,0.9043,0.6412,0.9043,0.6158,0.926,0.5903,0.9477,0.5649,0.9694,0.5649,0.9694,0.5603,0.9733,0.5557,0.9773,0.551,0.9812,0.551,0.9812,0.5384,0.992,0.5231,0.9981,0.5075,0.9996,0.5075,0.9996,0.4869,1.0016,0.4657,0.9955,0.449,0.9812,0.449,0.9812,0.4189,0.9556,0.3888,0.93,0.3588,0.9043,0.3588,0.9043,0.3461,0.8936,0.3305,0.8871,0.314,0.8858,0.314,0.8858,0.2746,0.8826,0.2352,0.8795,0.1958,0.8764,0.1958,0.8764,0.1573,0.8733,0.1267,0.8427,0.1236,0.8042,0.1236,0.8042,0.1215,0.7778,0.1194,0.7514,0.1173,0.7251,0.1173,0.7251,0.1167,0.7177,0.1162,0.7103,0.1156,0.703,0.1156,0.703,0.1151,0.6973,0.1147,0.6917,0.1142,0.686,0.1142,0.686,0.1129,0.6695,0.1064,0.6539,0.0957,0.6412,0.0957,0.6412,0.074,0.6158,0.0523,0.5903,0.0306,0.5649,0.0306,0.5649,0.0267,0.5603,0.0227,0.5557,0.0188,0.551,0.0188,0.551,0.008,0.5384,0.0019,0.5231,0.0004,0.5075,0.0004,0.5075,-0.0016,0.4869,0.0045,0.4657,0.0188,0.449,0.0188,0.449,0.0444,0.4189,0.07,0.3888,0.0957,0.3588,0.0957,0.3588,0.1064,0.3461,0.1129,0.3305,0.1142,0.314,0.1142,0.314,0.1174,0.2746,0.1205,0.2352,0.1236,0.1958,0.1236,0.1958,0.1267,0.1573,0.1573,0.1267,0.1958,0.1236,0.1958,0.1236,0.2222,0.1215,0.2486,0.1194,0.2749,0.1173,0.2749,0.1173,0.2823,0.1167,0.2897,0.1162,0.297,0.1156,0.297,0.1156,0.3027,0.1151,0.3083,0.1147,0.314,0.1142,0.314,0.1142,0.3305,0.1129,0.3461,0.1064,0.3588,0.0957,0.3588,0.0957,0.3842,0.074,0.4097,0.0523,0.4351,0.0306,0.4351,0.0306,0.4397,0.0267,0.4443,0.0227,0.449,0.0188,0.449,0.0188,0.4616,0.008,0.4769,0.0019,0.4925,0.0004,0.4925,0.0004,0.5131,-0.0016,0.5343,0.0045,0.551,0.0188,0.551,0.0188,0.5811,0.0444,0.6112,0.07,0.6412,0.0957,0.6412,0.0957,0.6539,0.1064,0.6695,0.1129,0.686,0.1142,0.686,0.1142,0.7254,0.1174,0.7648,0.1205,0.8042,0.1236,0.8042,0.1236,0.8427,0.1267,0.8733,0.1573,0.8764,0.1958,0.8764,0.1958,0.8785,0.2222,0.8806,0.2486,0.8827,0.2749,0.8827,0.2749,0.8833,0.2823,0.8838,0.2897,0.8844,0.297,0.8844,0.297,0.8849,0.3027,0.8853,0.3083,0.8858,0.314,0.8858,0.314,0.8871,0.3305,0.8936,0.3461,0.9043,0.3588,0.9043,0.3588,0.926,0.3842,0.9477,0.4096,0.9694,0.4351,0.9694,0.4351,0.9733,0.4397,0.9773,0.4443,0.9812,0.449,0.9812,0.449,0.992,0.4616,0.9981,0.4768,0.9996,0.4924,0.9996,0.4924,0.9999,0.4949,1,0.4975,1,0.5]
  private static let pair4End: [Double] = [0.981,0.6448,0.9869,0.6595,0.9914,0.6742,0.9946,0.6889,0.9946,0.6889,1.0014,0.72,1.0021,0.7507,0.9976,0.78,0.9976,0.78,0.9958,0.7922,0.993,0.8041,0.9894,0.8157,0.9894,0.8157,0.9809,0.8437,0.9676,0.8697,0.9505,0.893,0.9505,0.893,0.9425,0.9039,0.9337,0.9141,0.9242,0.9237,0.9242,0.9237,0.8955,0.9524,0.8604,0.9746,0.8214,0.9875,0.8214,0.9875,0.7658,1.006,0.7024,1.0056,0.6392,0.9783,0.6392,0.9783,0.6237,0.9716,0.6081,0.9649,0.5926,0.9582,0.5926,0.9582,0.5805,0.953,0.5682,0.9489,0.5556,0.9458,0.5556,0.9458,0.5313,0.9399,0.5062,0.9379,0.4814,0.9399,0.4814,0.9399,0.4562,0.9419,0.4312,0.9481,0.4075,0.9584,0.4075,0.9584,0.4033,0.9602,0.399,0.962,0.3948,0.9639,0.3948,0.9639,0.3837,0.9687,0.3725,0.9735,0.3614,0.9784,0.3614,0.9784,0.3446,0.9856,0.3279,0.991,0.3112,0.9946,0.3112,0.9946,0.28,1.0014,0.2493,1.0021,0.22,0.9976,0.22,0.9976,0.2078,0.9958,0.1959,0.993,0.1843,0.9895,0.1843,0.9895,0.1564,0.9809,0.1303,0.9676,0.107,0.9505,0.107,0.9505,0.0634,0.9185,0.0297,0.8733,0.0125,0.8214,0.0125,0.8214,-0.006,0.7657,-0.0056,0.7024,0.0217,0.6392,0.0217,0.6392,0.0284,0.6237,0.0351,0.6081,0.0418,0.5926,0.0418,0.5926,0.047,0.5805,0.0511,0.5682,0.0542,0.5556,0.0542,0.5556,0.0601,0.5313,0.0621,0.5062,0.0601,0.4814,0.0601,0.4814,0.0581,0.4562,0.0519,0.4312,0.0416,0.4075,0.0416,0.4075,0.0398,0.4033,0.038,0.399,0.0361,0.3948,0.0361,0.3948,0.0313,0.3837,0.0265,0.3725,0.0216,0.3614,0.0216,0.3614,0.0144,0.3446,0.009,0.3279,0.0054,0.3112,0.0054,0.3112,-0.0014,0.28,-0.0021,0.2493,0.0024,0.22,0.0024,0.22,0.0042,0.2078,0.007,0.1959,0.0105,0.1843,0.0105,0.1843,0.0191,0.1564,0.0324,0.1303,0.0495,0.107,0.0495,0.107,0.0815,0.0634,0.1267,0.0297,0.1786,0.0125,0.1786,0.0125,0.2343,-0.006,0.2976,-0.0056,0.3608,0.0217,0.3608,0.0217,0.3763,0.0284,0.3919,0.0351,0.4074,0.0418,0.4074,0.0418,0.4195,0.047,0.4318,0.0511,0.4444,0.0542,0.4444,0.0542,0.4687,0.0601,0.4938,0.0621,0.5186,0.0601,0.5186,0.0601,0.5438,0.0581,0.5688,0.0519,0.5925,0.0416,0.5925,0.0416,0.5967,0.0398,0.601,0.038,0.6052,0.0361,0.6052,0.0361,0.6163,0.0313,0.6275,0.0265,0.6386,0.0216,0.6386,0.0216,0.6554,0.0144,0.6721,0.009,0.6888,0.0054,0.6888,0.0054,0.72,-0.0014,0.7507,-0.0021,0.78,0.0024,0.78,0.0024,0.7922,0.0042,0.8041,0.007,0.8157,0.0105,0.8157,0.0105,0.8436,0.0191,0.8697,0.0324,0.893,0.0495,0.893,0.0495,0.9366,0.0815,0.9703,0.1267,0.9875,0.1786,0.9875,0.1786,1.006,0.2343,1.0056,0.2976,0.9783,0.3608,0.9783,0.3608,0.9716,0.3763,0.9649,0.3919,0.9582,0.4074,0.9582,0.4074,0.953,0.4195,0.9489,0.4318,0.9458,0.4444,0.9458,0.4444,0.9399,0.4687,0.9379,0.4938,0.9399,0.5186,0.9399,0.5186,0.9419,0.5438,0.9481,0.5688,0.9584,0.5925,0.9584,0.5925,0.9602,0.5968,0.9621,0.601,0.9639,0.6052,0.9639,0.6052,0.9687,0.6164,0.9735,0.6275,0.9784,0.6386,0.9784,0.6386,0.9793,0.6407,0.9801,0.6428,0.981,0.6448]
  private static let pair5Start: [Double] = [0.9242,0.9237,0.8856,0.9623,0.8352,0.9892,0.7797,0.9975,0.7797,0.9975,0.735,1.0042,0.687,0.999,0.6392,0.9783,0.6392,0.9783,0.6237,0.9716,0.6081,0.9649,0.5926,0.9582,0.5926,0.9582,0.5448,0.9376,0.4919,0.9337,0.4422,0.9465,0.4422,0.9465,0.4304,0.9495,0.4188,0.9535,0.4075,0.9584,0.4075,0.9584,0.3921,0.965,0.3767,0.9717,0.3614,0.9784,0.3614,0.9784,0.2945,1.0073,0.2274,1.0062,0.1694,0.9844,0.1694,0.9844,0.078,0.95,0.0094,0.8643,0.0007,0.7644,0.0007,0.7644,-0.0028,0.7242,0.0034,0.6816,0.0217,0.6392,0.0217,0.6392,0.0284,0.6237,0.0351,0.6081,0.0418,0.5926,0.0418,0.5926,0.0673,0.5335,0.0672,0.4665,0.0416,0.4075,0.0416,0.4075,0.035,0.3921,0.0283,0.3767,0.0216,0.3614,0.0216,0.3614,0.0165,0.3496,0.0123,0.3377,0.009,0.3259,0.009,0.3259,-0.0341,0.1714,0.0757,0.0242,0.2204,0.0025,0.2204,0.0025,0.265,-0.0042,0.313,0.001,0.3608,0.0217,0.3608,0.0217,0.3763,0.0284,0.3919,0.0351,0.4074,0.0418,0.4074,0.0418,0.4552,0.0624,0.5082,0.0663,0.5579,0.0535,0.5579,0.0535,0.5697,0.0505,0.5812,0.0465,0.5925,0.0416,0.5925,0.0416,0.6079,0.035,0.6233,0.0283,0.6386,0.0216,0.6386,0.0216,0.7055,-0.0073,0.7726,-0.0062,0.8306,0.0156,0.8306,0.0156,0.8657,0.0288,0.8974,0.0496,0.9237,0.0758,0.9237,0.0758,0.9659,0.1179,0.994,0.1741,0.9993,0.2357,0.9993,0.2357,1.0028,0.2759,0.9966,0.3184,0.9783,0.3608,0.9783,0.3608,0.9716,0.3763,0.9649,0.3919,0.9582,0.4074,0.9582,0.4074,0.9327,0.4665,0.9328,0.5335,0.9584,0.5925,0.9584,0.5925,0.965,0.6079,0.9717,0.6233,0.9784,0.6386,0.9784,0.6386,0.9835,0.6505,0.9877,0.6624,0.991,0.6742,0.991,0.6742,1.0175,0.7694,0.9861,0.8617,0.9242,0.9237]
  private static let pair5End: [Double] = [0.8865,0.6262,0.8535,0.6767,0.8141,0.7251,0.7696,0.7696,0.7696,0.7696,0.7338,0.8053,0.6955,0.8378,0.6557,0.8664,0.6557,0.8664,0.641,0.8769,0.626,0.8869,0.6109,0.8963,0.6109,0.8963,0.5652,0.925,0.5179,0.9484,0.4705,0.9657,0.4705,0.9657,0.4567,0.9707,0.443,0.9752,0.4294,0.9791,0.4294,0.9791,0.4107,0.9845,0.3922,0.9889,0.3739,0.9922,0.3739,0.9922,0.3043,1.0049,0.239,1.0023,0.1827,0.9839,0.1827,0.9839,0.1011,0.9572,0.0428,0.8989,0.0161,0.8173,0.0161,0.8173,0.0088,0.795,0.004,0.7714,0.0016,0.7466,0.0016,0.7466,0.0007,0.7363,0.0001,0.7257,-0.0001,0.715,-0.0001,0.715,-0.0006,0.6749,0.0048,0.6324,0.016,0.5885,0.016,0.5885,0.019,0.5769,0.0223,0.5652,0.0261,0.5534,0.0261,0.5534,0.0287,0.5455,0.0314,0.5375,0.0343,0.5295,0.0343,0.5295,0.0728,0.4241,0.1415,0.3194,0.2304,0.2304,0.2304,0.2304,0.2661,0.1947,0.3044,0.1623,0.3442,0.1337,0.3442,0.1337,0.3589,0.1232,0.3739,0.1132,0.389,0.1037,0.389,0.1037,0.4347,0.0751,0.482,0.0517,0.5295,0.0343,0.5295,0.0343,0.5432,0.0293,0.5569,0.0248,0.5705,0.0209,0.5705,0.0209,0.5892,0.0155,0.6077,0.0111,0.626,0.0078,0.626,0.0078,0.6957,-0.005,0.761,-0.0023,0.8173,0.0161,0.8173,0.0161,0.8581,0.0294,0.8931,0.0507,0.9212,0.0788,0.9212,0.0788,0.9493,0.1069,0.9706,0.1419,0.9839,0.1827,0.9839,0.1827,0.9912,0.2049,0.996,0.2286,0.9983,0.2534,0.9983,0.2534,0.9993,0.2637,0.9999,0.2742,1.0001,0.2849,1.0001,0.2849,1.0006,0.325,0.9952,0.3675,0.984,0.4114,0.984,0.4114,0.9811,0.423,0.9777,0.4347,0.9739,0.4465,0.9739,0.4465,0.9714,0.4544,0.9686,0.4625,0.9657,0.4705,0.9657,0.4705,0.9464,0.5232,0.9196,0.5758,0.8865,0.6262]
  private static let pair6Start: [Double] = [0.9212,0.0788,0.9303,0.0879,0.9387,0.0977,0.9463,0.1081,0.9463,0.1081,0.9593,0.1261,0.9702,0.1462,0.9787,0.168,0.9787,0.168,0.9805,0.1728,0.9823,0.1777,0.9839,0.1827,0.9839,0.1827,0.9875,0.1937,0.9905,0.2051,0.9929,0.2168,0.9929,0.2168,0.997,0.2367,0.9993,0.2576,0.9999,0.2791,0.9999,0.2791,1.0007,0.3071,0.9986,0.3362,0.9936,0.3662,0.9936,0.3662,0.9889,0.3945,0.9816,0.4236,0.9718,0.453,0.9718,0.453,0.9698,0.4588,0.9678,0.4647,0.9657,0.4705,0.9657,0.4705,0.9603,0.4852,0.9544,0.4998,0.9479,0.5144,0.9479,0.5144,0.9373,0.5383,0.9251,0.562,0.9116,0.5855,0.9116,0.5855,0.895,0.6143,0.8763,0.6426,0.8558,0.6701,0.8558,0.6701,0.8373,0.6949,0.8172,0.719,0.7958,0.7422,0.7958,0.7422,0.7873,0.7515,0.7785,0.7606,0.7696,0.7696,0.7696,0.7696,0.7605,0.7787,0.7512,0.7875,0.7418,0.7962,0.7418,0.7962,0.7187,0.8175,0.6948,0.8374,0.6701,0.8558,0.6701,0.8558,0.6426,0.8763,0.6143,0.895,0.5855,0.9116,0.5855,0.9116,0.5619,0.9252,0.538,0.9374,0.514,0.9481,0.514,0.9481,0.4995,0.9545,0.485,0.9604,0.4705,0.9657,0.4705,0.9657,0.4645,0.9679,0.4585,0.97,0.4525,0.9719,0.4525,0.9719,0.4232,0.9817,0.3944,0.9889,0.3662,0.9936,0.3662,0.9936,0.3362,0.9986,0.3071,1.0007,0.2791,0.9999,0.2791,0.9999,0.2574,0.9993,0.2365,0.997,0.2165,0.9928,0.2165,0.9928,0.2049,0.9904,0.1936,0.9875,0.1827,0.9839,0.1827,0.9839,0.1776,0.9822,0.1726,0.9804,0.1676,0.9785,0.1676,0.9785,0.1459,0.9701,0.126,0.9593,0.1081,0.9463,0.1081,0.9463,0.0872,0.931,0.069,0.9128,0.0537,0.8919,0.0537,0.8919,0.0407,0.8739,0.0298,0.8538,0.0213,0.832,0.0213,0.832,0.0195,0.8272,0.0177,0.8223,0.0161,0.8173,0.0161,0.8173,0.0125,0.8063,0.0095,0.7949,0.0071,0.7832,0.0071,0.7832,0.003,0.7633,0.0007,0.7424,0.0001,0.7209,0.0001,0.7209,-0.0007,0.6929,0.0014,0.6638,0.0064,0.6338,0.0064,0.6338,0.0111,0.6055,0.0184,0.5764,0.0282,0.547,0.0282,0.547,0.0302,0.5412,0.0322,0.5353,0.0343,0.5295,0.0343,0.5295,0.0397,0.5148,0.0456,0.5002,0.0521,0.4856,0.0521,0.4856,0.0627,0.4617,0.0749,0.438,0.0884,0.4145,0.0884,0.4145,0.105,0.3857,0.1237,0.3574,0.1442,0.3299,0.1442,0.3299,0.1627,0.3051,0.1828,0.281,0.2042,0.2578,0.2042,0.2578,0.2127,0.2485,0.2215,0.2394,0.2304,0.2304,0.2304,0.2304,0.2395,0.2213,0.2488,0.2125,0.2582,0.2038,0.2582,0.2038,0.2813,0.1825,0.3052,0.1626,0.3299,0.1442,0.3299,0.1442,0.3574,0.1237,0.3857,0.105,0.4145,0.0884,0.4145,0.0884,0.4381,0.0748,0.462,0.0626,0.486,0.0519,0.486,0.0519,0.5005,0.0455,0.515,0.0396,0.5295,0.0343,0.5295,0.0343,0.5355,0.0321,0.5415,0.03,0.5475,0.0281,0.5475,0.0281,0.5768,0.0183,0.6056,0.0111,0.6338,0.0064,0.6338,0.0064,0.6638,0.0014,0.6929,-0.0007,0.7209,0.0001,0.7209,0.0001,0.7426,0.0007,0.7635,0.003,0.7835,0.0072,0.7835,0.0072,0.7951,0.0096,0.8064,0.0125,0.8173,0.0161,0.8173,0.0161,0.8224,0.0178,0.8274,0.0196,0.8324,0.0215,0.8324,0.0215,0.8541,0.0299,0.874,0.0407,0.8919,0.0537,0.8919,0.0537,0.9023,0.0613,0.9121,0.0697,0.9212,0.0788]
  private static let pair6End: [Double] = [0.7935,0.0952,0.8075,0.1053,0.8166,0.1222,0.8152,0.1417,0.8152,0.1417,0.813,0.1724,0.8108,0.203,0.8085,0.2336,0.8085,0.2336,0.808,0.2406,0.8089,0.2475,0.811,0.2539,0.811,0.2539,0.8166,0.2708,0.8305,0.2842,0.8487,0.2886,0.8487,0.2886,0.8784,0.2958,0.908,0.303,0.9377,0.3102,0.9377,0.3102,0.9758,0.3194,0.9908,0.3655,0.9656,0.3954,0.9656,0.3954,0.9458,0.4189,0.926,0.4424,0.9062,0.4658,0.9062,0.4658,0.9021,0.4707,0.8991,0.476,0.897,0.4817,0.897,0.4817,0.8906,0.4991,0.8937,0.5192,0.9063,0.534,0.9063,0.534,0.9261,0.5572,0.9459,0.5805,0.9657,0.6037,0.9657,0.6037,0.991,0.6336,0.9762,0.6797,0.9381,0.6891,0.9381,0.6891,0.9083,0.6964,0.8785,0.7038,0.8487,0.7111,0.8487,0.7111,0.8363,0.7142,0.8259,0.7215,0.8188,0.7312,0.8188,0.7312,0.8116,0.741,0.8078,0.7534,0.8088,0.7663,0.8088,0.7663,0.8111,0.7968,0.8134,0.8272,0.8158,0.8576,0.8158,0.8576,0.8187,0.8967,0.7796,0.9252,0.7433,0.9105,0.7433,0.9105,0.7149,0.8989,0.6865,0.8873,0.658,0.8758,0.658,0.8758,0.6402,0.8685,0.6203,0.8717,0.6058,0.8829,0.6058,0.8829,0.6009,0.8867,0.5967,0.8914,0.5933,0.8969,0.5933,0.8969,0.5772,0.9229,0.5612,0.9489,0.5452,0.9749,0.5452,0.9749,0.5247,1.0083,0.4762,1.0084,0.4556,0.9751,0.4556,0.9751,0.4394,0.949,0.4232,0.923,0.407,0.8969,0.407,0.8969,0.3972,0.8811,0.3803,0.8721,0.3627,0.872,0.3627,0.872,0.3558,0.8719,0.3488,0.8732,0.3421,0.8759,0.3421,0.8759,0.3139,0.8876,0.2857,0.8992,0.2574,0.9108,0.2574,0.9108,0.2212,0.9257,0.182,0.8973,0.1848,0.8583,0.1848,0.8583,0.187,0.8276,0.1892,0.797,0.1915,0.7664,0.1915,0.7664,0.192,0.7594,0.1911,0.7525,0.189,0.7461,0.189,0.7461,0.1834,0.7292,0.1695,0.7158,0.1513,0.7114,0.1513,0.7114,0.1216,0.7042,0.092,0.697,0.0623,0.6898,0.0623,0.6898,0.0242,0.6806,0.0092,0.6345,0.0344,0.6046,0.0344,0.6046,0.0542,0.5811,0.074,0.5576,0.0938,0.5342,0.0938,0.5342,0.0979,0.5293,0.1009,0.524,0.103,0.5183,0.103,0.5183,0.1094,0.5009,0.1063,0.4808,0.0937,0.466,0.0937,0.466,0.0739,0.4428,0.0541,0.4195,0.0343,0.3963,0.0343,0.3963,0.009,0.3664,0.0238,0.3203,0.0619,0.3109,0.0619,0.3109,0.0917,0.3036,0.1215,0.2962,0.1513,0.2889,0.1513,0.2889,0.1638,0.2858,0.1743,0.2784,0.1814,0.2686,0.1814,0.2686,0.1885,0.2588,0.1922,0.2465,0.1912,0.2337,0.1912,0.2337,0.1889,0.2032,0.1866,0.1728,0.1842,0.1424,0.1842,0.1424,0.1813,0.1033,0.2204,0.0748,0.2567,0.0895,0.2567,0.0895,0.2851,0.1011,0.3135,0.1127,0.342,0.1242,0.342,0.1242,0.3598,0.1315,0.3797,0.1283,0.3942,0.1171,0.3942,0.1171,0.3991,0.1133,0.4033,0.1086,0.4067,0.1031,0.4067,0.1031,0.4228,0.0771,0.4388,0.0511,0.4548,0.0251,0.4548,0.0251,0.4753,-0.0083,0.5238,-0.0084,0.5444,0.0249,0.5444,0.0249,0.5606,0.051,0.5768,0.077,0.593,0.1031,0.593,0.1031,0.6028,0.1189,0.6197,0.1279,0.6373,0.128,0.6373,0.128,0.6442,0.1281,0.6512,0.1268,0.6579,0.1241,0.6579,0.1241,0.6861,0.1124,0.7143,0.1008,0.7426,0.0892,0.7426,0.0892,0.7607,0.0817,0.7795,0.0851,0.7935,0.0952]
  static let cookie9Sided: [Double] = [0.5,0.0052,0.5379,0.0052,0.5757,0.0188,0.6057,0.046,0.6057,0.046,0.6362,0.0737,0.6764,0.0883,0.7176,0.0867,0.7176,0.0867,0.7985,0.0836,0.8686,0.1424,0.8795,0.2227,0.8795,0.2227,0.8851,0.2635,0.9065,0.3005,0.939,0.3257,0.939,0.3257,1.0031,0.3753,1.0189,0.4654,0.9758,0.534,0.9758,0.534,0.9538,0.5688,0.9464,0.6109,0.9551,0.6511,0.9551,0.6511,0.9722,0.7303,0.9265,0.8095,0.8494,0.8343,0.8494,0.8343,0.8101,0.8469,0.7774,0.8743,0.7582,0.9108,0.7582,0.9108,0.7205,0.9824,0.6345,1.0137,0.5595,0.9831,0.5595,0.9831,0.5214,0.9675,0.4786,0.9675,0.4405,0.9831,0.4405,0.9831,0.3655,1.0137,0.2795,0.9824,0.2418,0.9108,0.2418,0.9108,0.2226,0.8743,0.1899,0.8469,0.1506,0.8343,0.1506,0.8343,0.0735,0.8095,0.0278,0.7303,0.0449,0.6511,0.0449,0.6511,0.0536,0.6109,0.0462,0.5688,0.0242,0.534,0.0242,0.534,-0.0189,0.4654,-0.0031,0.3753,0.061,0.3257,0.061,0.3257,0.0935,0.3005,0.1149,0.2635,0.1205,0.2227,0.1205,0.2227,0.1314,0.1424,0.2015,0.0836,0.2824,0.0867,0.2824,0.0867,0.3236,0.0883,0.3638,0.0737,0.3943,0.046,0.3943,0.046,0.4243,0.0188,0.4621,0.0052,0.5,0.0052]
}

struct MDButtonStyle: ButtonStyle {
  enum Kind { case filled, tonal, text }
  var kind: Kind = .filled
  var minHeight: CGFloat = 40

  func makeBody(configuration: Configuration) -> some View {
    let restRadius = minHeight / 2
    let pressedRadius = minHeight <= 40 ? MDShape.small : MDShape.medium
    MDButtonBody(
      configuration: configuration,
      kind: kind,
      minHeight: minHeight,
      restShape: UnevenRoundedRectangle(
        topLeadingRadius: restRadius, bottomLeadingRadius: restRadius,
        bottomTrailingRadius: restRadius, topTrailingRadius: restRadius, style: .continuous),
      pressedShape: UnevenRoundedRectangle(
        topLeadingRadius: pressedRadius, bottomLeadingRadius: pressedRadius,
        bottomTrailingRadius: pressedRadius, topTrailingRadius: pressedRadius, style: .continuous))
  }

  fileprivate func foreground(for role: ButtonRole?) -> Color {
    if role == .destructive {
      switch kind {
      case .filled: return MDTheme.onError
      case .tonal: return MDTheme.onErrorContainer
      case .text: return MDTheme.error
      }
    }
    switch kind {
    case .filled: return MDTheme.onPrimary
    case .tonal: return MDTheme.onSecondaryContainer
    case .text: return MDTheme.primary
    }
  }

  fileprivate func background(for role: ButtonRole?) -> Color {
    switch kind {
    case .filled: role == .destructive ? MDTheme.error : MDTheme.primary
    case .tonal: role == .destructive ? MDTheme.errorContainer : MDTheme.secondaryContainer
    case .text: .clear
    }
  }
}

enum MDButtonGroupPosition {
  case single, first, middle, last

  fileprivate var leadingRadius: CGFloat {
    switch self {
    case .single, .first: MDShape.largeIncreased
    case .middle, .last: MDShape.small
    }
  }

  fileprivate var trailingRadius: CGFloat {
    switch self {
    case .single, .last: MDShape.largeIncreased
    case .first, .middle: MDShape.small
    }
  }

  fileprivate var pressedLeadingRadius: CGFloat {
    switch self {
    case .single: MDShape.medium
    case .first: MDShape.largeIncreased
    case .middle, .last: MDShape.extraSmall
    }
  }

  fileprivate var pressedTrailingRadius: CGFloat {
    switch self {
    case .single: MDShape.medium
    case .last: MDShape.largeIncreased
    case .first, .middle: MDShape.extraSmall
    }
  }
}

struct MDButtonRun<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 2) { content }
  }
}

struct MDConnectedButtonStyle: ButtonStyle {
  var kind: MDButtonStyle.Kind = .tonal
  let position: MDButtonGroupPosition

  func makeBody(configuration: Configuration) -> some View {
    MDButtonBody(
      configuration: configuration,
      kind: kind,
      minHeight: 40,
      restShape: UnevenRoundedRectangle(
        topLeadingRadius: position.leadingRadius,
        bottomLeadingRadius: position.leadingRadius,
        bottomTrailingRadius: position.trailingRadius,
        topTrailingRadius: position.trailingRadius,
        style: .continuous),
      pressedShape: UnevenRoundedRectangle(
        topLeadingRadius: position.pressedLeadingRadius,
        bottomLeadingRadius: position.pressedLeadingRadius,
        bottomTrailingRadius: position.pressedTrailingRadius,
        topTrailingRadius: position.pressedTrailingRadius,
        style: .continuous))
  }
}

private struct MDButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: MDButtonStyle.Kind
  let minHeight: CGFloat
  let restShape: UnevenRoundedRectangle
  let pressedShape: UnevenRoundedRectangle
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    let base = MDButtonStyle(kind: kind, minHeight: minHeight)
    let shape = configuration.isPressed ? pressedShape : restShape
    let foreground = base.foreground(for: configuration.role)
    let stateColor = kind == .filled ? foreground : (configuration.role == .destructive ? MDTheme.error : MDTheme.primary)

    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, kind == .text ? 12 : 16)
      .frame(minHeight: minHeight)
      .foregroundStyle(foreground)
      .background(base.background(for: configuration.role), in: shape)
      .overlay(
        shape.fill(stateColor.opacity(isEnabled ? (configuration.isPressed ? 0.10 : hovered ? 0.08 : 0) : 0))
          .allowsHitTesting(false))
      .opacity(isEnabled ? 1 : 0.38)
      .contentShape(shape)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: hovered)
      .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: configuration.isPressed)
      .onHover { hovered = $0 && isEnabled }
  }
}

struct MDInput<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content
  @FocusState private var isFocused: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.mdContainerSurface) private var containerSurface
  @State private var isHovered = false

  var body: some View {
    let borderColor: Color = isFocused
      ? MDTheme.primary
      : (isHovered && isEnabled ? MDTheme.onSurface : MDTheme.outline)
    content
      .textFieldStyle(.plain)
      .font(.system(size: 14))
      .focused($isFocused)
      .foregroundStyle(MDTheme.onSurface)
      .padding(.horizontal, 16)
      .frame(minHeight: 56)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(containerSurface, in: RoundedRectangle(cornerRadius: MDShape.large, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: MDShape.large, style: .continuous)
          .strokeBorder(borderColor, lineWidth: isFocused ? 2 : 1)
      }
      .overlay(alignment: .topLeading) {
        Text(title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isFocused ? MDTheme.primary : MDTheme.onSurfaceVariant)
          .padding(.horizontal, 5)
          .background(containerSurface)
          .offset(x: 12, y: -7)
      }
      .padding(.top, 7)
      .compositingGroup()
      .opacity(isEnabled ? 1 : 0.38)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isFocused)
      .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
      .onHover { isHovered = $0 }
  }
}

struct MDSearchField: View {
  let prompt: String
  @Binding var text: String
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

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
    .background(MDTheme.surfaceContainerHigh, in: Capsule(style: .circular))
    .overlay {
      Capsule(style: .circular).strokeBorder(isFocused ? MDTheme.primary : (isHovered ? MDTheme.outlineVariant : .clear), lineWidth: isFocused ? 2 : 1)
    }
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isFocused)
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
    .onHover { isHovered = $0 }
  }
}

struct MDRadioMark: View {
  let isSelected: Bool
  var isHovered = false
  var isPressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var localHovered = false

  var body: some View {
    let activeHover = isHovered || localHovered
    let haloColor = (isSelected ? MDTheme.primary : MDTheme.onSurface)
      .opacity(isPressed ? 0.10 : activeHover ? 0.08 : 0)

    ZStack {
      Circle()
        .fill(haloColor)
        .frame(width: 40, height: 40)

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
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: activeHover)
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isPressed)
    .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: isSelected)
    .onHover { localHovered = $0 }
    .accessibilityHidden(true)
  }
}

struct MDSwitch: View {
  @Binding var isOn: Bool
  var label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button {
      if reduceMotion {
        isOn.toggle()
      } else {
        withAnimation(MDMotion.fastSpatial) {
          isOn.toggle()
        }
      }
    } label: {
      EmptyView()
    }
    .buttonStyle(MDSwitchButtonStyle(isOn: isOn, isEnabled: isEnabled, reduceMotion: reduceMotion))
    .accessibilityLabel(label)
    .accessibilityValue(isOn ? L10n.text("common.enabled") : L10n.text("common.disabled"))
  }
}

private struct MDSwitchButtonStyle: ButtonStyle {
  let isOn: Bool
  let isEnabled: Bool
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    MDSwitchBody(
      isOn: isOn,
      isPressed: configuration.isPressed && isEnabled,
      isEnabled: isEnabled,
      reduceMotion: reduceMotion)
  }
}

private struct MDSwitchBody: View {
  let isOn: Bool
  let isPressed: Bool
  let isEnabled: Bool
  let reduceMotion: Bool
  @State private var isHovered = false

  var body: some View {
    // M3E Switch tokens: thumb expands to 28pt on press; 40pt halo centers on thumb.
    let thumbSize: CGFloat = isPressed ? 28 : (isOn ? 24 : 16)
    let thumbOffsetX: CGFloat = isPressed ? (isOn ? 22 : 2) : (isOn ? 24 : 8)
    let thumbColor: Color = if isOn {
      (isPressed || isHovered) ? MDTheme.primaryContainer : MDTheme.onPrimary
    } else {
      (isPressed || isHovered) ? MDTheme.onSurfaceVariant : MDTheme.outline
    }
    let haloColor: Color = (isOn ? MDTheme.primary : MDTheme.onSurface)
      .opacity(isEnabled ? (isPressed ? 0.10 : isHovered ? 0.08 : 0) : 0)

    ZStack(alignment: .leading) {
      Capsule(style: .circular)
        .fill(isOn ? MDTheme.primary : MDTheme.surfaceContainerHighest)

      Capsule(style: .circular)
        .strokeBorder(isOn ? .clear : MDTheme.outline, lineWidth: 2)

      ZStack {
        Circle()
          .fill(haloColor)
          .frame(width: 40, height: 40)

        Circle()
          .fill(thumbColor)
          .frame(width: thumbSize, height: thumbSize)

        if isOn {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle((isPressed || isHovered) ? MDTheme.onPrimaryContainer : MDTheme.primary)
            .transition(.scale(scale: 0.75).combined(with: .opacity))
        }
      }
      .frame(width: thumbSize, height: thumbSize)
      .offset(x: thumbOffsetX)
    }
    .frame(width: 52, height: 32)
    .contentShape(Capsule(style: .circular))
    .opacity(isEnabled ? 1 : 0.38)
    .animation(reduceMotion ? nil : MDMotion.fastEffects, value: isHovered)
    .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: isPressed)
    .animation(reduceMotion ? nil : MDMotion.fastSpatial, value: isOn)
    .onHover { isHovered = $0 && isEnabled }
  }
}

struct MDBanner: View {
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
        .foregroundStyle(tone == .red ? MDTheme.onErrorContainer : MDTheme.onSurfaceVariant)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.container, in: RoundedRectangle(cornerRadius: MDShape.large, style: .continuous))
  }
}

#Preview("Material 3") {
  MDPage {
    MDSection(title: L10n.text("ui.project")) {
      MDList {
        MDListRow(title: "Luti", symbol: "folder", subtitle: "~/Projects/Luti") {
          Button(L10n.text("ui.change")) {}.buttonStyle(MDButtonStyle(kind: .tonal))
        }
      }
    }
  }.frame(width: 540, height: 500)
}
