import SwiftUI

struct MobileChannelProfileView: View {
  let channel: FollowedChannel
  let onLive: (FollowedChannel) -> Void
  @Environment(MobileVODProgressStore.self) private var progress
  @State private var profile: ChannelProfile?
  @State private var content: ChannelContent?
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var selectedVideo: MobileVODSelection?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        MobileChannelProfileHeader(channel: channel, profile: profile, onLive: onLive)
        if let errorMessage { MobileStatusView(message: errorMessage) { Task { await refresh() } } }
        let resumable = progress.entries.filter { $0.login.caseInsensitiveCompare(channel.login) == .orderedSame }
        if !resumable.isEmpty {
          MobileContinueWatchingSection(entries: resumable) { selectedVideo = $0 }
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("Past broadcasts").font(.title3.bold()).accessibilityAddTraits(.isHeader)
          if loading { ProgressView("Loading broadcasts") }
          ForEach(content?.videos ?? []) { video in
            Button {
              selectedVideo = .init(video: video, channel: .init(channel: channel))
            } label: {
              MobileBroadcastRow(video: video, subtitle: nil, resumeSeconds: progress.progress(for: video.id))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("broadcast-\(video.id)")
          }
          if !loading, content?.videos.isEmpty == true {
            Text("No past broadcasts are available for this channel.").foregroundStyle(.secondary)
          }
        }
      }
      .padding()
    }
    .navigationTitle(channel.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(.visible, for: .navigationBar)
    .accessibilityIdentifier("mobile-channel-profile")
    .task(id: channel.channelKey) { await refresh() }
    .refreshable { await refresh() }
    .fullScreenCover(item: $selectedVideo) { MobileVODPlayerView(selection: $0) }
  }

  private func refresh() async {
    loading = true
    errorMessage = nil
    async let loadedProfile = ChannelProfileService.fetch(login: channel.login)
    async let loadedContent = ChannelContentService.load(login: channel.login)
    let (newProfile, newContent) = await (loadedProfile, loadedContent)
    guard !Task.isCancelled else { return }
    profile = newProfile
    content = newContent
    if newProfile == nil || newContent == nil {
      errorMessage = "Could not load all channel details. Pull to refresh or try again."
    }
    loading = false
  }
}

struct MobileChannelProfileHeader: View {
  let channel: FollowedChannel
  let profile: ChannelProfile?
  let onLive: (FollowedChannel) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        CachedAsyncImage(url: profile?.profileImageURL ?? channel.profileImageURL) { image in
          image.resizable().scaledToFill()
        } placeholder: { Circle().fill(.quaternary) }
          .frame(width: 72, height: 72).clipShape(Circle())
        VStack(alignment: .leading, spacing: 4) {
          Text(profile?.displayName ?? channel.displayName).font(.title2.bold())
          Text((profile?.isLive ?? channel.isLive) ? "Live" : "Offline").foregroundStyle(.secondary)
          if let count = profile?.followerCount {
            Text("\(count.formatted(.number.notation(.compactName))) followers").font(.caption)
          }
        }
      }
      if let description = profile?.description { Text(description).font(.subheadline) }
      if profile?.isLive ?? channel.isLive {
        Button("Watch live") {
          onLive(FollowedChannel(id: channel.id, login: channel.login,
            displayName: profile?.displayName ?? channel.displayName,
            title: profile?.liveTitle ?? channel.title, gameName: profile?.liveGame ?? channel.gameName,
            viewerCount: profile?.liveViewerCount ?? channel.viewerCount,
            thumbnailURL: channel.thumbnailURL, profileImageURL: profile?.profileImageURL ?? channel.profileImageURL,
            isLive: true))
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }
}

struct MobileContinueWatchingSection: View {
  let entries: [MobileVODProgress]
  let onSelect: (MobileVODSelection) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Continue watching").font(.title3.bold()).accessibilityAddTraits(.isHeader)
      ForEach(entries) { entry in
        Button { onSelect(entry.selection) } label: {
          MobileBroadcastRow(video: entry.video, subtitle: entry.displayName, resumeSeconds: entry.seconds)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("resume-broadcast-\(entry.id)")
      }
    }
  }
}

struct MobileBroadcastRow: View {
  let video: ChannelVOD
  let subtitle: String?
  let resumeSeconds: Double
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    layout {
      CachedAsyncImage(url: video.thumbnailURL) { image in image.resizable().aspectRatio(contentMode: .fit) }
        placeholder: { Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit) }
        .frame(width: typeSize.isAccessibilitySize ? nil : 120)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 4) {
        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        Text(video.title).font(.headline).lineLimit(2)
        if resumeSeconds > 0 {
          Text("Resume at \(Duration.seconds(resumeSeconds).formatted(.time(pattern: .hourMinuteSecond)))")
            .font(.caption).foregroundStyle(.secondary)
        } else if let date = video.publishedAt {
          Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        if video.lengthSeconds > 0 {
          ProgressView(value: min(resumeSeconds, Double(video.lengthSeconds)), total: Double(video.lengthSeconds))
            .accessibilityLabel("Watch progress")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
