import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct StrozzMobileApp: App {
  @State private var auth = TwitchAuthSession()
  @State private var theme = ThemeManager()

  init() {
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ImageCacheConfigurator.configure()
    ChatSyncDefaultsMigration.runIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      MobileRootView()
        .environment(auth)
        .environment(theme)
        .preferredColorScheme(theme.theme.preferredColorScheme)
        .task {
          auth.restore()
          auth.startSessionValidation()
        }
    }
  }
}

struct MobileRootView: View {
  @Environment(ThemeManager.self) private var theme
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedChannel: FollowedChannel?
  @State private var playbackModel = MobilePlaybackModel()

  var body: some View {
    let palette = theme.theme.palette(systemColorScheme: colorScheme)
    TabView {
      NavigationStack {
        MobileHomeView(onSelect: select)
      }
      .tabItem { Label { Text("Live") } icon: { Image("tb-home") } }

      NavigationStack {
        MobileFollowingView(onSelect: select)
          .id(auth.userID)
      }
      .tabItem { Label { Text("Following") } icon: { Image("tb-heart") } }

      NavigationStack {
        MobileBrowseView(onSelect: select)
      }
      .tabItem { Label { Text("Browse") } icon: { Image("tb-layout-grid") } }

      NavigationStack { MobileAccountView() }
        .tabItem { Label { Text("Account") } icon: { Image("tb-user-circle") } }
    }
    .environment(\.themePalette, palette)
    .fullScreenCover(item: $selectedChannel, onDismiss: { playbackModel.stop() }) { channel in
      MobilePlayerView(channel: channel, model: playbackModel)
        .environment(\.themePalette, palette)
    }
  }

  private func select(_ channel: FollowedChannel) {
    playbackModel.stop()
    playbackModel = MobilePlaybackModel()
    selectedChannel = channel
  }
}
