import SwiftUI

struct MDOption<Value: Hashable>: Identifiable {
  let value: Value
  let title: String
  var id: Value { value }
}

/// Compact segmented filter used for small in-place filters such as Activity.
/// Full-page choices use a navigation row + radio list instead of dropdowns.
struct MDFilterBar<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [MDOption<Value>]
  @FocusState private var focusedOption: Value?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) { choices }
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) { choices }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .onMoveCommand { direction in
      guard direction == .left || direction == .right,
            let index = options.firstIndex(where: { $0.value == (focusedOption ?? selection) }),
            !options.isEmpty
      else { return }
      let next = (index + (direction == .right ? 1 : -1) + options.count) % options.count
      selection = options[next].value
      focusedOption = selection
    }
  }

  private var choices: some View {
    ForEach(options) { option in
      Button { selection = option.value } label: {
        Text(option.title)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(
        MDFilterChoiceStyle(
          isSelected: selection == option.value,
          isFocused: focusedOption == option.value))
      .focusable()
      .focusEffectDisabled()
      .focused($focusedOption, equals: option.value)
      .accessibilityAddTraits(selection == option.value ? .isSelected : [])
      .help(option.title)
    }
  }
}

private struct MDFilterChoiceStyle: ButtonStyle {
  let isSelected: Bool
  let isFocused: Bool

  func makeBody(configuration: Configuration) -> some View {
    MDFilterChoiceBody(
      configuration: configuration,
      isSelected: isSelected,
      isFocused: isFocused)
  }
}

private struct MDFilterChoiceBody: View {
  let configuration: ButtonStyleConfiguration
  let isSelected: Bool
  let isFocused: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovered = false

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 18, style: .continuous)
  }

  var body: some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isSelected ? MDTheme.onPrimaryContainer : MDTheme.onSurface)
      .padding(.horizontal, 14)
      .frame(minHeight: 40)
      .background(
        isSelected ? MDTheme.primaryContainer : MDTheme.surfaceContainerHigh,
        in: shape)
      .overlay(
        shape.fill(
          MDTheme.primary.opacity(
            configuration.isPressed ? 0.12 : isFocused ? 0.08 : isHovered ? 0.06 : 0)))
      .contentShape(shape)
      .opacity(isEnabled ? 1 : 0.38)
      .onHover { isHovered = $0 && isEnabled }
  }
}
