import Foundation
import Observation

struct MobileVODSelection: Identifiable, Hashable {
  let video: ChannelVOD
  let channel: ChannelPageTarget
  var id: String { video.id }
}

struct MobileVODProgress: Codable, Identifiable {
  let video: ChannelVOD
  let login: String
  let displayName: String
  let avatarURL: URL?
  let seconds: Double
  let updatedAt: Date
  var id: String { video.id }
  var selection: MobileVODSelection {
    var channel = ChannelPageTarget(login: login, displayName: displayName, profileImageURL: avatarURL)
    channel.platform = video.platform
    return .init(video: video, channel: channel)
  }
}

@MainActor
@Observable
final class MobileVODProgressStore {
  private var storedEntries: [MobileVODProgress]
  var entries: [MobileVODProgress] {
    storedEntries.filter { StreamPlatformPreferences.shared.selection.includes($0.video.platform) }
  }
  private let key: String
  private let defaults: UserDefaults

  init(accountID: String, defaults: UserDefaults = .standard) {
    key = PersistenceKey.mobileVODProgress(accountID: accountID)
    self.defaults = defaults
    storedEntries = Defaults.load(forKey: key, from: defaults) ?? []
  }

  func progress(for id: String) -> Double { storedEntries.first { $0.id == id }?.seconds ?? 0 }

  func save(_ selection: MobileVODSelection, seconds: Double, duration: Double) {
    guard seconds.isFinite, seconds > 0, duration.isFinite, duration > 0 else { return }
    storedEntries.removeAll { $0.id == selection.id }
    if seconds < duration - 15 || seconds < duration * 0.95 {
      storedEntries.insert(.init(video: selection.video, login: selection.channel.login,
        displayName: selection.channel.displayName ?? selection.channel.login,
        avatarURL: selection.channel.profileImageURL, seconds: min(seconds, duration), updatedAt: Date()), at: 0)
    }
    storedEntries = Array(storedEntries.prefix(80))
    Defaults.save(storedEntries, forKey: key, to: defaults)
  }

  func clear() {
    storedEntries = []
    Defaults.save(storedEntries, forKey: key, to: defaults)
  }
}
