import SwiftUI

struct MobileAccountView: View {
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(ThemeManager.self) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(PersistenceKey.chatSyncToStream) private var chatSync = true

  var body: some View {
    @Bindable var theme = theme
    Form {
      Section("Twitch") {
        if auth.isAuthenticated {
          Text("Signed in as \(auth.userDisplayName ?? auth.userLogin ?? "")")
          Button("Sign out", role: .destructive) { auth.signOut() }
        } else {
          Text("Sign in to see your follows and send chat messages. You can watch without signing in.")
            .foregroundStyle(.secondary)
          if auth.isAuthenticating {
            if let code = auth.activationCode {
              Text(code).font(.title.monospaced().bold()).textSelection(.enabled)
                .accessibilityLabel("Sign-in code: \(code)")
            }
            if let raw = auth.verificationURIComplete ?? auth.verificationURI,
               let url = URL(string: raw) {
              Link("Continue on Twitch", destination: url).buttonStyle(.borderedProminent)
            }
            if let status = auth.statusMessage { Text(status).foregroundStyle(.secondary) }
            Button("Cancel sign-in") { auth.cancelSignIn() }
          } else {
            Button("Sign in to Twitch") { Task { await auth.beginDeviceCodeSignIn() } }
          }
        }
        if let error = auth.errorMessage { Text(error).foregroundStyle(.secondary) }
      }
      Section("Appearance") {
        Picker("Theme", selection: $theme.theme) {
          ForEach(AppTheme.allCases) { theme in
            Text(theme.displayName).tag(theme)
          }
        }
      }
      Section {
        Toggle("Sync chat to extra delay", isOn: $chatSync)
      } footer: {
        Text("Chat stays live during normal playback. When video falls further behind, incoming chat waits to match it. Sending is always immediate.")
      }
      Section {
        Text("This first mobile version supports Twitch live streams. VODs, clips, multiview, and merged chat are not included.")
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Account")
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await auth.validateSessionIfNeeded() } }
    }
  }
}
