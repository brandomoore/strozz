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
  var theme: AppTheme = .system
  @State private var selection = StreamPlatforms.both
  // System appearance must be read inside the scene's view hierarchy, not on App.
  @Environment(\.colorScheme) private var colorScheme

  private var palette: ThemePalette { theme.palette(systemColorScheme: colorScheme) }

  var body: some View {
    ZStack {
      LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()

      ScrollView {
        VStack(spacing: 40) {
          StreamPlatformOnboardingHeader()
          VStack(spacing: 32) {
            VStack(spacing: 20) {
              StreamPlatformSelectionControls(selection: $selection)
            }
            Button {
              preferences.completeOnboarding(selection)
            } label: {
              Text("Continue").frame(minWidth: 180)
            }
            .controlSize(.large)
            .platformSelectionButtonStyle(prominent: true)
            .accessibilityIdentifier("platform-choice-continue")
          }
          .frame(maxWidth: 600)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 64)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
      }
      .defaultScrollAnchor(.center, for: .alignment)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.themePalette, palette)
    .preferredColorScheme(theme.preferredColorScheme)
    .onAppear { selection = preferences.selection }
    .accessibilityIdentifier("platform-onboarding")
    #if os(tvOS)
      .resolveGlassDisabled()
    #endif
  }
}

private struct StreamPlatformOnboardingHeader: View {
  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(spacing: 12) {
      Text("Choose your platforms")
        .font(.largeTitle.bold())
        .foregroundStyle(palette.chromeOnOpaque)
        .accessibilityIdentifier("platform-choice-title")
      Text("Choose one or both.")
        .foregroundStyle(palette.chromeOnOpaque.opacity(0.7))
        .accessibilityIdentifier("platform-choice-description")
    }
    .multilineTextAlignment(.center)
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
