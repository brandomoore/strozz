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
    let counts = Dictionary(history.map { ($0.login.lowercased(), $0.watchCount) }, uniquingKeysWith: max)
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
  let onSelect: (FollowedChannel) -> Void
  let onProfile: (FollowedChannel) -> Void
  let onAccount: () -> Void
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync
  @Environment(\.themePalette) private var palette
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(MobileVODProgressStore.self) private var vodProgress
  @AppStorage(RecommendationPreferences.enabledDefaultsKey) private var personalizedEnabled = true
  @State private var feed = MobileHomeFeed.live
  @State private var category: TwitchCategory?
  @State private var recommendations = RecommendationsService()
  @State private var categoryStreams = BrowseService()
  @State private var follows = FollowedChannelsService()
  @State private var followsAccountID: String?
  @State private var followedSkeletonCount = MobileFollowedShortcutCount.limit
  @State private var affinity = StreamerAffinityService()
  @State private var personalChannels: [FollowedChannel] = []
  @State private var selectedVideo: MobileVODSelection?
  @State private var personalRefreshID = UUID()
  @State private var personalLoading = true

  private var shouldPreview: Bool { previewsEnabled && feed == .live && selectedVideo == nil }
  private var liveCategoryID: String? { feed == .live ? category?.id : nil }
  private var personalFeed: Bool {
    personalizedEnabled && (auth.isAuthenticated || !history.entries.isEmpty)
  }
  private var personalizationID: String {
    "\(auth.userID ?? "")|\(follows.lastUpdatedAt?.timeIntervalSinceReferenceDate ?? 0)|\(personalizedEnabled)|"
      + history.entries.map { "\($0.login):\($0.watchCount)" }.joined(separator: ",")
  }
  private var visibleFollows: [FollowedChannel] {
    MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
                                 isDemo: follows.isUsingDemoData, category: category)
  }
  private var shortcutsLoading: Bool {
    sync.isRestoringAccount || (follows.lastUpdatedAt == nil && follows.errorMessage == nil)
  }
  private var homeChannels: [FollowedChannel] {
    guard personalFeed else { return category == nil ? recommendations.channels : categoryStreams.categoryStreams }
    return personalChannels.filter { channel in
      category.map { channel.gameName.localizedCaseInsensitiveCompare($0.name) == .orderedSame } ?? true
    }
  }

  var body: some View {
    let shortcutChannels = visibleFollows
    let shortcutRows = MobileFollowedShortcutCount.rows(
      visibleCount: shortcutChannels.count, isLoading: shortcutsLoading,
      cachedCount: followedSkeletonCount, accessibilitySize: typeSize.isAccessibilitySize)
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
            Text("Strozz")
              .font(.title2.bold())
              .accessibilityAddTraits(.isHeader)
              .accessibilityIdentifier("mobile-home-heading")
              .padding(.horizontal)
              .id("mobile-home-top")
            Section {
              MobileHomeFilters(categories: recommendations.categories, selection: $category)
              if feed == .following {
                MobileFollowingContent(
                  authenticated: auth.isAuthenticated,
                  isRestoringAccount: sync.isRestoringAccount,
                  channels: MobileHomeFeed.directory(follows.directory, authenticated: auth.isAuthenticated, category: category),
                  isLoading: follows.isLoadingDirectory
                    || (follows.directoryLoadedAt == nil && follows.directoryErrorMessage == nil),
                  errorMessage: follows.directoryErrorMessage,
                  filtered: category != nil, onAccount: onAccount,
                  onRetry: { Task { await follows.loadDirectory(using: auth, force: true) } },
                  onSelect: onSelect, onProfile: onProfile, resumeEntries: vodProgress.entries,
                  onResume: { selectedVideo = $0 })
                  .padding(.horizontal)
              } else {
                if category == nil, !vodProgress.entries.isEmpty {
                  MobileContinueWatchingSection(entries: Array(vodProgress.entries.prefix(4))) { selectedVideo = $0 }
                    .padding(.horizontal)
                }
                MobileFollowedShortcuts(channels: shortcutChannels, onSelect: onSelect,
                                       onSeeAll: { feed = .following },
                                       isLoading: shortcutsLoading,
                                       authenticated: auth.isAuthenticated,
                                       isRestoringAccount: sync.isRestoringAccount,
                                       skeletonCount: followedSkeletonCount)
                  .padding(.horizontal)
                Text(personalFeed ? "For you" : "Popular live channels")
                  .font(.title3.bold()).accessibilityAddTraits(.isHeader).padding(.horizontal)
                if personalFeed, let error = follows.errorMessage {
                  MobileStatusView(message: error) { Task { await follows.refresh(using: auth) } }
                    .padding(.horizontal)
                }
                MobileLiveFeedContent(
                  channels: homeChannels,
                  isLoading: personalFeed ? (personalLoading || (auth.isAuthenticated
                    && (follows.isLoading || follows.lastUpdatedAt == nil)))
                    : (category == nil ? recommendations.isLoading || recommendations.lastUpdatedAt == nil
                      : categoryStreams.isLoadingStreams),
                  errorMessage: personalFeed ? nil
                    : (category == nil ? recommendations.errorMessage : categoryStreams.streamsErrorMessage),
                  preview: preview, onSelect: onSelect, onRetry: { Task { await refreshLive() } })
                  .padding(.horizontal)
              }
            } header: {
              MobileHomeFeedTabs(feed: $feed)
                .padding(.horizontal)
                .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
            }
          }
          .animation(reduceMotion || feed != .live ? nil : .easeInOut(duration: 0.22), value: shortcutRows)
          .padding(.top, 8)
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
          if feed == .following {
            if auth.isAuthenticated { await follows.loadDirectory(using: auth, force: true) }
          } else {
            await refreshLive()
            if auth.isAuthenticated { await follows.refresh(using: auth) }
          }
        }
      }
      .ignoresSafeArea(.container, edges: .bottom)
    }
    .onChange(of: shouldPreview, initial: true) { _, enabled in preview.setEnabled(enabled) }
    .onAppear { preview.setEnabled(shouldPreview) }
    .onDisappear { preview.stop() }
    .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: auth.userID, initial: true) { _, accountID in
      followedSkeletonCount = MobileFollowedShortcutCount.cached(for: accountID)
    }
    .onChange(of: follows.lastUpdatedAt) { _, updatedAt in
      guard updatedAt != nil, auth.isAuthenticated, followsAccountID == auth.userID,
            let count = MobileFollowedShortcutCount.remember(
              follows.channels, for: followsAccountID, isDemo: follows.isUsingDemoData,
              errorMessage: follows.errorMessage)
      else { return }
      followedSkeletonCount = count
    }
    .task { if recommendations.lastUpdatedAt == nil { await recommendations.refresh() } }
    .task(id: liveCategoryID) {
      if feed == .live, !personalFeed, let category { await categoryStreams.loadStreams(for: category) }
    }
    .task(id: auth.isAuthenticated ? auth.userID : nil) {
      guard !Task.isCancelled else { return }
      // A previous account's in-flight refresh may only update its old service.
      let accountID = auth.isAuthenticated ? auth.userID : nil
      if followsAccountID != accountID {
        follows = FollowedChannelsService()
        followsAccountID = accountID
      }
      let current = follows
      if auth.isAuthenticated { await current.refresh(using: auth) }
    }
    .task(id: "\(auth.userID ?? "")-\(feed == .following)") {
      if feed == .following { await follows.loadDirectory(using: auth) }
    }
    .task(id: personalizationID) { await refreshPersonalized() }
    .fullScreenCover(item: $selectedVideo) { MobileVODPlayerView(selection: $0) }
  }

  private func refreshLive() async {
    if personalFeed { await refreshPersonalized() }
    else if let category { await categoryStreams.loadStreams(for: category) }
    else { await recommendations.refresh() }
  }

  private func refreshPersonalized() async {
    let refreshID = UUID()
    personalRefreshID = refreshID
    let service = PersonalizedRecommendationsService()
    personalLoading = true
    defer { if refreshID == personalRefreshID { personalLoading = false } }
    guard personalFeed else { return }
    let logins = history.entries.sorted { ($0.watchCount, $0.lastWatchedAt) > ($1.watchCount, $1.lastWatchedAt) }
      .prefix(20).map(\.login)
    async let watched = SimilarChannelsEngine.liveChannels(forLogins: Array(logins))
    await affinity.refreshIfNeeded()
    guard !Task.isCancelled, refreshID == personalRefreshID else { return }
    await service.refresh(
      follows: MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
        isDemo: follows.isUsingDemoData, category: nil),
      followedCategories: follows.isUsingDemoData ? [:] : follows.followedCategories,
      followedLogins: follows.isUsingDemoData ? [] : follows.followedLogins,
      history: history, affinity: affinity.map)
    let loaded = await watched
    guard !Task.isCancelled, refreshID == personalRefreshID else { return }
    personalChannels = MobileHomeFeed.homeChannels(
      follows: MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
        isDemo: follows.isUsingDemoData, category: nil),
      watched: loaded, recommendations: service.channels, history: history.entries, category: nil)
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
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        Button("All") { selection = nil }
          .tint(selection == nil ? .accentColor : .secondary)
          .accessibilityAddTraits(selection == nil ? .isSelected : [])
          .accessibilityIdentifier("home-filter-all")
        ForEach(categories) { category in
          Button(category.name) { selection = category }
            .tint(selection?.id == category.id ? .accentColor : .secondary)
            .accessibilityAddTraits(selection?.id == category.id ? .isSelected : [])
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
        Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1, reservesSpace: true)
        Text(channel.gameName.isEmpty ? " " : channel.gameName)
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1, reservesSpace: true)
      }
      Spacer(minLength: 0)
      if let count = channel.viewerCount {
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
        Button("Sign in to Twitch", action: onAccount).buttonStyle(.borderedProminent)
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
            .accessibilityHint(channel.isLive ? "Watch live stream" : "Open channel profile and past broadcasts")
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
                          isLive: channel.isLive, viewerCount: channel.viewerCount,
                          isCompact: !typeSize.isAccessibilitySize)
        .frame(width: typeSize.isAccessibilitySize ? nil : 116)
      VStack(alignment: .leading, spacing: 3) {
        Text(channel.displayName).font(.headline).lineLimit(1)
        if channel.isLive { Text(channel.title).font(.subheadline).lineLimit(2, reservesSpace: true) }
        else {
          Text("Offline · Profile and past broadcasts").font(.subheadline).foregroundStyle(.secondary)
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
