import SwiftUI

struct MultiviewControls: View {
  let layout: MultiviewLayout
  let showsLayoutPicker: Bool
  let canBrowse: Bool
  let hasLineup: Bool
  var focus: FocusState<MultiviewFocusTarget?>.Binding
  let onLayout: () -> Void
  let onSelectLayout: (MultiviewLayout) -> Void
  let onBrowse: () -> Void
  let onDone: () -> Void
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    VStack(spacing: 24) {
      if showsLayoutPicker {
        MultiviewLayoutPicker(layout: layout, focus: focus, onSelect: onSelectLayout)
      }
      MultiviewControlRow {
        Button(action: onLayout) {
          Label { Text("Layout") } icon: { Icon(glyph: layout.glyph, size: 22) }
        }
        .focused(focus, equals: .layoutButton)
        .accessibilityValue(Text(layout.title))
        .accessibilityIdentifier("multiview-layout")
        if canBrowse {
          Button(action: onBrowse) {
            Label {
              if hasLineup { Text("Browse streams") } else { Text("Add stream") }
            } icon: { Icon(glyph: .plus, size: 22) }
          }
          .focused(focus, equals: .addButton)
          .accessibilityIdentifier("multiview-browse")
        }
        Button(action: onDone) {
          Label { Text("Done") } icon: { Icon(glyph: .check, size: 22) }
        }
        .focused(focus, equals: .closeButton)
        .accessibilityIdentifier("multiview-controls-done")
      }
      .disabled(showsLayoutPicker)
    }
    .lineLimit(1)
    .fixedSize(horizontal: false, vertical: true)
    .focusSection()
    .environment(\.colorScheme, palette.chromeColorScheme)
    .environment(\.glassDisabled, glassDisabled || reduceTransparency)
    .task(id: showsLayoutPicker) {
      focus.wrappedValue = showsLayoutPicker ? .layoutChoice(layout) : .layoutButton
    }
  }
}

private struct MultiviewLayoutPicker: View {
  let layout: MultiviewLayout
  var focus: FocusState<MultiviewFocusTarget?>.Binding
  let onSelect: (MultiviewLayout) -> Void

  var body: some View {
    MultiviewControlRow {
      ForEach(MultiviewLayout.allCases, id: \.self) { choice in
        Button { onSelect(choice) } label: {
          HStack(spacing: 10) {
            Icon(glyph: choice.glyph, size: 22)
            Text(choice.title)
            Icon(glyph: .check, size: 18)
              .opacity(choice == layout ? 1 : 0)
              .accessibilityHidden(true)
          }
        }
        .focused(focus, equals: .layoutChoice(choice))
        .accessibilityIdentifier("multiview-layout-\(choice.rawValue)")
        .accessibilityAddTraits(choice == layout ? [.isSelected] : [])
      }
    }
  }
}

private struct MultiviewControlRow<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 22, content: content)
        .font(.headline)
        .padding(.horizontal, 28)
        .fixedSize()
      HStack(spacing: 12, content: content)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 18)
        .fixedSize(horizontal: false, vertical: true)
    }
    .StrozzControlButtonStyle()
    .padding(.vertical, 18)
    .modifier(ChatSettingsPanelGlassStyle())
  }
}
