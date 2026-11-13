import Foundation
import Observation

#if os(tvOS)
  import TVServices
#endif

@MainActor
@Observable
final class StreamPlatformPreferences {
  static let shared = StreamPlatformPreferences()

  var selection: StreamPlatforms {
    didSet {
      guard selection != oldValue else { return }
      defaults.set(selection.rawValue, forKey: StreamPlatforms.storageKey)
      defaults.set(selection.resolve(.all).rawValue, forKey: BrowsePlatformFilter.storageKey)
      publishSelection()
    }
  }
  private(set) var hasChosen: Bool
  private let defaults: UserDefaults
  private let shelfDefaults: UserDefaults?

  init(
    defaults: UserDefaults = .standard,
    shelfDefaults: UserDefaults? = UserDefaults(suiteName: TopShelf.appGroupID)
  ) {
    self.defaults = defaults
    self.shelfDefaults = shelfDefaults
    selection = StreamPlatforms.load(from: defaults)
    hasChosen = defaults.bool(forKey: StreamPlatforms.onboardingKey)
    publishSelection()
  }

  func completeOnboarding(_ selection: StreamPlatforms) {
    self.selection = selection
    defaults.set(true, forKey: StreamPlatforms.onboardingKey)
    hasChosen = true
  }

  private func publishSelection() {
    shelfDefaults?.set(selection.rawValue, forKey: StreamPlatforms.storageKey)
    #if os(tvOS)
      TVTopShelfContentProvider.topShelfContentDidChange()
    #endif
  }
}

extension StreamPlatforms {
  func includes(_ platform: LivePlatform) -> Bool { includes(platform.rawValue) }

  func filter(_ channels: [FollowedChannel]) -> [FollowedChannel] {
    channels.compactMap { channel in
      if !includes(channel.platform) || channel.hasUnsupportedLiveProtection {
        guard channel.platform == .twitch, includesKick, let kick = channel.kick else { return nil }
        var counterpart = kick.followedChannel
        counterpart.youtube = channel.youtube
        return counterpart
      }
      var channel = channel
      if !includesKick { channel.kick = nil }
      return channel
    }
  }

  func filter(_ sources: CreatorLiveSources) -> CreatorLiveSources {
    var sources = sources
    if !includesTwitch { sources.twitch = nil }
    if !includesKick { sources.kick = nil }
    return sources
  }

  func resolve(_ filter: BrowsePlatformFilter) -> BrowsePlatformFilter {
    switch self {
    case .both: filter
    case .twitch: .twitch
    case .kick: .kick
    }
  }
}
