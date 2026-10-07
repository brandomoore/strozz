import SwiftUI

struct MobileAccountView: View {
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(ThemeManager.self) private var theme
  @Environment(WatchHistoryService.self) private var history
  @Environment(MobileVODProgressStore.self) private var vodProgress
  @Environment(TwitchAccountSync.self) private var sync
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(PersistenceKey.chatSyncToStream) private var chatSync = true
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalized = true
  @State private var confirmingClearHistory = false
  @State private var showSignIn = false
  @State private var showLocalSignOut = false

  var body: some View {
    @Bindable var theme = theme
    Form {
      Section {
        if auth.isAuthenticated {
          MobileTwitchIdentityRow(name: auth.userDisplayName ?? auth.userLogin ?? "Twitch",
                                 imageURL: auth.profileImageURL)
          Button("Sign out", role: .destructive) { showLocalSignOut = true }
            .accessibilityIdentifier("account-sign-out-local")
        } else {
          Text(sync.isSignedOutLocally
            ? "Signed out on this device. Sign in to reconnect."
            : "Your saved Twitch connection restores automatically through iCloud.")
            .foregroundStyle(.secondary)
          Button("Sign in to Twitch") { showSignIn = true }
            .accessibilityIdentifier("account-sign-in")
            .disabled(!sync.hasCompletedInitialSync || sync.isBusy)
        }
        if let error = auth.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
      } header: { Text("Twitch") }

      Section {
        HStack {
          Text(auth.isAuthenticated ? "Sign-in sharing" : "Connect from another device")
          Spacer()
          if sync.isBusy { ProgressView().accessibilityLabel("Syncing account") }
        }
        Text(sync.status).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("account-sync-status")
        if let error = sync.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
        if !sync.isSignedOutLocally {
          Button("Sync now") {
            Task { await sync.synchronize() }
          }
          .disabled(sync.isBusy)
          .accessibilityIdentifier("account-sync")
        }
        NavigationLink("Manage connected account") { MobileConnectedAccountView() }
          .accessibilityIdentifier("account-manage-sync")
      } header: {
        Text("Across your devices")
      } footer: {
        Text("Sign in once. Strozz securely shares the connection with your other devices using the same Apple Account.")
      }

      MobileWatchRewardsSettings()

      Section("Appearance") {
        Picker("Theme", selection: $theme.theme) {
          ForEach(AppTheme.allCases) { theme in Text(theme.displayName).tag(theme) }
        }
        NavigationLink("Overlays") { MobileOverlaySettingsView() }
          .accessibilityIdentifier("account-overlays")
      }
      Section {
        Toggle("Sync chat to extra delay", isOn: $chatSync)
      } footer: {
        Text("Chat stays live normally. If video falls behind, incoming chat waits to match it.")
      }
      Section {
        Toggle("Personalized Home", isOn: $personalized)
        Button("Clear watch history and broadcast progress", role: .destructive) { confirmingClearHistory = true }
      } footer: {
        Text("Viewing history stays on this device, separately for each account.")
      }
    }
    .buttonStyle(.borderless)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showSignIn) { MobileTwitchSignInSheet() }
    .confirmationDialog("Sign out on this device?", isPresented: $showLocalSignOut, titleVisibility: .visible) {
      Button("Sign out", role: .destructive) { auth.signOut() }
    } message: { Text("Your other devices stay connected. This device stays signed out until you choose Sign in.") }
    .confirmationDialog("Clear this account's history on this device?", isPresented: $confirmingClearHistory) {
      Button("Clear history", role: .destructive) { history.clear(); vodProgress.clear() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await sync.synchronize(); await auth.validateSessionIfNeeded() } }
    }
  }
}

private struct MobileOverlaySettingsView: View {
  @AppStorage(PersistenceKey.showStreamDuration) private var showStreamDuration = true

  var body: some View {
    Form {
      Toggle("Stream duration", isOn: $showStreamDuration)
        .accessibilityIdentifier("overlay-stream-duration")
    }
    .navigationTitle("Overlays")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MobileTwitchIdentityRow: View {
  let name: String
  let imageURL: URL?
  var body: some View {
    HStack(spacing: 12) {
      CachedAsyncImage(url: imageURL) { image in image.resizable().scaledToFill() }
        placeholder: { Circle().fill(.quaternary) }
        .frame(width: 44, height: 44).clipShape(Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.headline)
        Text("Connected to Twitch").font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

private struct MobileTwitchSignInSheet: View {
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("We'll use your saved connection if available. Otherwise, approve Strozz on Twitch to connect your devices.")
          if let code = auth.activationCode {
            Text(code).font(.title.monospaced().bold()).textSelection(.enabled)
          } else if auth.isRestoringConnection { ProgressView("Checking your saved connection...") }
          else if auth.isAuthenticating { ProgressView("Requesting a sign-in code") }
          if let raw = auth.verificationURIComplete ?? auth.verificationURI, let url = URL(string: raw) {
            Link("Continue on Twitch", destination: url)
          }
          if let status = auth.statusMessage { Text(status).foregroundStyle(.secondary) }
          if let error = auth.errorMessage { Text(error).foregroundStyle(.secondary) }
          if !auth.isAuthenticating && !auth.isAuthenticated && !auth.isRestoringConnection {
            Button("Try again") { Task { await auth.beginDeviceCodeSignIn() } }
            if auth.errorMessage != nil {
              Button("Sign in with Twitch instead") {
                Task { await auth.beginDeviceCodeSignIn(useSavedConnection: false) }
              }
            }
          }
        }
      }
      .buttonStyle(.borderless)
      .navigationTitle("Connect Twitch")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
    .task { await auth.beginDeviceCodeSignIn() }
    .onChange(of: auth.isAuthenticated) { _, connected in if connected { dismiss() } }
    .onDisappear { auth.cancelSignIn() }
  }
}

private struct MobileConnectedAccountView: View {
  @Environment(TwitchAccountSync.self) private var sync
  @State private var confirmReplace = false
  @State private var confirmSignOut = false
  var body: some View {
    Form {
      Section {
        Text(sync.status)
        Text("Changes here affect Strozz on devices using this Apple Account. They do not delete your Twitch account or its follows, points, and streaks.")
          .foregroundStyle(.secondary)
        if sync.hasAccountConflict {
          Button("Use the connection saved in iCloud") { Task { await sync.useICloudAccount() } }
          Button("Replace iCloud connection with this device") { confirmReplace = true }
        }
      }
      Section {
        Button("Sign out everywhere", role: .destructive) { confirmSignOut = true }
          .accessibilityIdentifier("account-sign-out-all")
      } footer: { Text("For this device only, use Sign out on the Account page.") }
    }
    .buttonStyle(.borderless)
    .navigationTitle("Connected account")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Replace the connection on your other devices?", isPresented: $confirmReplace, titleVisibility: .visible) {
      Button("Replace iCloud connection", role: .destructive) { Task { await sync.replaceICloudAccount() } }
        .disabled(sync.isBusy)
    }
    .confirmationDialog("Sign out of Twitch and rewards everywhere?", isPresented: $confirmSignOut, titleVisibility: .visible) {
      Button("Sign out everywhere", role: .destructive) { Task { await sync.signOutAllDevices() } }
        .disabled(sync.isBusy)
    }
  }
}
