import SwiftUI

struct MobileBrowseView: View {
  let onSelect: (FollowedChannel) -> Void
  @State private var service = BrowseService()
  @State private var search = SearchService()
  @State private var query = ""
  @State private var hasLoadedCategories = false
  @State private var showsCategories = false
  @AppStorage(BrowsePlatformFilter.storageKey) private var platformFilter = BrowsePlatformFilter.all
  @AppStorage(StreamLanguagePreference.storageKey) private var language = StreamLanguagePreference.deviceDefault()
  @Environment(PlaybackReturnRefreshCoordinator.self) private var returnRefresh: PlaybackReturnRefreshCoordinator?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Picker("Platform", selection: $platformFilter) {
          ForEach(BrowsePlatformFilter.allCases, id: \.self) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("browse-platform-filter")
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          HStack {
            Text(showsCategories ? String(localized: "Categories") : String(localized: "Live streams"))
              .font(.headline)
            Spacer()
            Button {
              showsCategories.toggle()
            } label: {
              if showsCategories { Text("Live streams") } else { Text("Categories") }
            }
            .accessibilityIdentifier("browse-content-toggle")
          }
          if showsCategories {
            if let error = service.categoryErrorMessage {
              MobileStatusView(message: error) { Task { await refreshBrowse() } }
            }
            MobileCategoryGrid(categories: service.categories, onSelect: onSelect,
                               isLoading: service.isLoadingCategories || !hasLoadedCategories)
            if let error = service.moreCategoriesErrorMessage {
              Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            if service.isLoadingMoreCategories {
              ProgressView("Loading categories")
            } else if service.nextKickCategoryPage != nil {
              Button("Load more") { Task { await service.loadMoreCategories() } }
                .accessibilityIdentifier("browse-load-more-categories")
            }
            if hasLoadedCategories && !service.isLoadingCategories && service.categories.isEmpty
              && service.categoryErrorMessage == nil {
              Text("No live categories found right now.").foregroundStyle(.secondary)
            }
          } else {
            if let error = service.streamsErrorMessage {
              MobileStatusView(message: error) { Task { await refreshBrowse() } }
            }
            MobileChannelGrid(channels: service.categoryStreams, onSelect: onSelect,
                              isLoading: service.isLoadingStreams || !hasLoadedCategories)
            if hasLoadedCategories && !service.isLoadingStreams && service.categoryStreams.isEmpty
              && service.streamsErrorMessage == nil {
              Text("No live streams found right now.").foregroundStyle(.secondary)
            }
            MobileBrowseMore(service: service)
          }
        } else {
          MobileSearchResults(service: search, onSelect: onSelect) {
            Task { await search.search(query, filter: platformFilter) }
          }
        }
      }
      .padding()
    }
    .navigationTitle("Browse")
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Channels and categories")
    .scrollDismissesKeyboard(.interactively)
    .task(id: "\(platformFilter.rawValue):\(query)") {
      let pending = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if search.query == pending, search.platformFilter == platformFilter, search.hasResults { return }
      search.clear()
      guard !pending.isEmpty else { return }
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      await search.search(pending, filter: platformFilter)
    }
    .task(id: "\(platformFilter.rawValue):\(showsCategories):\(language):\(returnRefresh?.thumbnailRevision.uuidString ?? "")") {
      hasLoadedCategories = false
      await refreshBrowse()
    }
    .onChange(of: returnRefresh?.thumbnailRevision) { _, _ in
      if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Task { await search.search(query, preservingResultsOnFailure: true, filter: platformFilter) }
      }
    }
    .refreshable {
      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await refreshBrowse()
      } else {
        await search.search(query, filter: platformFilter)
      }
    }
  }

  private func refreshBrowse() async {
    if showsCategories { await service.loadCategories(filter: platformFilter) }
    else { await service.loadStreams(filter: platformFilter) }
    if !Task.isCancelled { hasLoadedCategories = true }
  }
}

struct MobileSearchResults: View {
  let service: SearchService
  let onSelect: (FollowedChannel) -> Void
  let retry: () -> Void

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 14) {
      if service.isSearching { ProgressView("Searching") }
      if let error = service.errorMessage {
        MobileStatusView(message: error, retry: retry)
      }
      ForEach(service.channelResults, id: \.channelKey) { channel in
        NavigationLink {
          MobileChannelProfileView(channel: channel, onLive: onSelect)
        } label: {
          MobileChannelSearchRow(channel: channel)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stream-\(channel.channelKey)")
      }
      ForEach(service.categoryResults) { category in
        NavigationLink {
          MobileCategoryStreamsView(category: category, onSelect: onSelect)
        } label: {
          MobileCategorySearchRow(category: category)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-category-\(category.id)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MobileChannelSearchRow: View {
  let channel: FollowedChannel

  var body: some View {
    HStack(spacing: 12) {
      CachedAsyncImage(url: channel.profileImageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: { Circle().fill(.quaternary) }
      .frame(width: 40, height: 40).clipShape(Circle())
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          ChannelPlatformIcons(channel: channel)
          Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        if channel.isLive {
          Text("\(channel.gameName) · \(channel.title)")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text("Offline").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)
      if channel.isLive {
        VStack(alignment: .trailing, spacing: 2) {
          Text("LIVE").font(.caption2.bold())
          if let count = channel.combinedViewerCount {
            Text(count, format: .number.notation(.compactName)).font(.caption.monospacedDigit())
          }
        }
      }
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

struct MobileCategorySearchRow: View {
  let category: TwitchCategory

  var body: some View {
    HStack(spacing: 12) {
      CachedAsyncImage(url: category.boxArtURL) { image in
        image.resizable().scaledToFill()
      } placeholder: { Rectangle().fill(.quaternary) }
      .frame(width: 40, height: 54).clipShape(RoundedRectangle(cornerRadius: 3))
      VStack(alignment: .leading, spacing: 3) {
        Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(2)
        Text(category.platform == .kick ? "Kick" : "Twitch").font(.caption2).foregroundStyle(.secondary)
        if let count = category.viewerCount {
          Text("Category · \(count.formatted(.number.notation(.compactName))) viewers")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Category").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

struct MobileCategoryStreamsView: View {
  let category: TwitchCategory
  let onSelect: (FollowedChannel) -> Void
  @State private var service = BrowseService()
  @State private var hasLoaded = false
  @AppStorage(StreamLanguagePreference.storageKey) private var language = StreamLanguagePreference.deviceDefault()
  @Environment(PlaybackReturnRefreshCoordinator.self) private var returnRefresh: PlaybackReturnRefreshCoordinator?

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if let error = service.streamsErrorMessage {
          MobileStatusView(message: error) { Task { await service.loadStreams(for: category) } }
        }
        MobileChannelGrid(channels: service.categoryStreams, onSelect: onSelect,
                          isLoading: service.isLoadingStreams || !hasLoaded)
        MobileBrowseMore(service: service)
        if hasLoaded && !service.isLoadingStreams && service.categoryStreams.isEmpty && service.streamsErrorMessage == nil {
          Text("No live streams in this category right now.").foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle(category.name)
    .task(id: "\(language):\(returnRefresh?.thumbnailRevision.uuidString ?? "")") {
      await service.loadStreams(for: category)
      if !Task.isCancelled { hasLoaded = true }
    }
    .refreshable { await service.loadStreams(for: category) }
  }
}

private struct MobileBrowseMore: View {
  let service: BrowseService

  var body: some View {
    if let error = service.moreStreamsErrorMessage {
      Text(error).font(.footnote).foregroundStyle(.secondary)
    }
    if service.isLoadingMore {
      ProgressView("Loading streams")
    } else if service.nextKickCursor != nil {
      Button("Load more") { Task { await service.loadMoreStreams() } }
        .accessibilityIdentifier("browse-load-more")
    }
  }
}

struct MobileCategoryGrid: View {
  let categories: [TwitchCategory]
  let onSelect: (FollowedChannel) -> Void
  var isLoading = false
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let columns = sizeClass == .compact
      ? Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
              count: typeSize.isAccessibilitySize ? 2 : 3)
      : [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12, alignment: .top)]
    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
      if categories.isEmpty && isLoading {
        ForEach(LoadingSkeleton.categories) { category in
          MobileCategoryCard(category: category)
            .modifier(LoadingSkeletonStyle())
        }
      }
      ForEach(categories) { category in
        NavigationLink {
          MobileCategoryStreamsView(category: category, onSelect: onSelect)
        } label: {
          MobileCategoryCard(category: category)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-\(category.id)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(categories.isEmpty && isLoading ? Text("Loading categories") : Text(""))
  }
}

struct MobileCategoryCard: View {
  let category: TwitchCategory

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Rectangle().fill(.quaternary)
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay {
          CachedAsyncImage(url: category.boxArtURL) { image in
            image.resizable().scaledToFill()
          } placeholder: {
            Icon(glyph: .layoutGrid, size: 32).foregroundStyle(.secondary)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
      Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
      Text(category.platform == .kick ? "Kick" : "Twitch")
        .font(.caption2).foregroundStyle(.secondary)
      Text(category.viewerCount ?? 0, format: .number.notation(.compactName))
        .font(.caption).foregroundStyle(.secondary)
        .opacity(category.viewerCount == nil ? 0 : 1)
        .accessibilityLabel("\(category.viewerCount ?? 0) viewers")
        .accessibilityHidden(category.viewerCount == nil)
    }
  }
}

struct MobileChannelGrid: View {
  let channels: [FollowedChannel]
  let onSelect: (FollowedChannel) -> Void
  var preview: MobileHomePreview? = nil
  var isLoading = false

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20, alignment: .top)], spacing: 24) {
      if channels.isEmpty && isLoading {
        ForEach(LoadingSkeleton.channels.prefix(6)) { channel in
          MobileChannelCard(channel: channel)
            .modifier(LoadingSkeletonStyle())
        }
      }
      ForEach(channels, id: \.channelKey) { channel in
        Button { onSelect(channel) } label: {
          MobileChannelCard(channel: channel, preview: preview)
        }
        .buttonStyle(.plain)
        .disabled(!channel.isLive)
        .contextMenu {
          NavigationLink("View channel") { MobileChannelProfileView(channel: channel, onLive: onSelect) }
        }
        .accessibilityIdentifier("stream-\(channel.channelKey)")
        .accessibilityHint(channel.isLive ? "Watch live stream" : "Channel is offline")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(channels.isEmpty && isLoading ? Text("Loading streams") : Text(""))
  }
}

struct MobileChannelCard: View {
  let channel: FollowedChannel
  var preview: MobileHomePreview? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileStreamArtwork(channelKey: channel.channelKey, thumbnailURL: channel.thumbnailURL,
                          isLive: channel.isLive, viewerCount: channel.combinedViewerCount, preview: preview)
      HStack(alignment: .top, spacing: 10) {
        CachedAsyncImage(url: channel.profileImageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: { Circle().fill(.quaternary) }
        .frame(width: 40, height: 40).clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            ChannelPlatformIcons(channel: channel)
            Text(channel.displayName).font(.headline).lineLimit(1, reservesSpace: true)
          }
          Text(channel.title).font(.subheadline).lineLimit(2, reservesSpace: true)
          Text(channel.gameName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
      }

    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityValue(preview?.channel == channel.channelKey && preview?.isReady == true ? "Muted live preview" : "")
  }
}

struct MobileStreamArtwork: View {
  let channelKey: String
  let thumbnailURL: URL?
  let isLive: Bool
  let viewerCount: Int?
  var preview: MobileHomePreview? = nil
  var isCompact = false
  @Environment(\.themePalette) private var palette

  var body: some View {
    Rectangle().fill(palette.cardOpaqueSurface)
    .aspectRatio(16 / 9, contentMode: .fit)
    .overlay {
      LiveThumbnail(url: thumbnailURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Icon(glyph: .broadcast, size: 28).foregroundStyle(.secondary)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("artwork-\(channelKey)")
    .overlay {
      if let preview, preview.channel == channelKey, preview.player.currentItem != nil {
        MobilePreviewSurface(player: preview.player)
          .opacity(preview.isReady ? 1 : 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("mobile-home-content")) } action: {
      if isLive { preview?.updateFrame($0, for: channelKey) }
    }
    .onDisappear { preview?.updateFrame(nil, for: channelKey) }
    .overlay(alignment: .topTrailing) {
      if !isCompact {
        HStack(spacing: 4) {
          if isLive {
            Circle().fill(palette.liveIndicator).frame(width: 6, height: 6)
              .accessibilityHidden(true)
          }
          Text(isLive ? "Live" : "Offline")
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6).padding(.vertical, 3)
        .modifier(MobileControlSurface())
        .padding(6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live-label-\(channelKey)")
      }
    }
    .overlay(alignment: .bottomLeading) {
      if isLive && isCompact {
        MobileViewerBadge(count: viewerCount, isCompact: true)
          .padding(4)
          .accessibilityIdentifier("viewers-\(channelKey)")
      } else if isLive, let viewerCount {
        MobileViewerBadge(count: viewerCount)
          .padding(6)
          .accessibilityIdentifier("viewers-\(channelKey)")
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if let preview, preview.channel == channelKey, preview.isReady {
        Icon(glyph: .volumeOff, size: 16)
          .padding(6)
          .modifier(MobileControlSurface())
          .padding(6)
          .accessibilityLabel("Muted live preview")
      }
    }
  }
}

struct MobileViewerBadge: View {
  let count: Int?
  var isCompact = false
  var isVideoOverlay = false
  @Environment(\.themePalette) private var palette

  var body: some View {
    HStack(spacing: 4) {
      if isCompact {
        Circle().fill(palette.liveIndicator).frame(width: 6, height: 6)
      } else {
        Icon(glyph: .user, size: 12)
      }
      if let count {
        Text(count, format: .number.notation(.compactName)).monospacedDigit()
      }
    }
    .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, isCompact ? 4 : 6).padding(.vertical, isCompact ? 2 : 4)
    .modifier(MobileControlSurface(isVideoOverlay: isVideoOverlay))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count.map {
      isCompact ? String(localized: "Live, \($0) viewers") : String(localized: "\($0) viewers")
    } ?? String(localized: "Live"))
  }
}

struct MobileStatusView: View {
  let message: String
  var playerControls = false
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text(message).multilineTextAlignment(.center)
      if playerControls {
        Button(action: retry) {
          Text("Try again").padding(.horizontal, 16).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .modifier(MobilePlayerButtonSurface())
      } else {
        Button("Try again", action: retry).buttonStyle(.bordered)
      }
    }
    .padding()
    .frame(maxWidth: .infinity)
  }
}
