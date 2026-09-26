import SwiftUI

struct TwitchWatchRewardsSection: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.glassDisabled) private var glassDisabled
  @State private var showConnect = false
  @State private var showDisconnect = false

  private var session: TwitchWatchRewardsSession { environment.watchRewards }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Twitch Rewards")
        .font(.title3.weight(.semibold))
      if let credential = session.credential {
        Text("Connected as \(credential.login)")
          .font(.callout)
      } else if environment.auth.isAuthenticated {
        Text("Connect for watch streaks, polls, and channel rewards.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let error = session.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.primary)
      }
      if !environment.auth.isAuthenticated {
        Text("Sign in to Strozz with Twitch first.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 24) {
        Button(session.isConnected ? "Reconnect" : "Connect") {
          showConnect = true
        }
        .disabled(!environment.auth.isAuthenticated)
        if session.isConnected {
          Button("Disconnect", role: .destructive) {
            showDisconnect = true
          }
        }
      }
      .font(.headline)
      .settingsProminentActionButtonStyle()
      if session.isConnected {
        Toggle("Collect watch bonuses", isOn: Binding(
          get: { session.autoClaimBonuses },
          set: { session.autoClaimBonuses = $0 }))
          .font(.callout)
      }
      Text("Experimental. Twitch determines viewing credit.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .settingsGlassPanel(disabled: glassDisabled)
    .focusSection()
    .fullScreenCover(isPresented: $showConnect) {
      TwitchWatchRewardsSignInView(session: session, userID: environment.auth.userID ?? "")
    }
    .confirmationDialog("Disconnect Twitch watch rewards?", isPresented: $showDisconnect) {
      Button("Disconnect", role: .destructive) { session.disconnect() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your normal Twitch sign-in stays connected.")
    }
  }
}

private struct TwitchWatchRewardsSignInView: View {
  let session: TwitchWatchRewardsSession
  let userID: String
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @State private var attempt = UUID()

  var body: some View {
    ZStack {
      LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
      VStack(spacing: 28) {
        Text("Connect Twitch Rewards")
          .font(.title.weight(.bold))
        Text("Use the same Twitch account as Strozz.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 1200)
        if let code = session.deviceCode, let url = code.activationURL {
          HStack(spacing: 72) {
            BrandQRCodeView(
              payload: url.absoluteString, logoName: "twitch-logo",
              moduleColor: palette.liftPrimaryText, backgroundColor: palette.liftSurface, size: 330)
            VStack(spacing: 24) {
              Text("Scan with your phone, or visit")
              Text("twitch.tv/activate")
                .font(.title2.weight(.semibold))
              Text(code.user_code)
                .font(.system(size: 76, weight: .bold, design: .monospaced))
              Text("Waiting for Twitch approval")
                .foregroundStyle(.secondary)
            }
          }
        } else if session.isConnecting {
          ProgressView("Requesting Twitch code")
            .frame(height: 380)
        }
        if let error = session.errorMessage {
          Text(error)
            .font(.callout)
            .multilineTextAlignment(.center)
          Button("Try Again") { attempt = UUID() }
        }
        Button("Cancel") {
          session.cancelConnection()
          dismiss()
        }
      }
      .padding(64)
    }
    .task(id: attempt) { await session.connect(expectedUserID: userID) }
    .onChange(of: session.isConnecting) { wasConnecting, connecting in
      if wasConnecting, !connecting, session.errorMessage == nil, session.isConnected { dismiss() }
    }
    .onDisappear { session.cancelConnection() }
  }
}

struct TwitchWatchStreakStatusView: View {
  let tracker: TwitchWatchTracker

  var body: some View {
    Group {
      if tracker.state == .unavailable {
        Text("Watch streak unavailable")
          .accessibilityHint(tracker.errorMessage ?? "")
      } else if let streak = tracker.streak {
        HStack(spacing: 6) {
          Icon(glyph: .flame, size: 20)
          Text("\(streak)-stream watch streak")
        }
      } else if tracker.state == .watching {
        Text("Watch streak: awaiting Twitch")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
