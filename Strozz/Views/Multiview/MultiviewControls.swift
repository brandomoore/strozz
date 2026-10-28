import SwiftUI

struct MultiviewControls: View {
  let layout: MultiviewLayout
  let canBrowse: Bool
  let hasLineup: Bool
  var focus: FocusState<MultiviewFocusTarget?>.Binding
  let onSelectLayout: (MultiviewLayout) -> Void
  let onBrowse: () -> Void
  let onDone: () -> Void
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(spacing: 12) {
      Menu {
        MultiviewLayoutOptions(layout: layout, onSelect: onSelectLayout)
      } label: {
        Label { Text("Layout") } icon: { Icon(glyph: layout.glyph, size: 20) }
          .font(.system(size: 24, weight: .semibold))
      }
      .focused(focus, equals: .layoutButton)
      .accessibilityLabel("Layout")
      .accessibilityValue(Text(layout.title))
      .accessibilityIdentifier("multiview-layout")
      if canBrowse {
        Button(action: onBrowse) {
          Label {
            if hasLineup { Text("Browse streams") } else { Text("Add stream") }
          } icon: { Icon(glyph: .plus, size: 20) }
            .font(.system(size: 24, weight: .semibold))
        }
        .focused(focus, equals: .addButton)
        .accessibilityIdentifier("multiview-browse")
      }
      Button(action: onDone) {
        Label { Text("Done") } icon: { Icon(glyph: .check, size: 20) }
          .font(.system(size: 24, weight: .semibold))
      }
      .focused(focus, equals: .closeButton)
      .accessibilityIdentifier("multiview-controls-done")
    }
    .lineLimit(1)
    .controlSize(.small)
    .StrozzControlButtonStyle()
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .modifier(ChatSettingsPanelGlassStyle())
    .fixedSize(horizontal: false, vertical: true)
    .focusSection()
    .environment(\.colorScheme, palette.chromeColorScheme)
    .environment(\.glassDisabled, glassDisabled || reduceTransparency)
    .task { focus.wrappedValue = .layoutButton }
  }
}

struct MultiviewLayoutOptions: View {
  let layout: MultiviewLayout
  let onSelect: (MultiviewLayout) -> Void

  var body: some View {
    Picker("Layout", selection: Binding(get: { layout }, set: onSelect)) {
      ForEach(MultiviewLayout.allCases, id: \.self) { choice in
        Label {
          Text(choice.title)
        } icon: {
          Icon(glyph: choice.glyph)
        }
        .tag(choice)
        .accessibilityIdentifier("multiview-layout-\(choice.rawValue)")
      }
    }
    .pickerStyle(.inline)
  }
}
