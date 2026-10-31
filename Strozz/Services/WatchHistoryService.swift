import Foundation
import Observation

/// User-facing preference keys for personalization. Kept in a non-isolated enum
/// so SwiftUI `@AppStorage` and other call sites can reference the key without
/// touching the `@MainActor`-isolated service.
enum RecommendationPreferences {
  /// Whether personalized "Recommended for you" is on. Defaults to enabled.
  static let enabledDefaultsKey = PersistenceKey.personalizedRecommendationsEnabled
}

/// One channel the viewer has watched, used purely to personalize recommendations.
struct WatchHistoryEntry: Codable, Identifiable, Sendable {
  var id: String { channelKey }
  var login: String
  var displayName: String
  var gameName: String
  var viewerCount: Int?
  var lastWatchedAt: Date
  var watchCount: Int
  var sourcePlatform: LivePlatform? = nil
  var platform: LivePlatform { sourcePlatform ?? .twitch }
  var channelKey: String { platform == .twitch ? login.lowercased() : "\(platform.rawValue):\(login.lowercased())" }
}

/// Records which channels the viewer watches so recommendations can reflect their
/// actual taste — **entirely on-device**.
///
/// History and watch counts stay in this device's `UserDefaults` and can be
/// disabled or cleared in Settings. Discovery requests channel/category metadata
/// from the respective platforms; it does not upload the stored history.
@MainActor
@Observable
final class WatchHistoryService {
  private let storageKey: String
  private static let maxEntries = 120
  /// Watches this old contribute half the weight of a fresh watch.
  private static let recencyHalfLife: TimeInterval = 14 * 24 * 3600

  private(set) var entries: [WatchHistoryEntry] = []

  /// On-device personalization switch, mirrored from `UserDefaults` so the
  /// Settings toggle and this service always agree. Defaults to on.
  var isEnabled: Bool {
    UserDefaults.standard.object(forKey: RecommendationPreferences.enabledDefaultsKey) as? Bool ?? true
  }

  init(storageKey: String = PersistenceKey.watchHistoryEntries) {
    self.storageKey = storageKey
    load()
  }

  /// Records a watch of `channel`. No-op when personalization is disabled or the
  /// channel has no login. Existing channels are bumped to most-recent.
  func record(_ channel: FollowedChannel) {
    guard isEnabled, channel.platform == .twitch || channel.platform == .kick else { return }
    let login = channel.login.lowercased()
    guard !login.isEmpty else { return }

    let now = Date()
    if let index = entries.firstIndex(where: { $0.channelKey == channel.channelKey }) {
      var entry = entries.remove(at: index)
      entry.lastWatchedAt = now
      entry.watchCount += 1
      entry.displayName = channel.displayName
      if !channel.gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        entry.gameName = channel.gameName
      }
      if let viewers = channel.combinedViewerCount { entry.viewerCount = viewers }
      entries.insert(entry, at: 0)
    } else {
      entries.insert(
        WatchHistoryEntry(
          login: login,
          displayName: channel.displayName,
          gameName: channel.gameName,
          viewerCount: channel.combinedViewerCount,
          lastWatchedAt: now,
          watchCount: 1,
          sourcePlatform: channel.platform
        ),
        at: 0
      )
    }

    if entries.count > Self.maxEntries {
      entries = Array(entries.prefix(Self.maxEntries))
    }
    persist()
  }

  /// Permanently forgets all watch history from this device.
  func clear() {
    entries = []
    persist()
  }

  /// Twitch-only logins for callers of the Twitch affinity API.
  var recentLogins: [String] {
    entries.filter { $0.platform == .twitch }.map(\.login)
  }

  /// Category name -> recency-weighted affinity (unnormalized). Recent, repeated
  /// watches of a category count for more, so the profile tracks current taste.
  func categoryAffinities(now: Date = Date()) -> [String: Double] {
    var weights: [String: Double] = [:]
    for entry in entries {
      let game = entry.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !game.isEmpty, game.caseInsensitiveCompare("live") != .orderedSame else { continue }
      let age = now.timeIntervalSince(entry.lastWatchedAt)
      let recency = pow(0.5, max(age, 0) / Self.recencyHalfLife)
      weights[game, default: 0] += recency * Double(max(entry.watchCount, 1))
    }
    return weights
  }

  /// Median concurrent-viewer count across watched channels, used to favor
  /// similarly-sized peers when ranking recommendations.
  var medianViewerTier: Int? {
    let counts = entries.compactMap(\.viewerCount).filter { $0 > 0 }.sorted()
    guard !counts.isEmpty else { return nil }
    let mid = counts.count / 2
    return counts.count.isMultiple(of: 2) ? (counts[mid - 1] + counts[mid]) / 2 : counts[mid]
  }

  // MARK: - Persistence (local UserDefaults only)

  private func load() {
    if let decoded: [WatchHistoryEntry] = Defaults.load(forKey: storageKey) {
      entries = decoded
    }
  }

  /// Serial queue so JSON encoding and the UserDefaults write happen off the
  /// main thread (record() runs at playback start) while preserving write order.
  private static let persistQueue = DispatchQueue(
    label: "com.thatcube.Strozz.watchHistory.persist", qos: .utility)

  private func persist() {
    let snapshot = entries
    let key = storageKey
    Self.persistQueue.async {
      Defaults.save(snapshot, forKey: key)
    }
  }
}
