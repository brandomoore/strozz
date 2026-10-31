import SwiftUI

struct KickDirectoryView: View {
  @State private var query: String
  @State private var channel: KickChannel?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @AppStorage("kickRecentChannels") private var recent = ""
  #if os(tvOS)
    @Environment(AppEnvironment.self) private var environment
    @State private var playback: KickChannel?
  #else
    @Environment(MobilePlaybackSession.self) private var playback
  #endif

  init(initialQuery: String = "") {
    #if DEBUG
      _query = State(
        initialValue: initialQuery.isEmpty
          && ProcessInfo.processInfo.environment["STROZZ_KICK_UI_FIXTURE"] == "1"
          ? ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc" : initialQuery)
    #else
      _query = State(initialValue: initialQuery)
    #endif
  }

  var body: some View {
    #if DEBUG
    if let scene = ProcessInfo.processInfo.environment["STROZZ_KICK_CONTENT_FIXTURE"] {
      KickContentFixture(slug: query, scene: scene)
    } else {
      directory
    }
    #else
    directory
    #endif
  }

  private var directory: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Watch Kick channels").font(.title2.bold())
          Text(
            "Find a creator by their Kick channel name or channel URL, including creators who don't stream on Twitch."
          )
          .foregroundStyle(.secondary)
          TextField("Kick channel or URL", text: $query)
            .autocorrectionDisabled()
            .accessibilityIdentifier("kick-channel-input")
          Button("Find channel") { Task { await lookup(query) } }
            .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("kick-find-channel")
          if isLoading { ProgressView("Finding channel") }
          if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
          if let channel {
            VStack(alignment: .leading, spacing: 8) {
              Text(channel.displayName).font(.headline)
              Text(channel.title).foregroundStyle(.secondary)
              if channel.isLive {
                Button("Watch live") { open(channel) }
                  .accessibilityIdentifier("kick-watch-live")
              } else {
                Text("Offline").foregroundStyle(.secondary)
              }
            }

          }
          if !recent.isEmpty {
            Text("Recent Kick channels").font(.headline)
            ForEach(recent.split(separator: ",").map(String.init), id: \.self) { slug in
              Button(slug) { Task { await lookup(slug, watch: true) } }
                .disabled(isLoading)
            }
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Kick")
      #if os(tvOS)
        .fullScreenCover(item: $playback) { channel in
          PlayerView(channel: channel.slug, auth: environment.auth, initialPlatform: .kick)
        }
      #endif
    }
  }

  private func lookup(_ requested: String, watch: Bool = false) async {
    query = requested
    isLoading = true
    errorMessage = nil
    channel = nil
    defer { isLoading = false }
    do {
      let found = try await KickPlaybackService.channel(requested)
      guard !Task.isCancelled, query == requested else { return }
      channel = found
      if watch, found.isLive { open(found) }
    } catch {
      guard !Task.isCancelled, query == requested else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func open(_ channel: KickChannel) {
    var slugs = recent.split(separator: ",").map(String.init).filter { $0 != channel.slug }
    slugs.insert(channel.slug, at: 0)
    recent = slugs.prefix(12).joined(separator: ",")
    #if os(tvOS)
      playback = channel
    #else
      playback.select(channel.followedChannel)
    #endif
  }
}

#if DEBUG
/// Launches real content surfaces directly when simulator input tooling is unavailable.
private struct KickContentFixture: View {
  let slug: String
  let scene: String
  @State private var content: KickChannelContentService.Content?
  @State private var broadcast: ChannelVOD?
  @State private var clips: [ChannelClip] = []
  @State private var errorMessage: String?
  @State private var browse = BrowseService()
  @State private var search = SearchService()
  @State private var selectedChannel: FollowedChannel?
  @State private var channelPageTarget: ChannelPageTarget?
  @State private var returnRefresh = PlaybackReturnRefreshCoordinator()
  @AppStorage(PersistenceKey.appTheme) private var theme = AppTheme.system
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationStack {
      Group {
        switch scene {
        case "profile":
          KickChannelDetailsView(slug: slug, onWatch: { selectedChannel = $0 })
        case "clip":
          if let clip = clips.first { ClipPlayerView(slug: clip.slug, title: clip.title) }
          else { status }
        case "broadcast":
          if let content, let video = broadcast {
            #if os(tvOS)
            OnDemandPlayerView(item: .vod(id: video.id, title: video.title), channelLogin: slug)
            #else
            MobileVODPlayerView(selection: .init(video: video,
              channel: .init(channel: content.channel.followedChannel)))
            #endif
          } else { status }
        case "categories":
          #if os(tvOS)
          BrowseCategoriesView(service: browse, isLoading: browse.isLoadingCategories,
            onSelectCategory: { _ in }, platformFilter: .constant(.kick))
          #else
          ScrollView {
            MobileCategoryGrid(categories: browse.categories, onSelect: { _ in },
              isLoading: browse.isLoadingCategories)
          }
          #endif
        case "search":
          #if os(tvOS)
          SearchView(selectedChannel: $selectedChannel, channelPageTarget: $channelPageTarget,
            service: search, initialQuery: slug)
          #else
          ScrollView {
            MobileSearchResults(service: search, onSelect: { selectedChannel = $0 }, retry: {})
          }
          #endif
        default:
          Text("Unknown Kick content fixture")
        }
      }
    }
    .environment(returnRefresh)
    .background(AppBackground(palette: theme.palette(systemColorScheme: colorScheme)))
    .environment(\.themePalette, theme.palette(systemColorScheme: colorScheme))
    .preferredColorScheme(theme.preferredColorScheme)
    .task(id: "\(scene):\(slug)") {
      do {
        switch scene {
        case "clip": clips = try await KickChannelContentService.clips(slug).clips
        case "broadcast":
          let loaded = try await KickChannelContentService.load(slug)
          let requestedID = ProcessInfo.processInfo.environment["STROZZ_KICK_BROADCAST_ID"]
          guard let video = loaded.videos.first(where: { requestedID == nil || $0.id == requestedID }) else {
            throw KickChannelContentService.Failure.unavailableBroadcast
          }
          content = loaded
          broadcast = video
        case "categories": await browse.loadCategories(filter: .kick)
        case "search":
          #if os(iOS)
          await search.search(slug, filter: .kick)
          #else
          break
          #endif
        default: break
        }
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }

  private var status: some View {
    Group {
      if let errorMessage { Text(errorMessage) }
      else { ProgressView("Loading Kick content") }
    }
  }
}
#endif
