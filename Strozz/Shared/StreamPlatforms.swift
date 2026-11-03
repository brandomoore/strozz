import Foundation

enum StreamPlatforms: String, CaseIterable, Sendable {
  case both, twitch, kick

  static let storageKey = "streamPlatforms"
  static let onboardingKey = "didChooseStreamPlatforms"

  var includesTwitch: Bool { self != .kick }
  var includesKick: Bool { self != .twitch }

  func includes(_ platform: String) -> Bool {
    switch platform {
    case "twitch": includesTwitch
    case "kick": includesKick
    case "youtube": true
    default: false
    }
  }

  static func load(from defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .both
  }
}
