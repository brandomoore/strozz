import Foundation
import Observation
import OSLog

/// Public facade for the signed-in viewer's followed channels.
///
/// Owns the observable state that the UI binds to (the live "Following" rail,
/// the full Following directory, the follow-category profile, plus loading and
/// error flags) and the orchestration that decides *when* to fetch live data,
/// show anonymous trending content, refresh expired tokens, or enrich with
/// YouTube presence. The heavy lifting is delegated to focused, Foundation-only
/// collaborators so this type stays a thin coordinator:
///
/// - `FollowedChannelsFetcher` — every Twitch Helix round-trip plus decode and
///   model mapping.
/// - `FollowedChannelsDemoProvider` — anonymous trending + hand-curated demo
///   channels used as fallbacks.
/// - `FollowedChannelsAvatarPrewarmer` — best-effort avatar image prewarming.
///
/// The public surface (type name, observable properties, and the `refresh`,
/// `loadDirectory`, and `applyYouTubePresence` methods) is unchanged.
@MainActor
@Observable
final class FollowedChannelsService {
  private static let disallowedClientIDs: Set<String> = [
    // Twitch web public client. Device flow consent appears as "Twilight"
    // and followed-channel APIs can fail unexpectedly.
    TwitchConfig.webPublicClientID
  ]

  private let fetcher: FollowedChannelsFetcher
  private let demoProvider: FollowedChannelsDemoProvider
  private let avatarPrewarmer = FollowedChannelsAvatarPrewarmer()
  private var accountID: String?
  private var refreshID = UUID()
  private var directoryRequestID = UUID()
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "following")

  init(loadData: @escaping NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }) {
    fetcher = FollowedChannelsFetcher(loadData: loadData)
    demoProvider = FollowedChannelsDemoProvider(loadData: loadData)
  }

  private struct Account: Equatable {
    let userID: String?
    let authenticated: Bool
    let generation: UUID

    @MainActor init(_ auth: TwitchAuthSession) {
      userID = auth.userID
      authenticated = auth.isAuthenticated
      generation = auth.sessionGeneration
    }
  }

  /// Clear another account's data immediately, but retain this account's last good
  /// results while its connection is being recovered.
  func accountChanged(using auth: TwitchAuthSession) {
    guard accountID != auth.userID else { return }
    accountID = auth.userID
    refreshID = UUID()
    directoryRequestID = UUID()
    channels = []
    directory = []
    followedCategories = [:]
    followedLogins = []
    isUsingDemoData = false
    isLoading = false
    isLoadingDirectory = false
    errorMessage = nil
    directoryErrorMessage = nil
    lastUpdatedAt = nil
    directoryLoadedAt = nil
  }

  private(set) var channels: [FollowedChannel] = [] {
    didSet { avatarPrewarmer.prewarm(channels) }
  }
  /// Category name -> number of followed channels (online **and** offline) whose
  /// last/current broadcast was in that category. Drives the personalized
  /// recommendation profile so it reflects the whole follow list, not just whoever
  /// happens to be live. Empty in demo mode or when the lookup fails.
  private(set) var followedCategories: [String: Int] = [:]
  /// Lowercased logins of every channel the viewer follows (online and offline),
  /// used to guarantee recommendations never include someone they already follow —
  /// even a live follow beyond the first page of `/streams/followed`.
  private(set) var followedLogins: Set<String> = []
  private(set) var isLoading = false
  private(set) var isUsingDemoData = false
  private(set) var errorMessage: String?
  /// Last successful refresh, never a failed attempt or cancelled request.
  private(set) var lastUpdatedAt: Date?

  func needsRefresh(staleAfter interval: TimeInterval, now: Date = Date()) -> Bool {
    guard !isLoading else { return false }
    guard errorMessage == nil, let lastUpdatedAt else { return true }
    return now.timeIntervalSince(lastUpdatedAt) >= interval
  }

  /// The full "Following" directory — every channel the viewer follows, live
  /// **and** offline — sorted live-first. Populated lazily by `loadDirectory`
  /// when the directory screen opens, so its heavier multi-batch fetch never
  /// runs as part of the Home refresh.
  private(set) var directory: [FollowedChannel] = [] {
    didSet { avatarPrewarmer.prewarm(directory) }
  }
  private(set) var isLoadingDirectory = false
  private(set) var directoryErrorMessage: String?
  private(set) var directoryLoadedAt: Date?

  /// Merges live YouTube presence into the current Twitch-followed channels and
  /// directory so a dual-platform streamer shows as one card with both Twitch
  /// and YouTube viewers. Called after `refresh`/`loadDirectory` from the view
  /// layer, which owns the (downloaded, parameter-free) alias + snapshot
  /// services. A streamer with no known YouTube mapping, or who isn't currently
  /// live on YouTube, has its `youtube` presence cleared so stale data never
  /// lingers.
  func applyYouTubePresence(
    aliases: TwitchYouTubeAliasService,
    live: YouTubeLiveSnapshotService
  ) {
    func enrich(_ channel: FollowedChannel) -> FollowedChannel {
      var updated = channel
      if let channelID = aliases.youtubeChannelID(forTwitchLogin: channel.login),
        let presence = live.presence(forChannelID: channelID),
        presence.isLive {
        updated.youtube = presence
      } else {
        updated.youtube = nil
      }
      return updated
    }

    channels = channels.map(enrich)
    if !directory.isEmpty {
      directory = directory.map(enrich)
    }
  }

  func refresh(using auth: TwitchAuthSession) async {
    guard !Task.isCancelled else { return }
    accountChanged(using: auth)
    let account = Account(auth)
    let request = UUID()
    refreshID = request
    isLoading = true
    errorMessage = nil

    defer { if refreshID == request { isLoading = false } }
    func isCurrent() -> Bool {
      !Task.isCancelled && refreshID == request && Account(auth) == account
    }

    guard auth.isAuthenticated else {
      // False authentication can mean "restoring", not an anonymous viewer.
      if auth.userID != nil || auth.accessToken != nil || auth.refreshToken != nil
        || auth.cloudSync?.isRestoringAccount == true
        || (auth.cloudSync?.isSignedOutLocally != true
          && (auth.cloudSync?.errorMessage != nil || auth.errorMessage != nil)) {
        errorMessage = auth.errorMessage ?? auth.cloudSync?.errorMessage
        return
      }
      do {
        let trending = try await demoProvider.fetchTrendingChannels()
        guard isCurrent() else { return }
        isUsingDemoData = true
        channels = trending.isEmpty ? FollowedChannelsDemoProvider.demoChannels : trending
        if trending.isEmpty { errorMessage = "Trending feed is empty right now. Showing fallback demo channels." }
        else { lastUpdatedAt = Date() }
      } catch {
        guard isCurrent(), !(error is CancellationError) else { return }
        channels = FollowedChannelsDemoProvider.demoChannels
        isUsingDemoData = true
        errorMessage = "Could not load trending channels. Showing fallback demo channels."
        Self.logger.error("Trending refresh failed: \((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
      }
      return
    }

    // A previous anonymous rail is not valid signed-in content.
    if isUsingDemoData {
      channels = []
      isUsingDemoData = false
      lastUpdatedAt = nil
    }
    guard let clientID = resolveClientID() else {
      errorMessage =
        "Cannot load followed channels until TWITCH_CLIENT_ID is set in Config/TwitchSecrets.xcconfig.local."
      return
    }

    if Self.disallowedClientIDs.contains(clientID.lowercased()) {
      errorMessage =
        "TWITCH_CLIENT_ID is using a public Twitch web client (shows \"Twilight\"). Create your own Twitch app and use its Client ID to load followed channels."
      return
    }

    guard let userID = auth.userID
    else {
      errorMessage = "Could not identify your Twitch account. Check your connection in Settings."
      return
    }

    do {
      let initialAccessToken = try await auth.refreshAccessTokenIfNeeded()
      guard isCurrent() else { return }
      let loaded: [FollowedChannel]
      do {
        loaded = try await fetcher.fetchLiveFollowedChannels(
          clientID: clientID, accessToken: initialAccessToken, userID: userID)
      } catch let error as TwitchHelixRequestError where error.status == 401 {
        guard isCurrent() else { return }
        let refreshedAccessToken = try await auth.recoverAccessToken(
          afterUnauthorized: initialAccessToken)
        guard isCurrent() else { return }
        loaded = try await fetcher.fetchLiveFollowedChannels(
          clientID: clientID,
          accessToken: refreshedAccessToken,
          userID: userID
        )
      }
      guard isCurrent() else { return }
      channels = loaded
      isUsingDemoData = false
      lastUpdatedAt = Date()
      await refreshFollowedCategories(clientID: clientID, accessToken: auth.accessToken ?? initialAccessToken,
        userID: userID, isCurrent: isCurrent)
    } catch {
      guard isCurrent(), !(error is CancellationError) else { return }
      let detail = describe(error)
      errorMessage = "Could not refresh followed channels (\(detail)). Try refreshing again."
      Self.logger.error("Following refresh failed: \((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
    }
  }

  /// Loads the full Following directory — every followed channel, live and
  /// offline — into `directory`, sorted live-first. Lazy and idempotent: a cached
  /// result is reused unless `force` is set. Requires a real authenticated
  /// session (the directory has no demo/trending equivalent).
  func loadDirectory(using auth: TwitchAuthSession, force: Bool = false) async {
    guard !Task.isCancelled else { return }
    accountChanged(using: auth)
    guard auth.isAuthenticated, let userID = auth.userID else { return }
    guard let clientID = resolveClientID(),
          !Self.disallowedClientIDs.contains(clientID.lowercased())
    else {
      directoryErrorMessage = "Could not load your follows. A valid Twitch application client ID is required."
      return
    }

    if !force, directoryLoadedAt != nil, directoryErrorMessage == nil { return }
    if isLoadingDirectory && !force { return }

    let account = Account(auth)
    let request = UUID()
    directoryRequestID = request
    isLoadingDirectory = true
    directoryErrorMessage = nil
    defer { if directoryRequestID == request { isLoadingDirectory = false } }
    func isCurrent() -> Bool {
      !Task.isCancelled && directoryRequestID == request && Account(auth) == account
    }

    let accessToken: String
    if let token = auth.accessToken {
      accessToken = token
    } else {
      do {
        accessToken = try await auth.refreshAccessTokenIfNeeded(force: true)
      } catch {
        guard isCurrent(), !(error is CancellationError) else { return }
        directoryErrorMessage =
          "Could not load your follows (\(describe(error)))."
        return
      }
    }

    do {
      guard isCurrent() else { return }
      let loaded = try await fetcher.fetchFollowingDirectory(
        clientID: clientID, accessToken: accessToken, userID: userID)
      guard isCurrent() else { return }
      directory = loaded
      directoryLoadedAt = Date()
    } catch let error as TwitchHelixRequestError where error.status == 401 {
      guard isCurrent() else { return }
      do {
        let refreshed = try await auth.recoverAccessToken(
          afterUnauthorized: accessToken)
        guard isCurrent() else { return }
        let loaded = try await fetcher.fetchFollowingDirectory(
          clientID: clientID, accessToken: refreshed, userID: userID)
        guard isCurrent() else { return }
        directory = loaded
        directoryLoadedAt = Date()
      } catch {
        guard isCurrent(), !(error is CancellationError) else { return }
        directoryErrorMessage = "Could not load your follows (\(describe(error)))."
      }
    } catch {
      guard isCurrent(), !(error is CancellationError) else { return }
      directoryErrorMessage = "Could not load your follows (\(describe(error)))."
    }
  }

  /// Loads the categories of every channel the viewer follows (online and offline)
  /// and tallies them by category. Best-effort: on any failure the previous
  /// profile is left intact so a transient error doesn't wipe recommendations.
  private func refreshFollowedCategories(clientID: String, accessToken: String, userID: String,
                                        isCurrent: () -> Bool) async {
    do {
      let follows = try await fetcher.fetchFollowedBroadcasters(
        clientID: clientID, accessToken: accessToken, userID: userID)
      guard isCurrent() else { return }
      let ids = follows.map(\.broadcasterID)
      guard !ids.isEmpty else {
        followedCategories = [:]
        followedLogins = []
        return
      }
      let logins = Set(
        follows.compactMap {
          let login = $0.broadcasterLogin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          return (login?.isEmpty == false) ? login : nil
        })
      let categories = try await fetcher.fetchChannelCategoryCounts(
        clientID: clientID, accessToken: accessToken, broadcasterIDs: ids)
      guard isCurrent() else { return }
      followedLogins = logins
      followedCategories = categories
    } catch {
      guard isCurrent(), !(error is CancellationError) else { return }
      Self.logger.warning("Follow category refresh failed; preserving previous profile: \((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
    }
  }

  private func resolveClientID() -> String? {
    guard let raw = Bundle.main.object(forInfoDictionaryKey: "TWITCH_CLIENT_ID") as? String else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("$(") || trimmed.contains("TWITCH_CLIENT_ID") {
      return nil
    }
    return trimmed
  }

  private func describe(_ error: Error) -> String {
    if let helixError = error as? TwitchHelixRequestError {
      return helixError.localizedDescription
    }
    return error.localizedDescription
  }
}
