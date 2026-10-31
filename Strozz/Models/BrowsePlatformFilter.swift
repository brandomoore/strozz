import Foundation

enum BrowsePlatformFilter: String, CaseIterable {
  case all, twitch, kick

  static let storageKey = "browsePlatformFilter"

  var title: LocalizedStringResource {
    switch self {
    case .all: "All"
    case .twitch: "Twitch"
    case .kick: "Kick"
    }
  }

  func includes(_ platform: LivePlatform) -> Bool {
    self == .all || rawValue == platform.rawValue
  }
}
