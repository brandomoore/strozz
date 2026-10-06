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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @State private var selectedChannel: FollowedChannel?
  @State private var playbackModel = MobilePlaybackModel()
  @State private var preview = MobileHomePreview()
  @State private var tab = 0

  var body: some View {
    let palette = theme.theme.palette(systemColorScheme: colorScheme)
    let previewsEnabled = tab == 0 && selectedChannel == nil && !playbackModel.isActive && scenePhase == .active
    TabView(selection: $tab) {
      NavigationStack {
        MobileHomeView(preview: preview, previewsEnabled: previewsEnabled,
                       onSelect: select, onAccount: { tab = 2 })
      }
      .tabItem { Label { Text("Home") } icon: { Image("tb-home") } }
      .tag(0)

      NavigationStack {
        MobileBrowseView(onSelect: select)
      }
      .tabItem { Label { Text("Browse") } icon: { Image("tb-layout-grid") } }
      .tag(1)

      NavigationStack { MobileAccountView() }
        .tabItem { Label { Text("Account") } icon: { Image("tb-user-circle") } }
        .tag(2)
    }
    .environment(\.themePalette, palette)
    .fullScreenCover(item: $selectedChannel, onDismiss: { playbackModel.stop() }) { channel in
      MobilePlayerView(channel: channel, model: playbackModel)
        .environment(\.themePalette, palette)
    }
  }

  private func select(_ channel: FollowedChannel) {
    preview.stop()
    playbackModel.stop()
    playbackModel = MobilePlaybackModel()
    selectedChannel = channel
  }
}
