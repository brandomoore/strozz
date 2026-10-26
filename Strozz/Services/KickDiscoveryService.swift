import Foundation
import Observation
import OSLog

enum KickUnifiedFeed {
  /// Links are explicit creator identities, never a match on display name.
  static func merge(twitch: [FollowedChannel], kick: [KickChannel], links: [String: String]) -> [FollowedChannel] {
    let bySlug = Dictionary(kick.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    let owners = Dictionary(grouping: links, by: \.value)
    var consumed = Set<String>()
    var result = twitch.map { channel in
      guard channel.platform == .twitch, let slug = links[channel.login.lowercased()],
        owners[slug]?.count == 1,
        let linked = bySlug[slug], consumed.insert(slug).inserted else { return channel }
      if !channel.isLive, linked.isLive {
        var promoted = linked.followedChannel
        promoted.youtube = channel.youtube
        return promoted
      }
      var merged = channel
      merged.kick = linked
      return merged
    }
    result += kick.filter { !consumed.contains($0.slug) }.map(\.followedChannel)
    var seen = Set<String>()
    return result.filter { seen.insert($0.channelKey).inserted }
  }

  static func interleave(_ first: [FollowedChannel], _ second: [FollowedChannel]) -> [FollowedChannel] {
    var result: [FollowedChannel] = []
    var seen = Set<String>()
    for index in 0..<max(first.count, second.count) {
      for list in [first, second] where index < list.count {
        let item = list[index]
        if seen.insert(item.channelKey).inserted { result.append(item) }
      }
    }
    return result
  }
}

@MainActor
@Observable
final class KickDiscoveryService {
  let follows: KickFollowingStore
  private(set) var directory: [KickChannel] = []
  private(set) var recommended: [KickChannel] = []
  private(set) var links: [String: String] = [:]
  private(set) var errorMessage: String?
  private(set) var isRefreshing = false
  private(set) var lastUpdatedAt: Date?
  private var epoch = UUID()
  private var loadedConnection: UUID?
  private var loadedRoster: [KickFollow] = []
  private var nextLinkAttempt: [String: Date] = [:]
  private let load: @Sendable (String) async throws -> KickChannel
  private let resolve: @MainActor @Sendable (PlatformLiveTarget) async throws -> CreatorLiveSources
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "kick-discovery")

  init(follows: KickFollowingStore,
       load: @escaping @Sendable (String) async throws -> KickChannel = { try await KickPlaybackService.channel($0) },
       resolve: @escaping @MainActor @Sendable (PlatformLiveTarget) async throws -> CreatorLiveSources = CreatorSourceResolver.resolve) {
    self.follows = follows
    self.load = load
    self.resolve = resolve
  }

  func accountChanged() {
    epoch = UUID()
    loadedConnection = nil
    loadedRoster = []
    directory = []
    recommended = []
    links = [:]
    nextLinkAttempt = [:]
    errorMessage = nil
    lastUpdatedAt = nil
    isRefreshing = false
  }

  func applyRoster() {
    let document = follows.document
    if loadedConnection != document?.connectionID {
      accountChanged()
      loadedConnection = document?.connectionID
    }
    if loadedRoster != (document?.follows ?? []) {
      epoch = UUID()
      isRefreshing = false
      lastUpdatedAt = nil
      loadedRoster = document?.follows ?? []
    }
    let previous = Dictionary(directory.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    directory = (document?.follows ?? []).map { previous[$0.slug] ?? $0.channel }
  }

  func mergedFollowing(_ twitch: [FollowedChannel], liveOnly: Bool = false) -> [FollowedChannel] {
    KickUnifiedFeed.merge(twitch: twitch, kick: directory, links: links)
      .filter { !liveOnly || $0.isLive }
      .sorted {
        if $0.isLive != $1.isLive { return $0.isLive }
        if $0.isLive, $0.combinedViewerCount != $1.combinedViewerCount {
          return ($0.combinedViewerCount ?? 0) > ($1.combinedViewerCount ?? 0)
        }
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  func mergedRecommendations(_ twitch: [FollowedChannel], blocked: Set<String> = []) -> [FollowedChannel] {
    let candidates = recommended.filter(\.isLive)
    let merged = KickUnifiedFeed.merge(twitch: twitch, kick: candidates, links: links)
      .filter { !blocked.contains($0.channelKey) }
    return KickUnifiedFeed.interleave(
      merged.filter { $0.platform != .kick }, merged.filter { $0.platform == .kick })
  }

  func refresh(twitch: [FollowedChannel], force: Bool = false, preservingRecommendations: Bool = false) async {
    applyRoster()
    guard !isRefreshing, force || Date().timeIntervalSince(lastUpdatedAt ?? .distantPast) >= 60 else { return }
    let request = epoch
    isRefreshing = true
    defer { if epoch == request { isRefreshing = false } }
    let roster = follows.document?.follows ?? []
    let rosterSlugs = Set(roster.map(\.slug))
    var seen = Set<String>()
    let candidates = twitch.filter { $0.platform == .twitch && seen.insert($0.login.lowercased()).inserted }

    // Reuse explicit links already saved by Stream Source before doing any
    // background identity discovery. Spread uncached profile reads over refreshes.
    for channel in candidates {
      let root = PlatformLiveTarget(platform: .twitch, channel: channel.login)
      if let saved = CreatorLiveSession.savedSources(for: root) {
        links[channel.login.lowercased()] = saved.kick
        nextLinkAttempt[channel.login.lowercased()] = .distantFuture
      }
    }
    let loaded = await Self.loadChannels(roster.map(\.slug), load: load) {
      self.epoch == request
    }
    guard epoch == request, !Task.isCancelled else { return }
    let previous = Dictionary((directory + recommended).map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    directory = roster.map { loaded.channels[$0.slug] ?? previous[$0.slug] ?? $0.channel }
    errorMessage = loaded.failures == 0 ? nil
      : String(localized: "Some Kick channels couldn't be refreshed. Showing their last known status.")

    // Follow liveness is visible before slower creator-profile discovery.
    let missing = candidates.filter {
      Date() >= (nextLinkAttempt[$0.login.lowercased()] ?? .distantPast)
    }.prefix(24)
    let resolve = self.resolve
    let logger = Self.logger
    await withTaskGroup(of: (String, String?, Bool).self) { group in
      var iterator = missing.makeIterator()
      func enqueue(_ channel: FollowedChannel) {
        group.addTask {
          do {
            let sources = try await resolve(.init(platform: .twitch, channel: channel.login))
            return (channel.login.lowercased(), sources.kick, true)
          } catch {
            if !(error is CancellationError) {
              logger.warning("Kick creator link unavailable: \((error as NSError).domain) \((error as NSError).code)")
            }
            return (channel.login.lowercased(), nil, false)
          }
        }
      }
      for _ in 0..<4 { if let channel = iterator.next() { enqueue(channel) } }
      for await (login, slug, succeeded) in group {
        guard epoch == request, !Task.isCancelled else { group.cancelAll(); break }
        nextLinkAttempt[login] = Date().addingTimeInterval(succeeded ? 86_400 : 300)
        if succeeded { links[login] = slug }
        if let channel = iterator.next() { enqueue(channel) }
      }
    }
    guard epoch == request, !Task.isCancelled else { return }
    var suggested = Set(candidates.compactMap { links[$0.login.lowercased()] })
    if preservingRecommendations { suggested.formUnion(recommended.map(\.slug)) }
    suggested.subtract(rosterSlugs)
    let suggestions = await Self.loadChannels(suggested.sorted(), load: load) {
      self.epoch == request
    }
    guard epoch == request, !Task.isCancelled else { return }
    recommended = suggested.sorted().compactMap { suggestions.channels[$0] ?? previous[$0] }.filter(\.isLive)
    let failures = loaded.failures + suggestions.failures
    errorMessage = failures == 0 ? nil
      : String(localized: "Some Kick channels couldn't be refreshed. Showing their last known status.")
    if failures > 0 { Self.logger.warning("Kick metadata refresh failed for \(failures) channels") }
    lastUpdatedAt = Date()
  }

  private static func loadChannels(
    _ slugs: [String], load: @escaping @Sendable (String) async throws -> KickChannel,
    isCurrent: () -> Bool
  ) async -> (channels: [String: KickChannel], failures: Int) {
    await withTaskGroup(of: (String, KickChannel?).self) { group in
      var iterator = slugs.makeIterator()
      func enqueue(_ slug: String) {
        group.addTask {
          do { return (slug, try await load(slug)) }
          catch { return (slug, nil) }
        }
      }
      for _ in 0..<4 { if let slug = iterator.next() { enqueue(slug) } }
      var channels: [String: KickChannel] = [:]
      var failures = 0
      for await (slug, channel) in group {
        if Task.isCancelled || !isCurrent() { group.cancelAll(); break }
        if let channel { channels[slug] = channel } else { failures += 1 }
        if let next = iterator.next() { enqueue(next) }
      }
      return (channels, failures)
    }
  }
}
