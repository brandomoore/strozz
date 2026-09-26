import SwiftUI

/// Settings sub-page: choose which followed channels surface the in-app
/// "just went live" toast.
///
/// Opt-in model: start empty, enable all, or choose individual channels.
/// Leaving All snapshots current follows; new follows then remain off.
///
/// This is a second-level detail page, so it hides the top tab bar and presents
/// as a focused full-screen list.
struct GoLiveAlertsSettingsView: View {
  var follows: FollowedChannelsService
  let settings: GoLiveNotificationSettings
  let auth: TwitchAuthSession

  @Environment(\.themePalette) private var palette
  @State private var searchText = ""

  /// The full follow list (live + offline) from the shared Following directory,
  /// sorted by name so the picker is easy to scan. Reuses `loadDirectory` rather
  /// than fetching the follow list a second time.
  private var broadcasters: [FollowedChannel] {
    follows.directory.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  /// `broadcasters` narrowed by the search field — matches display name or login,
  /// case-insensitively — so ~100 follows stay findable.
  private var filteredBroadcasters: [FollowedChannel] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return broadcasters }
    return broadcasters.filter {
      $0.displayName.localizedCaseInsensitiveContains(query)
        || $0.login.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      List {
        channelsSection
      }
    }
    .navigationTitle("Go Live Alerts")
    .toolbar(.hidden, for: .tabBar)
    .searchable(
      text: $searchText,
      placement: .automatic,
      prompt: "Search channels"
    )
    .task {
      settings.beginChoosingChannels()
      await follows.loadDirectory(using: auth, force: true)
    }
  }

  /// Whether a search query is currently narrowing the list.
  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Channels a bulk action affects: the visible (filtered) rows. With no search
  /// this is every follow; while searching it's just the matches, so the viewer
  /// can "find a group, toggle them."
  private var bulkTargets: [FollowedChannel] {
    filteredBroadcasters
  }

  /// Enabling all visible rows manually never silently opts into future follows.
  /// Only the explicitly named Enable All action selects the All policy.
  @ViewBuilder
  private var bulkActionButton: some View {
    if isSearching {
      Button("Enable Matches") {
        settings.setAlerting(true, logins: bulkTargets.map(\.login), followedLogins: broadcasters.map(\.login))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
      .disabled(bulkTargets.isEmpty || follows.isLoadingDirectory || follows.directoryErrorMessage != nil)
      Button("Disable Matches") {
        settings.setAlerting(false, logins: bulkTargets.map(\.login), followedLogins: broadcasters.map(\.login))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tint)
      .disabled(bulkTargets.isEmpty || follows.isLoadingDirectory || follows.directoryErrorMessage != nil)
    } else {
      Button("Enable All") { settings.enableAll() }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      Button("Disable All") { settings.disableAll() }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
  }

  @ViewBuilder
  private var channelsSection: some View {
    Section {
      if let error = follows.directoryErrorMessage {
        Text(error)
          .foregroundStyle(.secondary)
        Button("Retry") {
          Task { await follows.loadDirectory(using: auth, force: true) }
        }
      } else if broadcasters.isEmpty {
        if follows.isLoadingDirectory {
          loadingState
        } else {
          emptyState
        }
      } else if filteredBroadcasters.isEmpty {
        noMatchesState
      } else {
        ForEach(filteredBroadcasters) { channel in
          Toggle(isOn: binding(for: channel)) {
            channelLabel(channel)
          }
          .disabled(follows.isLoadingDirectory)
        }
      }
    } header: {
      HStack {
        Text("Channels")
        Spacer()
        bulkActionButton
      }
    } footer: {
      Text(footerText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var footerText: LocalizedStringResource {
    if isSearching {
      return "Match actions affect only your search results. Turning any channel off switches to a custom selection, where future follows start off."
    }
    switch settings.mode {
    case .off:
      return "Alerts are off. Enable a channel individually or choose Enable All."
    case .all:
      return "All current and future follows will alert. Turning any channel off switches to a custom selection, where future follows start off."
    case .selected:
      return "Only the channels you switch on will alert. Future follows start off. Enable All includes current and future follows."
    }
  }

  private func channelLabel(_ channel: FollowedChannel) -> some View {
    HStack(spacing: 16) {
      avatar(for: channel)
      VStack(alignment: .leading, spacing: 2) {
        Text(channel.displayName)
          .font(.headline)
          .lineLimit(1)
        if channel.login.caseInsensitiveCompare(channel.displayName) != .orderedSame {
          Text("@\(channel.login)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func avatar(for channel: FollowedChannel) -> some View {
    CachedAsyncImage(url: channel.profileImageURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Circle().fill(.ultraThinMaterial)
        Icon(glyph: .userCircle, size: 30)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 56, height: 56)
    .clipShape(Circle())
  }

  private var loadingState: some View {
    HStack(spacing: 16) {
      ProgressView()
      Text("Loading your follows…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    HStack(spacing: 16) {
      Icon(glyph: .userCircle, size: 30)
        .foregroundStyle(.secondary)
      Text("No followed channels yet. Sign in and follow channels to choose which ones alert you.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 8)
  }

  private var noMatchesState: some View {
    Text("No channels match “\(searchText)”.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.vertical, 8)
  }

  private func binding(for channel: FollowedChannel) -> Binding<Bool> {
    Binding(
      get: { settings.isAlerting(login: channel.login) },
      set: { settings.setAlerting($0, login: channel.login, followedLogins: broadcasters.map(\.login)) }
    )
  }
}
