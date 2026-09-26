import SwiftUI

/// A one-time invitation, not a permission request to Twitch or tvOS.
struct GoLiveAlertsSetupView: View {
  let follows: FollowedChannelsService
  let settings: GoLiveNotificationSettings
  let auth: TwitchAuthSession

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @FocusState private var keepOffFocused: Bool

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 48) {
        GoLiveAlertsSetupHeader()

        HStack(spacing: 32) {
          Button(role: .cancel) {
            settings.disableAll()
            dismiss()
          } label: {
            GoLiveAlertOptionCard(
              glyph: .x,
              title: "Keep Off",
              subtitle: "No go-live alerts while you watch.")
          }
          .focused($keepOffFocused)

          Button {
            settings.enableAll()
            dismiss()
          } label: {
            GoLiveAlertOptionCard(
              glyph: .broadcast,
              title: "All Channels",
              subtitle: "Every follow, including new ones.")
          }

          NavigationLink {
            GoLiveAlertsSettingsView(follows: follows, settings: settings, auth: auth)
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") { dismiss() }
                }
              }
          } label: {
            GoLiveAlertOptionCard(
              glyph: .adjustmentsHorizontal,
              title: "Choose Channels",
              subtitle: settings.mode == .all
                ? "Turn any channel off to start a custom list."
                : "Pick your channels. New follows stay off.")
          }
        }
        .buttonStyle(.plain)
        .focusSection()

        Text("Only in Strozz, not synced with Twitch's bell. Change anytime in Settings.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: 1320)
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.vertical, 60)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { AppBackground(palette: palette) }
      .defaultFocus($keepOffFocused, true)
      .onAppear { settings.markPromptPresented() }
      .onExitCommand { dismiss() }
    }
  }

  private struct GoLiveAlertsSetupHeader: View {
    var body: some View {
      HStack(spacing: 28) {
        Image("StrozzPixelLogo")
          .resizable()
          .interpolation(.none)
          .scaledToFit()
          .frame(width: 96, height: 96)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 12) {
          Text("Go Live Alerts")
            .font(.largeTitle.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text("Get a heads-up when your favorite channels start streaming.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private struct GoLiveAlertOptionCard: View {
    let glyph: Glyph
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette
    @Environment(\.glassDisabled) private var glassDisabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesLiftText: Bool {
      strozzUsesLiftFocusedText(isFocused: isFocused, glassDisabled: glassDisabled)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Icon(glyph: glyph, size: 44)
          .padding(.bottom, 16)
          .accessibilityHidden(true)
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(usesLiftText ? palette.liftSecondaryText : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(usesLiftText ? palette.liftPrimaryText : Color.primary)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
      .padding(32)
      .strozzLiquidGlassCard(
        cornerRadius: CardMetrics.cardCornerRadius, isFocused: isFocused, palette: palette)
      .scaleEffect(isFocused && !reduceMotion ? AppLayout.focusedCardScale : 1)
      .animation(reduceMotion ? nil : AppLayout.focusScaleAnimation, value: isFocused)
      .accessibilityElement(children: .combine)
    }
  }
}
