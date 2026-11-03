import SwiftUI

struct StreamPlatformSelectionControls: View {
  @Binding var selection: StreamPlatforms

  var body: some View {
    Toggle(
      "Twitch",
      isOn: Binding(
        get: { selection.includesTwitch },
        set: { selection = $0 ? (selection.includesKick ? .both : .twitch) : .kick })
    )
    .platformSelectionButtonStyle()
    .disabled(selection == .twitch)
    .accessibilityIdentifier("platform-choice-twitch")
    Toggle(
      "Kick",
      isOn: Binding(
        get: { selection.includesKick },
        set: { selection = $0 ? (selection.includesTwitch ? .both : .kick) : .twitch })
    )
    .platformSelectionButtonStyle()
    .disabled(selection == .kick)
    .accessibilityIdentifier("platform-choice-kick")
  }
}

struct StreamPlatformSettingsView: View {
  private var preferences: StreamPlatformPreferences { .shared }

  var body: some View {
    @Bindable var preferences = preferences
    Form {
      Section {
        StreamPlatformSelectionControls(selection: $preferences.selection)
      } footer: {
        Text("Choose at least one. Saved accounts are kept.")
      }
    }
    .navigationTitle("Platforms")
    #if os(tvOS)
      .resolveGlassDisabled()
    #endif
  }
}

struct StreamPlatformOnboardingView: View {
  var preferences: StreamPlatformPreferences = .shared
  @State private var selection = StreamPlatforms.both
  @Environment(\.themePalette) private var palette

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Text("Choose your platforms").font(.largeTitle.bold())
        Text("Choose one or both. You can change this in Settings.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        VStack(spacing: 20) {
          StreamPlatformSelectionControls(selection: $selection)
        }
        .padding(.vertical, 16)
        Button("Continue") { preferences.completeOnboarding(selection) }
          .platformSelectionButtonStyle(prominent: true)
          .accessibilityIdentifier("platform-choice-continue")
      }
      .padding(32)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.center, for: .alignment)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom)
    )
    .onAppear { selection = preferences.selection }
    .accessibilityIdentifier("platform-onboarding")
    #if os(tvOS)
      .resolveGlassDisabled()
    #endif
  }
}

extension View {
  @ViewBuilder
  fileprivate func platformSelectionButtonStyle(prominent: Bool = false) -> some View {
    #if os(tvOS)
      // Native tvOS opaque controls can invert against their labels; reuse the themed fallback.
      chatSettingsGlassButton()
    #else
      if prominent { buttonStyle(.borderedProminent) } else { self }
    #endif
  }
}
