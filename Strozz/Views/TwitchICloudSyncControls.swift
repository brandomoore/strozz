import SwiftUI

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
      Button(sync.isSignedOutLocally ? "Use iCloud connection" : "Sync now") {
        Task { await sync.useICloudAccount() }
      }
      .buttonStyle(.bordered)
      .disabled(sync.isBusy)
      if sync.hasAccountConflict {
        Button("Replace iCloud connection with this device") { confirmReplace = true }
          .disabled(sync.isBusy)
      }
      Button("Sign out all synced devices", role: .destructive) { confirmSignOut = true }
        .disabled(sync.isBusy)
      if sync.isBusy { ProgressView("Syncing account") }
    }
    .confirmationDialog("Replace the Twitch connection on your other devices?", isPresented: $confirmReplace) {
      Button("Replace iCloud connection", role: .destructive) { Task { await sync.replaceICloudAccount() } }
    }
    .confirmationDialog("Sign out of Twitch and rewards on all synced devices?", isPresented: $confirmSignOut) {
      Button("Sign out all devices", role: .destructive) { Task { await sync.signOutAllDevices() } }
    }
  }
}
