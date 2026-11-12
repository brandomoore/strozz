#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct StreamCategoryFixture: View {
  @State private var path: [TwitchCategory] = []
  @State private var returnRefresh = PlaybackReturnRefreshCoordinator()
  @State private var watched = ""
  @FocusState private var focused: Bool

  private let channel = FollowedChannel(id: "category-fixture", login: "categoryfixture",
    displayName: "Category fixture", title: "Context menu navigation", gameName: "Just Chatting",
    viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)

  var body: some View {
    NavigationStack(path: $path) {
      VStack {
        StreamChannelCard(channel: channel, isFocused: focused,
          onWatch: { watched = $0.login }, onGoToChannel: { _ in })
          .frame(width: 440)
          .focusable()
          .focused($focused)
          .accessibilityIdentifier("category-fixture-card")
        Text(watched).accessibilityIdentifier("category-fixture-watched")
      }
      .task { focused = true }
    }
    .environment(returnRefresh)
    .environment(\.streamPreviewsEnabled, false)
  }
}
#endif
