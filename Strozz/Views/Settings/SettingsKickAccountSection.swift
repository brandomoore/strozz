import SwiftUI

struct SettingsKickAccountSection: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette
  @State private var disconnect = false

  var body: some View {
    let store = environment.kickFollows
    VStack(alignment: .leading, spacing: 16) {
      Label { Text("Kick").font(.title3.bold()) } icon: { Icon(glyph: .brandKick, size: 28) }
      if let account = store.document?.account {
        Text(account.username).font(.headline)
        Text("\(store.document?.follows.count ?? 0) followed channels")
          .foregroundStyle(.secondary)
        if let date = store.document?.importedAt {
          Text("Follows imported \(date, format: .dateTime.month(.abbreviated).day().hour().minute())")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("Following updates automatically from Strozz on your iPhone or iPad. Open the mobile app after changing who you follow.")
          .font(.callout).foregroundStyle(.secondary)
        HStack {
          Button("Sync now") { Task { await store.synchronize() } }
            .disabled(store.isBusy)
          Button("Disconnect Kick", role: .destructive) { disconnect = true }
            .disabled(store.isBusy)
        }
        .settingsProminentActionButtonStyle()
      } else {
        HStack(spacing: 28) {
          BrandQRCodeView(payload: "strozz://connect/kick", logoName: "tb-brand-kick",
            moduleColor: palette.chromeOnOpaque, size: 180)
          VStack(alignment: .leading, spacing: 10) {
            Text("Connect on your iPhone or iPad").font(.headline)
            Text("With Strozz installed, scan this code to sign in to Kick. Or open Account in the mobile app and choose Connect Kick.")
            Text("Use the same Apple Account on both devices. Your follows appear here automatically; your password and website session stay on your mobile device.")
              .foregroundStyle(.secondary)
          }
          .font(.callout)
        }
        Button("Check connection") { Task { await store.synchronize() } }
          .settingsProminentActionButtonStyle()
          .disabled(store.isBusy)
      }
      if store.isBusy { ProgressView("Syncing Kick follows") }
      if let error = store.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
    }
    .padding(20)
    .settingsGlassPanel(disabled: glassDisabled)
    .focusSection()
    .accessibilityIdentifier("settings-kick-account")
    .confirmationDialog("Disconnect Kick on all your Strozz devices?", isPresented: $disconnect,
                        titleVisibility: .visible) {
      Button("Disconnect Kick", role: .destructive) {
        Task {
          do { try await store.disconnect() } catch { store.report(error) }
        }
      }
    } message: { Text("This does not unfollow anyone on Kick.") }
  }
}
