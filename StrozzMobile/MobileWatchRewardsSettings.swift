import SwiftUI

struct MobileWatchRewardsSettings: View {
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchWatchRewardsSession.self) private var rewards
  @Environment(\.openURL) private var openURL
  @State private var disconnecting = false
  @State private var lastOpenedCode: String?
  @State private var browserUnavailable = false

  var body: some View {
    Section {
      if let credential = rewards.credential {
        Text("Connected as \(credential.login)")
        Toggle("Collect watch bonuses", isOn: Binding(
          get: { rewards.autoClaimBonuses }, set: { rewards.autoClaimBonuses = $0 }))
        Button("Disconnect rewards", role: .destructive) { disconnecting = true }
      } else if rewards.isConnecting {
        if let code = rewards.deviceCode, let url = code.activationURL {
          Text("Waiting for Twitch approval").foregroundStyle(.secondary)
          Link("Continue on Twitch", destination: url)
          if browserUnavailable {
            Text("Your browser could not open. Visit twitch.tv/activate and enter this code:")
              .font(.callout)
            Text(code.user_code).font(.headline.monospaced()).textSelection(.enabled)
          }
        } else { ProgressView("Connecting to Twitch") }
        Button("Cancel connection") { rewards.cancelConnection() }
      } else {
        Text(auth.isAuthenticated ? "One extra Twitch approval enables channel points and watch streaks."
             : "Connect your Twitch account first to enable rewards.")
          .foregroundStyle(.secondary)
        Button("Connect rewards") {
          guard let userID = auth.userID else { return }
          lastOpenedCode = nil
          browserUnavailable = false
          rewards.beginConnection(expectedUserID: userID)
        }
          .disabled(!auth.isAuthenticated || rewards.isConnecting)
          .accessibilityIdentifier("account-connect-rewards")
      }
      if let error = rewards.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
    } header: {
      Text("Rewards & streaks")
    } footer: {
      Text("Your rewards connection also syncs through iCloud. Experimental; Twitch determines viewing credit.")
    }
    .onChange(of: rewards.deviceCode) { _, code in
      guard rewards.isConnecting, let code, code.user_code != lastOpenedCode, let url = code.activationURL else { return }
      lastOpenedCode = code.user_code
      openURL(url) { accepted in browserUnavailable = !accepted }
    }
    .confirmationDialog("Disconnect rewards on synced devices?", isPresented: $disconnecting, titleVisibility: .visible) {
      Button("Disconnect rewards", role: .destructive) { rewards.disconnect() }
    }
  }
}
