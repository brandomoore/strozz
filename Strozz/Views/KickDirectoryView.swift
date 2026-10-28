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
