import SwiftUI

struct TwitchAccountLoadingView: View {
  var body: some View {
    ProgressView()
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Loading your account")
      .accessibilityIdentifier("twitch-account-restoring")
  }
}

struct TwitchICloudSyncControls: View {
  let sync: TwitchAccountSync
  @State private var confirmReplace = false
  @State private var confirmSignOut = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("iCloud sign-in").font(.headline)
      Text(sync.status).foregroundStyle(.secondary)
      if let error = sync.errorMessage { Text(error).font(.callout) }
      Text("Your Twitch and rewards connections sync privately between devices using the same Apple Account. Twitch may occasionally require approval again.")
        .font(.caption).foregroundStyle(.secondary)
      if !sync.isSignedOutLocally {
        Button("Sync now") {
          Task { await sync.synchronize() }
        }
        .buttonStyle(.bordered)
        .disabled(sync.isBusy || sync.isRestoringAccount)
      }
      if sync.hasAccountConflict {
        Button("Use the account saved in iCloud") {
          Task { await sync.useICloudAccount() }
        }
        .disabled(sync.isBusy)
        Button("Replace iCloud connection with this device") { confirmReplace = true }
          .disabled(sync.isBusy)
      }
      Button("Sign out everywhere", role: .destructive) { confirmSignOut = true }
        .disabled(sync.isBusy || sync.isRestoringAccount)
      if sync.isBusy { ProgressView("Syncing account") }
    }
    .confirmationDialog("Replace the Twitch connection on your other devices?", isPresented: $confirmReplace) {
      Button("Replace iCloud connection", role: .destructive) { Task { await sync.replaceICloudAccount() } }
    }
    .confirmationDialog("Sign out of Twitch and rewards everywhere?", isPresented: $confirmSignOut) {
      Button("Sign out everywhere", role: .destructive) { Task { await sync.signOutAllDevices() } }
    }
  }
}
