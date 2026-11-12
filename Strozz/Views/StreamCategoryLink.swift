import SwiftUI

struct StreamCategoryLink: View {
  let channel: FollowedChannel
  let onWatch: (FollowedChannel) -> Void

  var body: some View {
    if let target = StreamCategoryTarget(channel: channel) {
      NavigationLink {
        StreamCategoryDestination(target: target, onWatch: onWatch)
      } label: {
        Label {
          Text("Go to \(target.name)", comment: "Stream context menu action; the variable is the game or category name.")
        } icon: {
          Icon(glyph: .layoutGrid)
        }
      }
      .accessibilityIdentifier("stream-go-to-category-\(channel.channelKey)")
    }
  }
}

private struct StreamCategoryDestination: View {
  let target: StreamCategoryTarget
  let onWatch: (FollowedChannel) -> Void
  @State private var category: TwitchCategory?
  @State private var errorMessage: String?
  @State private var attempt = 0
  @State private var channelPageTarget: ChannelPageTarget?
  @State private var pendingWatch: FollowedChannel?
  #if os(tvOS)
  @Environment(PlaybackReturnRefreshCoordinator.self) private var playbackReturnRefresh

  private func watch(_ channel: FollowedChannel) {
    playbackReturnRefresh.preservingOrigin { onWatch(channel) }
  }
  #endif

  var body: some View {
    Group {
      if let category {
        #if os(tvOS)
        CategoryStreamsView(category: category,
          selectedChannel: Binding(get: { nil }, set: { if let channel = $0 { watch(channel) } }),
          channelPageTarget: $channelPageTarget)
        .fullScreenCover(item: $channelPageTarget, onDismiss: {
          if let channel = pendingWatch {
            pendingWatch = nil
            watch(channel)
          } else {
            playbackReturnRefresh.playerDidDismiss {}
          }
        }) { target in
          ChannelPageView(target: target) { channel in
            pendingWatch = channel
            channelPageTarget = nil
          }
        }
        #else
        MobileCategoryStreamsView(category: category, onSelect: onWatch)
        #endif
      } else if let errorMessage {
        VStack(spacing: 16) {
          Text(errorMessage).foregroundStyle(.secondary)
          Button("Retry") { attempt += 1 }
        }
        .padding()
      } else {
        ProgressView("Loading category")
      }
    }
    .navigationTitle(target.name)
    .task(id: attempt) {
      errorMessage = nil
      do {
        let resolved = try await StreamCategoryService().resolve(target)
        try Task.checkCancellation()
        category = resolved
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = String(localized: "Couldn't load this category. \(error.localizedDescription)")
      }
    }
  }
}
