import SwiftUI

struct MobileBrowseView: View {
  let onSelect: (FollowedChannel) -> Void
  @State private var service = BrowseService()
  @State private var search = SearchService()
  @State private var query = ""

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          if let error = service.categoryErrorMessage {
            MobileStatusView(message: error) { Task { await service.loadCategories() } }
          }
          MobileCategoryGrid(categories: service.categories, onSelect: onSelect)
          if service.isLoadingCategories { ProgressView("Loading categories") }
        } else {
          MobileSearchResults(service: search, onSelect: onSelect) {
            Task { await search.search(query) }
          }
        }
      }
      .padding()
    }
    .navigationTitle("Browse")
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Channels and categories")
    .scrollDismissesKeyboard(.interactively)
    .task(id: query) {
      search.clear()
      guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      await search.search(query)
    }
    .task { if service.categories.isEmpty { await service.loadCategories() } }
    .refreshable {
      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await service.loadCategories()
      } else {
        await search.search(query)
      }
    }
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
        Button { onSelect(channel) } label: {
          MobileChannelSearchRow(channel: channel)
        }
        .buttonStyle(.plain)
        .disabled(!channel.isLive)
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
        Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
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
          if let count = channel.viewerCount {
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

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if let error = service.streamsErrorMessage {
          MobileStatusView(message: error) { Task { await service.loadStreams(for: category) } }
        }
        MobileChannelGrid(channels: service.categoryStreams, onSelect: onSelect)
        if service.isLoadingStreams {
          ProgressView("Loading streams")
        } else if service.categoryStreams.isEmpty && service.streamsErrorMessage == nil {
          Text("No live streams in this category right now.").foregroundStyle(.secondary)
        }
      }
      .padding()
    }
    .navigationTitle(category.name)
    .task { await service.loadStreams(for: category) }
    .refreshable { await service.loadStreams(for: category) }
  }
}

struct MobileCategoryGrid: View {
  let categories: [TwitchCategory]
  let onSelect: (FollowedChannel) -> Void
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let columns = sizeClass == .compact
      ? Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
              count: typeSize.isAccessibilitySize ? 2 : 3)
      : [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12, alignment: .top)]
    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
      ForEach(categories) { category in
        NavigationLink {
          MobileCategoryStreamsView(category: category, onSelect: onSelect)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            CachedAsyncImage(url: category.boxArtURL) { image in
              image.resizable().scaledToFill()
            } placeholder: { Rectangle().fill(.quaternary) }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(category.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let count = category.viewerCount {
              Text(count, format: .number.notation(.compactName))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("\(count) viewers")
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("category-\(category.id)")
      }
    }
  }
}

struct MobileChannelGrid: View {
  let channels: [FollowedChannel]
  let onSelect: (FollowedChannel) -> Void
  var preview: MobileHomePreview? = nil

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20, alignment: .top)], spacing: 24) {
      ForEach(channels, id: \.channelKey) { channel in
        Button { onSelect(channel) } label: {
          MobileChannelCard(channel: channel, preview: preview)
        }
        .buttonStyle(.plain)
        .disabled(!channel.isLive)
        .accessibilityIdentifier("stream-\(channel.channelKey)")
        .accessibilityHint(channel.isLive ? "Watch live stream" : "Channel is offline")
      }
    }
  }
}

struct MobileChannelCard: View {
  let channel: FollowedChannel
  var preview: MobileHomePreview? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      MobileStreamArtwork(channelKey: channel.channelKey, thumbnailURL: channel.thumbnailURL,
                          isLive: channel.isLive, viewerCount: channel.viewerCount, preview: preview)
      HStack(alignment: .top, spacing: 10) {
        CachedAsyncImage(url: channel.profileImageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: { Circle().fill(.quaternary) }
        .frame(width: 40, height: 40).clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(channel.displayName).font(.headline)
          Text(channel.title).font(.subheadline).lineLimit(2)
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
    LiveThumbnail(url: thumbnailURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Rectangle().fill(palette.cardOpaqueSurface)
        .overlay { Icon(glyph: .broadcast, size: 28).foregroundStyle(.secondary) }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
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
    .modifier(MobileControlSurface())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count.map {
      isCompact ? String(localized: "Live, \($0) viewers") : String(localized: "\($0) viewers")
    } ?? String(localized: "Live"))
  }
}

struct MobileStatusView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Text(message).multilineTextAlignment(.center)
      Button("Try again", action: retry).buttonStyle(.bordered)
    }
    .padding()
    .frame(maxWidth: .infinity)
  }
}
