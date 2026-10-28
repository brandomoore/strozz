import SDWebImage
import SDWebImageWebPCoder
import SwiftUI
import CloudKit

@main
struct StrozzMobileApp: App {
  @State private var auth = TwitchAuthSession()
  @State private var theme = ThemeManager()
  @State private var rewards = TwitchWatchRewardsSession()
  @State private var accountSync = TwitchAccountSync()
  @State private var playback = MobilePlaybackSession()
  @State private var kickFollows: KickFollowingStore
  @State private var kickDiscovery: KickDiscoveryService
  @State private var kickSignIn = MobileKickSignIn()

  init() {
    let kickFollows = KickFollowingStore()
    _kickFollows = State(initialValue: kickFollows)
    _kickDiscovery = State(initialValue: KickDiscoveryService(follows: kickFollows))
    PlaybackTelemetrySentry.start()
    SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    ImageCacheConfigurator.configure()
    ChatSyncDefaultsMigration.runIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
      if ProcessInfo.processInfo.environment["STROZZ_FOLLOW_FIXTURE"] == "1" {
        #if targetEnvironment(simulator)
        ChannelFollowFixture()
        #else
        appContent
        #endif
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "chat" {
        MobileChatLayoutFixture()
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "emotes" {
        MobileEmoteInspectionFixture()
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "composer" {
        MobileChatComposerFixture()
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "emote-menu" {
        MobileEmoteMenuFixture()
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "player-chrome" {
        MobilePlayerLayoutFixture()
      } else if ProcessInfo.processInfo.environment["STROZZ_LAYOUT_FIXTURE"] == "navigation" {
        MobileNavigationLayoutFixture()
      } else {
        appContent
      }
      #else
      appContent
      #endif
    }
  }

  private var appContent: some View {
    @Bindable var signIn = kickSignIn
    return MobileRootView(accountID: auth.userID ?? "anonymous",
      initialTab: initialTab)
      .id(auth.userID ?? "anonymous")
      .environment(auth)
      .environment(theme)
      .environment(rewards)
      .environment(accountSync)
      .environment(playback)
      .environment(kickFollows)
      .environment(kickDiscovery)
      .environment(kickSignIn)
      .onOpenURL { url in
        if url.scheme == "strozz", url.host == "connect", url.path == "/kick" {
          kickSignIn.connect(using: kickFollows)
        }
      }
      .sheet(isPresented: $signIn.isPresented) { MobileKickSignInSheet(signIn: signIn) }
      .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
        kickFollows.accountChanged()
        kickDiscovery.accountChanged()
        Task { await kickSignIn.clearWebsiteSession(); await kickFollows.synchronize() }
      }
      .preferredColorScheme(theme.theme.preferredColorScheme)
      .task {
        await accountSync.start(auth: auth, rewards: rewards)
      }
      .onChange(of: auth.userID) { _, userID in
        playback.close()
        rewards.accountChanged(to: userID)
      }
      #if DEBUG
      .task { await TwitchCloudProbe.runIfRequested() }
      #endif
  }

  private var initialTab: Int {
    #if DEBUG
    let tab = Int(ProcessInfo.processInfo.environment["STROZZ_UI_INITIAL_TAB"] ?? "") ?? 0
    return (0...2).contains(tab) ? tab : 0
    #else
    0
    #endif
  }
}

struct MobileRootView: View {
  @Environment(ThemeManager.self) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(MobilePlaybackSession.self) private var playback
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var accountSync
  @Environment(TwitchWatchRewardsSession.self) private var rewards
  @Environment(KickFollowingStore.self) private var kickFollows
  @Environment(KickDiscoveryService.self) private var kick
  @Environment(MobileKickSignIn.self) private var kickSignIn
  @State private var preview = MobileHomePreview()
  @State private var tab = 0
  @State private var history: WatchHistoryService
  @State private var vodProgress: MobileVODProgressStore
  @State private var homeProfile: FollowedChannel?
  @State private var browseProfile: FollowedChannel?
  @State private var returnRefresh = PlaybackReturnRefreshCoordinator()
  @State private var follows = FollowedChannelsService()
  @State private var sidebarVisibility = NavigationSplitViewVisibility.all
  @State private var compactColumn = NavigationSplitViewColumn.detail

  private enum PlayerVisibility {
    case closed, expanded, miniPlayer
  }

  private var playerVisibility: PlayerVisibility {
    playback.channel == nil ? .closed : (playback.isExpanded ? .expanded : .miniPlayer)
  }

  init(accountID: String = "anonymous", initialTab: Int = 0) {
    _tab = State(initialValue: initialTab)
    _history = State(initialValue: WatchHistoryService(storageKey: PersistenceKey.mobileWatchHistory(accountID: accountID)))
    _vodProgress = State(initialValue: MobileVODProgressStore(accountID: accountID))
  }

  var body: some View {
    let palette = theme.theme.palette(systemColorScheme: colorScheme)
    let previewsEnabled = tab == 0 && playback.channel == nil && scenePhase == .active
    let isTablet = UIDevice.current.userInterfaceIdiom == .pad
    let showsSidebar = isTablet && horizontalSizeClass == .regular && sidebarVisibility != .detailOnly
    browsingContent(previewsEnabled: previewsEnabled, isTablet: isTablet, showsSidebar: showsSidebar)
    .allowsHitTesting(!playback.isExpanded)
    .accessibilityHidden(playback.isExpanded)
    .overlay {
      if let channel = playback.channel {
        MobilePlayerView(channel: channel, session: playback)
          .id(ObjectIdentifier(playback.model))
      }
    }
    .environment(\.themePalette, palette)
    .environment(history)
    .environment(vodProgress)
    .environment(follows)
    .environment(returnRefresh)
    .task(id: scenePhase == .active && playback.channel == nil) {
      guard scenePhase == .active, playback.channel == nil else { return }
      while !Task.isCancelled {
        await kickFollows.synchronize()
        await kickSignIn.refreshIfNeeded(using: kickFollows)
        kick.applyRoster()
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
      }
    }
    .onChange(of: kickFollows.document) { _, _ in kick.applyRoster() }
    .onChange(of: playerVisibility) { previous, current in
      if previous == .expanded && current != .expanded
        || previous == .miniPlayer && current == .closed {
        returnRefresh.refreshThumbnails()
        compactColumn = .detail
      }
    }
    .onChange(of: homeProfile) { previous, current in
      if previous != nil, current == nil { returnRefresh.refreshThumbnails() }
    }
    .onChange(of: browseProfile) { previous, current in
      if previous != nil, current == nil { returnRefresh.refreshThumbnails() }
    }
    .onDisappear { preview.stop() }
    .onChange(of: tab) { _, _ in compactColumn = .detail }
    .task(id: auth.isAuthenticated ? auth.userID : nil) {
      follows.accountChanged(using: auth)
      if auth.isAuthenticated { await follows.refresh(using: auth) }
    }
    .onChange(of: auth.accessToken) { _, _ in
      guard auth.isAuthenticated, follows.errorMessage != nil, !follows.isRefreshing else { return }
      Task { await follows.refresh(using: auth) }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in playback.sceneChanged(phase) }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        await accountSync.synchronize()
        await auth.validateSessionIfNeeded()
        guard scenePhase == .active, !Task.isCancelled else { return }
        if isTablet, tab != 0, auth.isAuthenticated, follows.needsRefresh(staleAfter: 60) {
          await follows.refresh(using: auth)
        }
        returnRefresh.refreshThumbnails()
      }
    }
    .task(id: playback.channel?.channelKey) { await playback.trackWatch(auth: auth, rewards: rewards) }
  }

  @ViewBuilder
  private func browsingContent(previewsEnabled: Bool, isTablet: Bool, showsSidebar: Bool) -> some View {
    #if DEBUG
    if ProcessInfo.processInfo.environment["STROZZ_KICK_UI_FIXTURE"] == "1" {
      KickDirectoryView(initialQuery: ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc")
    } else {
      rootTabs(previewsEnabled: previewsEnabled, isTablet: isTablet, showsSidebar: showsSidebar)
    }
    #else
    rootTabs(previewsEnabled: previewsEnabled, isTablet: isTablet, showsSidebar: showsSidebar)
    #endif
  }

  private func rootTabs(previewsEnabled: Bool, isTablet: Bool, showsSidebar: Bool) -> some View {
    MobileRootTabs(selection: $tab, homeProfile: $homeProfile, browseProfile: $browseProfile,
      sidebarVisibility: $sidebarVisibility, compactColumn: $compactColumn,
      preview: preview, previewsEnabled: previewsEnabled, history: history, follows: follows,
      isTablet: isTablet, showsSidebar: showsSidebar, isInteractive: !playback.isExpanded, onSelect: select)
  }

  private func select(_ channel: FollowedChannel) {
    preview.stop()
    guard channel.isLive else {
      if tab == 0 { homeProfile = channel } else { browseProfile = channel }
      return
    }
    history.record(channel)
    playback.select(channel)
  }
}
