import SwiftUI

enum MobileHomeFeed: Hashable {
  case following, live

  static func visibleFollows(
    _ channels: [FollowedChannel], authenticated: Bool, isDemo: Bool, category: TwitchCategory?
  ) -> [FollowedChannel] {
    guard authenticated, !isDemo else { return [] }
    return channels.filter { channel in
      channel.isLive && (category.map {
        channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame
      } ?? true)
    }
  }

  static func directory(_ channels: [FollowedChannel], authenticated: Bool, category: TwitchCategory?) -> [FollowedChannel] {
    guard authenticated else { return [] }
    return channels.filter { channel in
      category.map { channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame } ?? true
    }
  }

  static func homeChannels(follows: [FollowedChannel], watched: [FollowedChannel],
                           recommendations: [FollowedChannel], history: [WatchHistoryEntry],
                           category: TwitchCategory?) -> [FollowedChannel] {
    let counts = Dictionary(history.map { ($0.channelKey, $0.watchCount) }, uniquingKeysWith: max)
    var seen = Set<String>()
    let familiar = (follows + watched).filter { $0.isLive && seen.insert($0.channelKey).inserted }
      .sorted {
        let lhs = counts[$0.channelKey] ?? 0, rhs = counts[$1.channelKey] ?? 0
        return lhs == rhs ? ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) : lhs > rhs
      }
    let discovery = recommendations.filter { $0.isLive && seen.insert($0.channelKey).inserted }
    return (familiar + discovery).filter { channel in
      category.map { channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame } ?? true
    }
  }
}

enum MobileFollowedShortcutCount {
  static let limit = 6

  static func cached(for accountID: String?, defaults: UserDefaults = .standard) -> Int {
    guard let accountID,
          let count = defaults.object(forKey: PersistenceKey.mobileLiveFollowedCount(accountID: accountID)) as? Int
    else { return limit }
    return min(limit, max(0, count))
  }

  static func remember(_ channels: [FollowedChannel], for accountID: String?, isDemo: Bool,
                       errorMessage: String?, defaults: UserDefaults = .standard) -> Int? {
    guard let accountID, !isDemo, errorMessage == nil else { return nil }
    let count = channels.lazy.filter(\.isLive).prefix(limit).count
    let key = PersistenceKey.mobileLiveFollowedCount(accountID: accountID)
    if defaults.object(forKey: key) as? Int != count { defaults.set(count, forKey: key) }
    return count
  }

  static func rows(visibleCount: Int, isLoading: Bool, cachedCount: Int, accessibilitySize: Bool) -> Int {
    let count = visibleCount == 0 && isLoading ? cachedCount : visibleCount
    let columns = accessibilitySize ? 1 : 2
    return (min(limit, max(0, count)) + columns - 1) / columns
  }
}

struct MobileHomeView: View {
  let preview: MobileHomePreview
  let previewsEnabled: Bool
  let history: WatchHistoryService
  let follows: FollowedChannelsService
  var usesTabletNavigation = false
  var showsFollowedShortcuts = true
  let onSelect: (FollowedChannel) -> Void
  let onProfile: (FollowedChannel) -> Void
  let onAccount: () -> Void
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync
  @Environment(KickDiscoveryService.self) private var kick
  @Environment(\.themePalette) private var palette
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(MobileVODProgressStore.self) private var vodProgress
  @Environment(PlaybackReturnRefreshCoordinator.self) private var returnRefresh: PlaybackReturnRefreshCoordinator?
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedEnabled = true
  @State private var feed = MobileHomeFeed.live
  @State private var category: TwitchCategory?
  @State private var recommendations = RecommendationsService()
  @State private var categoryStreams = BrowseService()
  @State private var followedSkeletonCount = MobileFollowedShortcutCount.limit
  @State private var affinity = StreamerAffinityService()
  @State private var personalChannels: [FollowedChannel] = []
  @State private var selectedVideo: MobileVODSelection?
  @State private var personalRefreshID = UUID()
  @State private var personalLoading = true
  @State private var personalError: String?
  @State private var hasAppeared = false

  private var shouldPreview: Bool { previewsEnabled && feed == .live && selectedVideo == nil }
  private var liveCategoryID: String? { feed == .live ? category?.id : nil }
  private var personalFeed: Bool {
    personalizedEnabled && (auth.isAuthenticated || kick.follows.isConnected || !history.entries.isEmpty)
  }
  private var personalizationID: String {
    "\(auth.userID ?? "")|\(follows.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)|\(personalizedEnabled)|"
      + "\(kick.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)|"
      + history.entries.map { "\($0.channelKey):\($0.watchCount)" }.joined(separator: ",")
  }
  private var allLiveFollows: [FollowedChannel] {
    kick.mergedFollowing(
      MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
        isDemo: follows.isUsingDemoData, category: nil), liveOnly: true)
  }
  private var visibleFollows: [FollowedChannel] {
    allLiveFollows.filter { channel in category.map {
        channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame
      } ?? true }
  }
  private var shortcutsLoading: Bool {
    !kick.follows.isConnected
      && (sync.isRestoringAccount || (auth.isAuthenticated && follows.lastUpdatedAt == nil && follows.errorMessage == nil))
  }
  private var homeChannels: [FollowedChannel] {
    let base = personalFeed ? personalChannels
      : category == nil ? recommendations.channels : categoryStreams.categoryStreams
    let merged = kick.mergedRecommendations(base, includeNew: false)
    return (personalFeed ? merged : KickUnifiedFeed.sortedByViewers(merged))
      .filter { channel in
      category.map { channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame } ?? true
    }
  }

  private struct KickRefreshIdentity: Equatable {
    let isActive: Bool
    let importedAt: Date?
  }

  var body: some View {
    let shortcutChannels = visibleFollows
    let shortcutRows = MobileFollowedShortcutCount.rows(
      visibleCount: shortcutChannels.count, isLoading: shortcutsLoading,
      cachedCount: followedSkeletonCount, accessibilitySize: typeSize.isAccessibilitySize)
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: usesTabletNavigation ? 8 : 16, pinnedViews: [.sectionHeaders]) {
            if !usesTabletNavigation {
              Text("Strozz")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("mobile-home-heading")
                .padding(.horizontal)
                .id("mobile-home-top")
            }
            Section {
              MobileHomeFilters(categories: recommendations.categories, selection: $category)
              if feed == .following {
                MobileFollowingContent(
                  authenticated: auth.isAuthenticated || kick.follows.isConnected,
                  isRestoringAccount: sync.isRestoringAccount && !kick.follows.isConnected,
                  channels: MobileHomeFeed.directory(kick.mergedFollowing(follows.directory),
                    authenticated: auth.isAuthenticated || kick.follows.isConnected, category: category),
                  isLoading: auth.isAuthenticated && (follows.isLoadingDirectory
                    || (follows.directoryLoadedAt == nil && follows.directoryErrorMessage == nil)),
                  errorMessage: (auth.isAuthenticated ? follows.directoryErrorMessage : nil)
                    ?? kick.errorMessage ?? (kick.follows.isConnected ? kick.follows.errorMessage : nil),
                  filtered: category != nil, onAccount: onAccount,
                  onRetry: {
                    Task {
                      if auth.isAuthenticated { await follows.loadDirectory(using: auth, force: true) }
                      await kick.follows.synchronize()
                      await kick.refresh(twitch: follows.directory + recommendations.channels, force: true)
                    }
                  },
                  onSelect: onSelect, onProfile: onProfile, resumeEntries: vodProgress.entries,
                  onResume: { selectedVideo = $0 })
                  .padding(.horizontal)
              } else {
                if category == nil, !vodProgress.entries.isEmpty {
                  MobileContinueWatchingSection(entries: Array(vodProgress.entries.prefix(4))) { selectedVideo = $0 }
                    .padding(.horizontal)
                }
                if showsFollowedShortcuts {
                  MobileFollowedShortcuts(channels: shortcutChannels, onSelect: onSelect,
                                         onSeeAll: { feed = .following },
                                         isLoading: shortcutsLoading,
                                         authenticated: auth.isAuthenticated || kick.follows.isConnected,
                                         isRestoringAccount: sync.isRestoringAccount && !kick.follows.isConnected,
                                         skeletonCount: followedSkeletonCount)
                    .padding(.horizontal)
                }
                if !usesTabletNavigation {
                  Text(personalFeed ? "For you" : "Popular live channels")
                    .font(.title3.bold()).accessibilityAddTraits(.isHeader).padding(.horizontal)
                }
                if personalFeed, auth.isAuthenticated, let error = follows.errorMessage {
                  MobileStatusView(message: error) { Task { await follows.refresh(using: auth) } }
                    .padding(.horizontal)
                }
                if let error = kick.errorMessage {
                  MobileStatusView(message: error) {
                    Task { await kick.refresh(twitch: follows.channels + recommendations.channels, force: true) }
                  }
                  .padding(.horizontal)
                }
                MobileLiveFeedContent(
                  channels: homeChannels,
                  isLoading: personalFeed ? (personalLoading || (auth.isAuthenticated
                    && (follows.isRefreshing || (follows.lastUpdatedAt == nil && follows.errorMessage == nil))))
                    : (category == nil ? recommendations.isLoading || recommendations.lastUpdatedAt == nil
                      : categoryStreams.isLoadingStreams),
                  errorMessage: personalFeed ? personalError
                    : (category == nil ? recommendations.errorMessage : categoryStreams.streamsErrorMessage),
                  preview: preview, onSelect: onSelect, onRetry: { Task { await refreshLive() } })
                  .padding(.horizontal)
              }
            } header: {
              if !usesTabletNavigation {
                MobileHomeFeedTabs(feed: $feed)
                  .padding(.horizontal)
                  .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
              }
            }
            .id(usesTabletNavigation ? "mobile-home-top" : "mobile-home-feed")
          }
          .animation(reduceMotion || feed != .live ? nil : .easeInOut(duration: 0.22), value: shortcutRows)
          .padding(.top, usesTabletNavigation ? 0 : 8)
          .padding(.bottom)
          .coordinateSpace(name: "mobile-home-content")
        }
        // Draw beneath the floating tab bar, but let the final card scroll clear
        // of it. Clipping still protects the status-bar area at the top.
        .contentMargins(.bottom, viewport.safeAreaInsets.bottom, for: .scrollContent)
        .clipped()
        .accessibilityIdentifier("mobile-home-scroll")
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, visible in
          preview.updateViewport(visible)
        }
        .onChange(of: feed) { _, _ in proxy.scrollTo("mobile-home-top", anchor: .top) }
        .refreshable {
          async let kickSynced: Void = kick.follows.synchronize()
          if feed == .following {
            if auth.isAuthenticated { await follows.loadDirectory(using: auth, force: true) }
          } else {
            await refreshLive()
            if auth.isAuthenticated { await follows.refresh(using: auth) }
          }
          await kickSynced
          await kick.refresh(twitch: (feed == .following ? follows.directory : follows.channels)
            + recommendations.channels, force: true)
        }
      }
      .ignoresSafeArea(.container, edges: .bottom)
    }
    .onChange(of: shouldPreview, initial: true) { _, enabled in preview.setEnabled(enabled) }
    .onAppear { preview.setEnabled(shouldPreview) }
    .onDisappear { preview.stop() }
    .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
    .navigationTitle(usesTabletNavigation ? "" : "Home")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(usesTabletNavigation ? .visible : .hidden, for: .navigationBar)
    .toolbar {
      if usesTabletNavigation {
        if #available(iOS 26.0, *) {
          ToolbarItem(placement: .topBarLeading) {
            MobileHomeFeedTabs(feed: $feed).fixedSize(horizontal: true, vertical: false)
          }
          .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .topBarLeading) {
            MobileHomeFeedTabs(feed: $feed).fixedSize(horizontal: true, vertical: false)
          }
        }
      }
    }
    .onChange(of: auth.userID, initial: true) { _, accountID in
      followedSkeletonCount = MobileFollowedShortcutCount.cached(for: accountID)
    }
    .onChange(of: follows.lastUpdatedAt) { _, updatedAt in
      guard updatedAt != nil, auth.isAuthenticated,
            let count = MobileFollowedShortcutCount.remember(
              follows.channels, for: auth.userID, isDemo: follows.isUsingDemoData,
              errorMessage: follows.errorMessage)
      else { return }
      followedSkeletonCount = count
    }
    .task { if recommendations.lastUpdatedAt == nil { await recommendations.refresh() } }
    .task(id: KickRefreshIdentity(isActive: previewsEnabled, importedAt: kick.follows.document?.importedAt)) {
      guard previewsEnabled else { return }
      while !Task.isCancelled {
        await kick.refresh(twitch: follows.channels + recommendations.channels)
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
      }
    }
    .task(id: recommendations.channels.map(\.channelKey)) {
      guard previewsEnabled, !recommendations.channels.isEmpty else { return }
      await kick.refresh(twitch: follows.channels + recommendations.channels, force: true)
    }
    .task(id: returnRefresh?.thumbnailRevision) {
      guard hasAppeared else { hasAppeared = true; return }
      await refreshAfterReturn()
    }
    .task(id: liveCategoryID) {
      if feed == .live, !personalFeed, let category {
        await categoryStreams.loadStreams(for: category, mixCategoryPlatforms: true)
      }
    }
    .task(id: "\(auth.userID ?? "")-\(feed == .following)") {
      guard feed == .following else { return }
      if auth.isAuthenticated { await follows.loadDirectory(using: auth) }
      await kick.refresh(twitch: follows.directory + recommendations.channels,
        force: true, preservingRecommendations: true)
    }
    .task(id: personalizationID) { await refreshPersonalized() }
    .fullScreenCover(item: $selectedVideo, onDismiss: {
      returnRefresh?.refreshThumbnails()
    }) { MobileVODPlayerView(selection: $0) }
  }

  private func refreshAfterReturn() async {
    if auth.isAuthenticated {
      await follows.refresh(using: auth)
      if feed == .following { await follows.loadDirectory(using: auth, force: true) }
    }
    guard !Task.isCancelled else { return }
    await refreshLive()
  }

  private func refreshLive() async {
    if personalFeed {
      await recommendations.refresh()
      await refreshPersonalized()
    }
    else if let category { await categoryStreams.loadStreams(for: category, mixCategoryPlatforms: true) }
    else { await recommendations.refresh() }
  }

  private func refreshPersonalized() async {
    let refreshID = UUID()
    personalRefreshID = refreshID
    let service = PersonalizedRecommendationsService()
    personalLoading = true
    personalError = nil
    defer { if refreshID == personalRefreshID { personalLoading = false } }
    guard personalFeed else { return }
    let logins = history.entries.filter { $0.platform == .twitch }
      .sorted { ($0.watchCount, $0.lastWatchedAt) > ($1.watchCount, $1.lastWatchedAt) }
      .prefix(20).map(\.login)
    async let watched = SimilarChannelsEngine.liveChannels(forLogins: Array(logins))
    let kickLogins = history.entries.filter { $0.platform == .kick }.prefix(20).map(\.login)
    async let watchedKick = KickDiscoveryService.loadChannels(
      kickLogins, load: { try await KickPlaybackService.channel($0) },
      isCurrent: { personalRefreshID == refreshID })
    await affinity.refreshIfNeeded()
    guard !Task.isCancelled, refreshID == personalRefreshID else { return }
    await service.refresh(
      follows: allLiveFollows,
      followedCategories: follows.isUsingDemoData ? [:] : follows.followedCategories,
      followedLogins: (follows.isUsingDemoData ? [] : follows.followedLogins)
        .union(kick.directory.map { $0.followedChannel.channelKey }),
      history: history, affinity: affinity.map)
    let loaded = await watched
    let loadedKick = await watchedKick
    guard !Task.isCancelled, refreshID == personalRefreshID else { return }
    personalChannels = MobileHomeFeed.homeChannels(
      follows: allLiveFollows,
      watched: loaded + loadedKick.channels.values.map(\.followedChannel),
      recommendations: service.channels, history: history.entries, category: nil)
    if loadedKick.failures > 0 {
      personalError = String(localized: "Some recently watched Kick channels couldn't be refreshed.")
    }
  }
}

struct MobileHomeFeedTabs: View {
  @Binding var feed: MobileHomeFeed
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 24) {
      MobileHomeFeedTab(title: "For you", selected: feed == .live) { feed = .live }
        .accessibilityIdentifier("home-feed-live")
      MobileHomeFeedTab(title: "Following", selected: feed == .following) { feed = .following }
        .accessibilityIdentifier("home-feed-following")
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Home feed")
    .accessibilityIdentifier("mobile-home-feed-tabs")
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: feed)
  }
}

struct MobileHomeFeedTab: View {
  let title: LocalizedStringKey
  let selected: Bool
  let action: () -> Void
  @Environment(\.themePalette) private var palette

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
          .foregroundStyle(selected ? palette.chromeOnOpaque : .secondary)
        Capsule().fill(palette.chromeOnOpaque)
          .frame(width: 24, height: 3)
          .opacity(selected ? 1 : 0)
          .accessibilityHidden(true)
      }
      .frame(minWidth: 44, minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct MobileHomeFilters: View {
  let categories: [TwitchCategory]
  @Binding var selection: TwitchCategory?

  var body: some View {
    let uniqueCategories = categories.reduce(into: [TwitchCategory]()) { result, category in
      if !result.contains(where: { $0.name.caseInsensitiveCompare(category.name) == .orderedSame }) {
        result.append(category)
      }
    }
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        Button("All") { selection = nil }
          .tint(selection == nil ? .accentColor : .secondary)
          .accessibilityAddTraits(selection == nil ? .isSelected : [])
          .accessibilityIdentifier("home-filter-all")
        ForEach(uniqueCategories) { category in
          Button(category.name) { selection = category }
            .tint(selection?.name.caseInsensitiveCompare(category.name) == .orderedSame ? .accentColor : .secondary)
            .accessibilityAddTraits(selection?.name.caseInsensitiveCompare(category.name) == .orderedSame ? .isSelected : [])
            .accessibilityIdentifier("home-filter-\(category.id)")
        }
      }
      .font(.subheadline.weight(.semibold))
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .frame(minHeight: 44)
    }
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .scrollIndicators(.hidden)
    .accessibilityIdentifier("mobile-home-filters")
  }
}

struct MobileLiveFeedContent: View {
  let channels: [FollowedChannel]
  let isLoading: Bool
  let errorMessage: String?
  let preview: MobileHomePreview
  let onSelect: (FollowedChannel) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      if let errorMessage { MobileStatusView(message: errorMessage, retry: onRetry) }
      MobileChannelGrid(channels: channels, onSelect: onSelect, preview: preview, isLoading: isLoading)
      if !isLoading && channels.isEmpty && errorMessage == nil {
        Text("No live streams in this category right now.").foregroundStyle(.secondary)
      }
    }
  }
}

struct MobileFollowedShortcuts: View {
  let channels: [FollowedChannel]
  let onSelect: (FollowedChannel) -> Void
  let onSeeAll: () -> Void
  var isLoading = false
  var authenticated = true
  var isRestoringAccount = false
  var skeletonCount = MobileFollowedShortcutCount.limit
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let visible = authenticated ? channels : []
    let loading = isLoading || isRestoringAccount
    if authenticated || isRestoringAccount {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("Live followed channels").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
          Spacer()
          Button("See all", action: onSeeAll).font(.subheadline)
            .disabled(isRestoringAccount)
        }
        Group {
          if visible.isEmpty && (!loading || skeletonCount == 0) {
            ZStack(alignment: .leading) {
              Text("No followed channels are live right now.")
                .opacity(loading ? 0 : 1).accessibilityHidden(loading)
              if loading { Text("Loading follows") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(minHeight: 44, alignment: .leading)
          } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
              ForEach(Array(visible.prefix(MobileFollowedShortcutCount.limit)), id: \.channelKey) { channel in
                Button { onSelect(channel) } label: { MobileFollowedShortcut(channel: channel) }
                  .buttonStyle(.plain)
                  .accessibilityIdentifier("follow-shortcut-\(channel.channelKey)")
              }
              if visible.isEmpty && loading {
                ForEach(LoadingSkeleton.channels.prefix(min(MobileFollowedShortcutCount.limit, max(0, skeletonCount)))) { channel in
                  MobileFollowedShortcut(channel: channel)
                    .modifier(LoadingSkeletonStyle())
                }
              }
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(visible.isEmpty && loading ? Text("Loading follows") : Text(""))
      }
    }
  }
}

struct MobileFollowedShortcut: View {
  let channel: FollowedChannel
  @Environment(\.themePalette) private var palette

  var body: some View {
    HStack(spacing: 8) {
      CachedAsyncImage(url: channel.profileImageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: { Circle().fill(.quaternary) }
      .frame(width: 30, height: 30).clipShape(Circle())
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          ChannelPlatformIcons(channel: channel, size: 12)
          Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1, reservesSpace: true)
        }
        Text(channel.gameName.isEmpty ? " " : channel.gameName)
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1, reservesSpace: true)
      }
      Spacer(minLength: 0)
      if let count = channel.combinedViewerCount {
        Text(count, format: .number.notation(.compactName))
          .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityLabel("\(count) viewers")
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background(palette.cardOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.cardOpaqueBorder, lineWidth: 0.5) }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

struct MobileFollowingContent: View {
  let authenticated: Bool
  var isRestoringAccount = false
  let channels: [FollowedChannel]
  let isLoading: Bool
  let errorMessage: String?
  let filtered: Bool
  let onAccount: () -> Void
  let onRetry: () -> Void
  let onSelect: (FollowedChannel) -> Void
  var onProfile: ((FollowedChannel) -> Void)? = nil
  var resumeEntries: [MobileVODProgress] = []
  var onResume: ((MobileVODSelection) -> Void)? = nil

  var body: some View {
    if isRestoringAccount {
      TwitchAccountLoadingView().padding(.vertical, 24)
    } else if !authenticated {
      VStack(spacing: 16) {
        Text("Sign in to see your followed channels.").foregroundStyle(.secondary)
        Button("Connect an account", action: onAccount).buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity).padding(.vertical, 24)
    } else {
      LazyVStack(alignment: .leading, spacing: 18) {
        Text("All followed channels").font(.headline).accessibilityAddTraits(.isHeader)
        if let errorMessage { MobileStatusView(message: errorMessage, retry: onRetry) }
        if channels.isEmpty && isLoading {
          ForEach(LoadingSkeleton.channels) { channel in
            MobileFollowingRow(channel: channel)
              .modifier(LoadingSkeletonStyle())
          }
        }
        ForEach(channels, id: \.channelKey) { channel in
          Button { onSelect(channel) } label: { MobileFollowingRow(channel: channel) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("following-\(channel.channelKey)")
            .accessibilityHint(channel.isLive ? "Watch live stream" : "Open channel profile")
            .contextMenu {
              Button("Channel profile") { (onProfile ?? onSelect)(channel) }
              if let entry = resumeEntries.first(where: { $0.login.lowercased() == channel.channelKey }), let onResume {
                Button("Continue broadcast") { onResume(entry.selection) }
              }
            }
        }
        if !isLoading && channels.isEmpty && errorMessage == nil {
          Text(filtered ? "No followed channels in this category." : "You are not following any channels yet.")
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(channels.isEmpty && isLoading ? Text("Loading follows") : Text(""))
    }
  }
}

struct MobileFollowingRow: View {
  let channel: FollowedChannel
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      MobileStreamArtwork(channelKey: channel.channelKey, thumbnailURL: channel.thumbnailURL,
                          isLive: channel.isLive, viewerCount: channel.combinedViewerCount,
                          isCompact: !typeSize.isAccessibilitySize)
        .frame(width: typeSize.isAccessibilitySize ? nil : 116)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          ChannelPlatformIcons(channel: channel)
          Text(channel.displayName).font(.headline).lineLimit(1)
        }
        if channel.isLive { Text(channel.title).font(.subheadline).lineLimit(2, reservesSpace: true) }
        else {
          Text(channel.platform == .kick ? "Offline · Channel profile" : "Offline · Profile and past broadcasts")
            .font(.subheadline).foregroundStyle(.secondary)
            .lineLimit(2, reservesSpace: true)
        }
        Text(channel.gameName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
