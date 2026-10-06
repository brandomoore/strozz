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
}

struct MobileHomeView: View {
  let preview: MobileHomePreview
  let previewsEnabled: Bool
  let onSelect: (FollowedChannel) -> Void
  let onAccount: () -> Void
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(\.themePalette) private var palette
  @State private var feed = MobileHomeFeed.live
  @State private var category: TwitchCategory?
  @State private var recommendations = RecommendationsService()
  @State private var categoryStreams = BrowseService()
  @State private var follows = FollowedChannelsService()
  @State private var followsAccountID: String?

  private var shouldPreview: Bool { previewsEnabled && feed == .live }
  private var liveCategoryID: String? { feed == .live ? category?.id : nil }
  private var visibleFollows: [FollowedChannel] {
    MobileHomeFeed.visibleFollows(follows.channels, authenticated: auth.isAuthenticated,
                                 isDemo: follows.isUsingDemoData, category: category)
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          MobileHomeHeading(feed: $feed)
            .id("mobile-home-top")
          MobileHomeFilters(categories: recommendations.categories, selection: $category)
          if feed == .following {
            MobileFollowingContent(
              authenticated: auth.isAuthenticated, channels: visibleFollows,
              isLoading: follows.isLoading, errorMessage: follows.errorMessage,
              filtered: category != nil, onAccount: onAccount,
              onRetry: { Task { await follows.refresh(using: auth) } }, onSelect: onSelect)
          } else {
            if !visibleFollows.isEmpty {
              MobileFollowedShortcuts(channels: visibleFollows, onSelect: onSelect,
                                     onSeeAll: { feed = .following })
            }
            MobileLiveFeedContent(
              channels: category == nil ? recommendations.channels : categoryStreams.categoryStreams,
              isLoading: category == nil ? recommendations.isLoading : categoryStreams.isLoadingStreams,
              errorMessage: category == nil ? recommendations.errorMessage : categoryStreams.streamsErrorMessage,
              preview: preview, onSelect: onSelect, onRetry: { Task { await refreshLive() } })
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom)
        .coordinateSpace(name: "mobile-home-content")
      }
      .clipped()
      .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, viewport in
        preview.updateViewport(viewport)
      }
      .onChange(of: feed) { _, _ in proxy.scrollTo("mobile-home-top", anchor: .top) }
      .refreshable {
        if feed == .following {
          if auth.isAuthenticated { await follows.refresh(using: auth) }
        }
        else {
          await refreshLive()
          if auth.isAuthenticated { await follows.refresh(using: auth) }
        }
      }
    }
    .onChange(of: shouldPreview, initial: true) { _, enabled in preview.setEnabled(enabled) }
    .onAppear { preview.setEnabled(shouldPreview) }
    .onDisappear { preview.stop() }
    .background(palette.backgroundColors.last ?? palette.cardOpaqueSurface)
    .toolbar(.hidden, for: .navigationBar)
    .task { if recommendations.lastUpdatedAt == nil { await recommendations.refresh() } }
    .task(id: liveCategoryID) {
      if feed == .live, let category { await categoryStreams.loadStreams(for: category) }
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
  }

  private func refreshLive() async {
    if let category { await categoryStreams.loadStreams(for: category) }
    else { await recommendations.refresh() }
  }
}

struct MobileHomeHeading: View {
  @Binding var feed: MobileHomeFeed

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Strozz")
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("mobile-home-heading")
      Picker("Home feed", selection: $feed) {
        Text("Following").tag(MobileHomeFeed.following)
        Text("Live").tag(MobileHomeFeed.live)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("mobile-home-feed-picker")
    }
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
      MobileChannelGrid(channels: channels, onSelect: onSelect, preview: preview)
      if isLoading {
        ProgressView("Loading streams").frame(maxWidth: .infinity)
      } else if channels.isEmpty && errorMessage == nil {
        Text("No live streams in this category right now.").foregroundStyle(.secondary)
      }
    }
  }
}

struct MobileFollowedShortcuts: View {
  let channels: [FollowedChannel]
  let onSelect: (FollowedChannel) -> Void
  let onSeeAll: () -> Void
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Live followed channels").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
        Spacer()
        Button("See all", action: onSeeAll).font(.subheadline)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                               count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
        ForEach(Array(channels.prefix(6)), id: \.channelKey) { channel in
          Button { onSelect(channel) } label: { MobileFollowedShortcut(channel: channel) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("follow-shortcut-\(channel.channelKey)")
        }
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
        Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
        Text(channel.gameName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
  let channels: [FollowedChannel]
  let isLoading: Bool
  let errorMessage: String?
  let filtered: Bool
  let onAccount: () -> Void
  let onRetry: () -> Void
  let onSelect: (FollowedChannel) -> Void

  var body: some View {
    if !authenticated {
      VStack(spacing: 16) {
        Text("Sign in to see your live followed channels.").foregroundStyle(.secondary)
        Button("Sign in to Twitch", action: onAccount).buttonStyle(.borderedProminent)
      }
      .frame(maxWidth: .infinity).padding(.vertical, 24)
    } else {
      LazyVStack(alignment: .leading, spacing: 18) {
        Text("Live followed channels").font(.headline).accessibilityAddTraits(.isHeader)
        if let errorMessage { MobileStatusView(message: errorMessage, retry: onRetry) }
        ForEach(channels, id: \.channelKey) { channel in
          Button { onSelect(channel) } label: { MobileFollowingRow(channel: channel) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("following-\(channel.channelKey)")
        }
        if isLoading {
          ProgressView("Loading follows").frame(maxWidth: .infinity)
        } else if channels.isEmpty && errorMessage == nil {
          Text(filtered ? "No followed channels are live in this category." : "None of your followed channels are live right now.")
            .foregroundStyle(.secondary)
        }
      }
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
        Text(channel.title).font(.subheadline).lineLimit(2)
        Text(channel.gameName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
