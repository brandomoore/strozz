import SDWebImage
import SDWebImageWebPCoder
import SwiftUI

@main
struct StrozzMobileApp: App {
  @State private var auth = TwitchAuthSession()
  @State private var theme = ThemeManager()
  @State private var rewards = TwitchWatchRewardsSession()
  @State private var accountSync = TwitchAccountSync()

  init() {
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ImageCacheConfigurator.configure()
    ChatSyncDefaultsMigration.runIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "chat" {
        MobileChatLayoutFixture()
      } else {
        appContent
      }
      #else
      appContent
      #endif
    }
  }

  private var appContent: some View {
    MobileRootView(accountID: auth.userID ?? "anonymous")
      .id(auth.userID ?? "anonymous")
      .environment(auth)
      .environment(theme)
      .environment(rewards)
      .environment(accountSync)
      .preferredColorScheme(theme.theme.preferredColorScheme)
      .task {
        await accountSync.start(auth: auth, rewards: rewards)
      }
      .onChange(of: auth.userID) { _, userID in rewards.accountChanged(to: userID) }
      #if DEBUG
      .task { await TwitchCloudProbe.runIfRequested() }
      #endif
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
  @State private var history: WatchHistoryService
  @State private var vodProgress: MobileVODProgressStore
  @State private var homeProfile: FollowedChannel?
  @State private var browseProfile: FollowedChannel?
  @State private var returnRefresh = PlaybackReturnRefreshCoordinator()

  init(accountID: String = "anonymous") {
    _history = State(initialValue: WatchHistoryService(storageKey: PersistenceKey.mobileWatchHistory(accountID: accountID)))
    _vodProgress = State(initialValue: MobileVODProgressStore(accountID: accountID))
  }

  var body: some View {
    let palette = theme.theme.palette(systemColorScheme: colorScheme)
    let previewsEnabled = tab == 0 && selectedChannel == nil && !playbackModel.isActive && scenePhase == .active
    TabView(selection: $tab) {
      NavigationStack {
        MobileHomeView(preview: preview, previewsEnabled: previewsEnabled, history: history,
                       onSelect: select, onProfile: { homeProfile = $0 }, onAccount: { tab = 2 })
          .navigationDestination(item: $homeProfile) { MobileChannelProfileView(channel: $0, onLive: select) }
      }
      .tabItem { Label { Text("Home") } icon: { Image("tb-home") } }
      .tag(0)

      NavigationStack {
        MobileBrowseView(onSelect: select)
          .navigationDestination(item: $browseProfile) { MobileChannelProfileView(channel: $0, onLive: select) }
      }
      .tabItem { Label { Text("Browse") } icon: { Image("tb-layout-grid") } }
      .tag(1)

      NavigationStack { MobileAccountView() }
        .tabItem { Label { Text("Account") } icon: { Image("tb-user-circle") } }
        .tag(2)
    }
    .environment(\.themePalette, palette)
    .environment(history)
    .environment(vodProgress)
    .environment(returnRefresh)
    .fullScreenCover(item: $selectedChannel, onDismiss: {
      playbackModel.stop()
      returnRefresh.refreshThumbnails()
    }) { channel in
      MobilePlayerView(channel: channel, model: playbackModel)
        .environment(\.themePalette, palette)
    }
    .onChange(of: homeProfile) { previous, current in
      if previous != nil, current == nil { returnRefresh.refreshThumbnails() }
    }
    .onChange(of: browseProfile) { previous, current in
      if previous != nil, current == nil { returnRefresh.refreshThumbnails() }
    }
    .onDisappear { preview.stop() }
  }

  private func select(_ channel: FollowedChannel) {
    preview.stop()
    guard channel.isLive else {
      if tab == 0 { homeProfile = channel } else { browseProfile = channel }
      return
    }
    history.record(channel)
    playbackModel.stop()
    playbackModel = MobilePlaybackModel()
    selectedChannel = channel
  }
}
