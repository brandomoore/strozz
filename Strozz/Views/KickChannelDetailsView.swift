import SwiftUI

struct KickChannelDetailsView: View {
  let slug: String
  let onWatch: (FollowedChannel) -> Void
  @State private var channel: KickChannel?
  @State private var errorMessage: String?
  @State private var loading = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label { Text(channel?.displayName ?? slug).font(.title.bold()) } icon: {
          Icon(glyph: .brandKick, size: 32)
        }
        if loading { ProgressView("Loading channel") }
        if let channel {
          Text(channel.isLive ? "Live on Kick" : "Offline").foregroundStyle(.secondary)
          if channel.isLive {
            Text(channel.title).font(.headline)
            Text(channel.category).foregroundStyle(.secondary)
            Button("Watch live") { onWatch(channel.followedChannel) }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("kick-watch-live")
          }
          Text("Past broadcasts aren't available for Kick in Strozz.").foregroundStyle(.secondary)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        Button("Refresh") { Task { await refresh() } }.disabled(loading)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(channel?.displayName ?? slug)
    .task(id: slug) { await refresh() }
  }

  private func refresh() async {
    loading = true
    defer { loading = false }
    do {
      let value = try await KickPlaybackService.channel(slug)
      guard !Task.isCancelled else { return }
      channel = value
      errorMessage = nil
    } catch {
      if !Task.isCancelled { errorMessage = error.localizedDescription }
    }
  }
}
