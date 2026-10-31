import SwiftUI

struct KickChannelDetailsView: View {
  let slug: String
  let onWatch: (FollowedChannel) -> Void
  @State private var content: KickChannelContentService.Content?
  @State private var errorMessage: String?
  @State private var loading = false
  @State private var selectedVideo: ChannelVOD?
  @State private var related: [FollowedChannel] = []
  @State private var clips: [ChannelClip] = []
  @State private var selectedClip: ChannelClip?
  @State private var nextClipCursor: String?
  @State private var clipsError: String?
  @State private var loadingMoreClips = false
  @State private var refreshID = UUID()
  #if os(iOS)
  @Environment(MobileVODProgressStore.self) private var progress
  #endif

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        if loading { ProgressView("Loading channel") }
        if let content {
          KickChannelHeader(content: content, onWatch: onWatch)
          KickClipsSection(clips: clips) { selectedClip = $0 }
          if let clipsError { Text(clipsError).font(.footnote).foregroundStyle(.secondary) }
          if loadingMoreClips {
            ProgressView("Loading clips")
          } else if nextClipCursor != nil {
            Button("More clips") { Task { await loadMoreClips() } }.disabled(loading)
          }
          #if os(iOS)
          let resumable = progress.entries.filter {
            $0.video.platform == .kick && $0.login.caseInsensitiveCompare(slug) == .orderedSame
          }
          if !resumable.isEmpty {
            MobileContinueWatchingSection(entries: resumable) { selectedVideo = $0.video }
          }
          #endif
          Text("Past broadcasts").font(.title2.bold()).accessibilityAddTraits(.isHeader)
          ForEach(content.videos) { video in
            Button { selectedVideo = video } label: {
              #if os(tvOS)
              KickBroadcastRow(video: video)
              #else
              MobileBroadcastRow(video: video, subtitle: nil, resumeSeconds: progress.progress(for: video.id))
              #endif
            }
            #if os(iOS)
            .buttonStyle(.plain)
            #endif
            .accessibilityIdentifier("broadcast-\(video.id)")
          }
          if content.videos.isEmpty {
            Text("No past broadcasts are available for this channel.").foregroundStyle(.secondary)
          } else {
            Text("Chat replay isn't available for Kick broadcasts.").font(.footnote).foregroundStyle(.secondary)
          }
          KickRelatedChannels(channels: related, onWatch: onWatch)
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        HStack {
          Button("Refresh") { Task { await refresh() } }.disabled(loading)
          #if os(tvOS)
          MultiviewLineupButton()
          #endif
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(content?.channel.displayName ?? slug)
    .accessibilityIdentifier("kick-channel-profile")
    .task(id: slug) { await refresh() }
    .task(id: "\(content?.channel.category ?? ""):\(content?.videos.first?.id ?? "")") {
      guard let content else { related = []; return }
      let categories = ([content.channel.category] + content.videos.prefix(8).compactMap(\.gameName))
        .filter { !$0.isEmpty }
      let counts = Dictionary(categories.map { ($0, 1.0) }, uniquingKeysWith: +)
      let maximum = counts.values.max() ?? 1
      let signals = ChannelSignals(login: "kick:\(slug)", categoryWeights: counts.mapValues { $0 / maximum },
        language: nil, tags: [], viewerTier: content.channel.viewerCount)
      let channels = await SimilarChannelsEngine.recommend(using: signals)
      if !Task.isCancelled { related = channels }
    }
    .refreshable { await refresh() }
    .fullScreenCover(item: $selectedVideo) { video in
      #if os(tvOS)
      OnDemandPlayerView(item: .vod(id: video.id, title: video.title), channelLogin: slug)
      #else
      if let content {
        MobileVODPlayerView(selection: .init(video: video, channel: .init(channel: content.channel.followedChannel)))
      }
      #endif
    }
    .fullScreenCover(item: $selectedClip) { clip in
      ClipPlayerView(slug: clip.slug, title: clip.title)
    }
  }

  private func refresh() async {
    let request = UUID()
    refreshID = request
    if let content, content.channel.slug.caseInsensitiveCompare(slug) != .orderedSame {
      self.content = nil
      clips = []
      related = []
      errorMessage = nil
      selectedVideo = nil
      selectedClip = nil
    }
    loading = true
    loadingMoreClips = false
    nextClipCursor = nil
    clipsError = nil
    defer { if refreshID == request { loading = false } }
    async let clipPage = KickChannelContentService.clips(slug)
    do {
      let value = try await KickChannelContentService.load(slug)
      guard !Task.isCancelled, refreshID == request else { return }
      content = value
      errorMessage = nil
    } catch {
      if !Task.isCancelled, refreshID == request { errorMessage = error.localizedDescription }
    }
    do {
      let page = try await clipPage
      guard !Task.isCancelled, refreshID == request else { return }
      clips = page.clips
      nextClipCursor = page.nextCursor
    } catch {
      if !Task.isCancelled, refreshID == request {
        clipsError = String(localized: "Clips couldn't be refreshed. \(error.localizedDescription)")
      }
    }
  }

  private func loadMoreClips() async {
    guard !loading, !loadingMoreClips, let cursor = nextClipCursor else { return }
    let request = refreshID
    loadingMoreClips = true
    clipsError = nil
    defer { if request == refreshID { loadingMoreClips = false } }
    do {
      let page = try await KickChannelContentService.clips(slug, after: cursor)
      guard !Task.isCancelled, request == refreshID else { return }
      var seen = Set(clips.map(\.id))
      clips += page.clips.filter { seen.insert($0.id).inserted }
      nextClipCursor = page.nextCursor == cursor ? nil : page.nextCursor
    } catch {
      if !Task.isCancelled, request == refreshID {
        clipsError = String(localized: "Clips couldn't be refreshed. \(error.localizedDescription)")
      }
    }
  }
}

private struct KickClipsSection: View {
  let clips: [ChannelClip]
  let onSelect: (ChannelClip) -> Void

  var body: some View {
    if !clips.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        Text("Clips").font(.title2.bold()).accessibilityAddTraits(.isHeader)
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 24) {
            ForEach(clips) { clip in
              Button { onSelect(clip) } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                      CachedAsyncImage(url: clip.thumbnailURL) { image in image.resizable().scaledToFill() }
                        placeholder: { Rectangle().fill(.quaternary) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                  Text(clip.title).font(.headline).lineLimit(2, reservesSpace: true)
                  Text(Duration.seconds(clip.durationSeconds).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                }
                .frame(width: 300)
              }
              #if os(iOS)
              .buttonStyle(.plain)
              #endif
              .accessibilityIdentifier("clip-\(clip.id)")
            }
          }
          .padding(.vertical, 12)
        }
        .scrollClipDisabled()
      }
    }
  }
}

private struct KickRelatedChannels: View {
  let channels: [FollowedChannel]
  let onWatch: (FollowedChannel) -> Void

  var body: some View {
    if !channels.isEmpty {
      VStack(alignment: .leading, spacing: 16) {
        Text("More like this").font(.title2.bold()).accessibilityAddTraits(.isHeader)
        ForEach(channels, id: \.channelKey) { channel in
          Button { onWatch(channel) } label: {
            HStack(spacing: 12) {
              ChannelPlatformIcons(channel: channel)
              VStack(alignment: .leading) {
                Text(channel.displayName).font(.headline)
                Text(channel.title).font(.subheadline).lineLimit(2)
              }
              Spacer()
              if let count = channel.combinedViewerCount {
                Text(count, format: .number.notation(.compactName)).font(.subheadline)
              }
            }
          }
          #if os(tvOS)
          .contextMenu { MultiviewSelectionAction(channel: channel) }
          #endif
        }
      }
    }
  }
}

private struct KickChannelHeader: View {
  let content: KickChannelContentService.Content
  let onWatch: (FollowedChannel) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        CachedAsyncImage(url: content.channel.imageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: { Circle().fill(.quaternary) }
          .frame(width: 80, height: 80).clipShape(Circle())
        VStack(alignment: .leading, spacing: 6) {
          Label { Text(content.channel.displayName).font(.title.bold()) } icon: {
            Icon(glyph: .brandKick, size: 28)
          }
          Text(content.channel.isLive ? "Live on Kick" : "Offline").foregroundStyle(.secondary)
          if let count = content.followerCount {
            Text("\(count.formatted(.number.notation(.compactName))) followers").font(.subheadline)
          }
        }
      }
      if let description = content.description, !description.isEmpty { Text(description).font(.subheadline) }
      if content.channel.isLive {
        Text(content.channel.title).font(.headline)
        HStack {
          Text(content.channel.category)
          if let count = content.channel.viewerCount {
            Text("\(count.formatted(.number.notation(.compactName))) viewers")
          }
        }.font(.subheadline).foregroundStyle(.secondary)
        Button("Watch live") { onWatch(content.channel.followedChannel) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("kick-watch-live")
          #if os(tvOS)
          .contextMenu { MultiviewSelectionAction(channel: content.channel.followedChannel) }
          #endif
      }
    }
  }
}

#if os(tvOS)
private struct KickBroadcastRow: View {
  let video: ChannelVOD

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      CachedAsyncImage(url: video.thumbnailURL) { image in image.resizable().scaledToFill() }
        placeholder: { Rectangle().fill(.quaternary) }
        .frame(width: 280, height: 157.5).clipShape(RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 8) {
        Text(video.title).font(.headline).lineLimit(2)
        if let date = video.publishedAt { Text(date, style: .date).font(.subheadline) }
        Text(Duration.seconds(video.lengthSeconds).formatted(.time(pattern: .hourMinuteSecond)))
          .font(.subheadline.monospacedDigit())
        Text("\(video.viewCount.formatted(.number.notation(.compactName))) views").font(.subheadline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}
#endif
