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
    .init(video: video, channel: .init(login: login, displayName: displayName, profileImageURL: avatarURL))
  }
}

@MainActor
@Observable
final class MobileVODProgressStore {
  private(set) var entries: [MobileVODProgress]
  private let key: String
  private let defaults: UserDefaults

  init(accountID: String, defaults: UserDefaults = .standard) {
    key = PersistenceKey.mobileVODProgress(accountID: accountID)
    self.defaults = defaults
    entries = Defaults.load(forKey: key, from: defaults) ?? []
  }

  func progress(for id: String) -> Double { entries.first { $0.id == id }?.seconds ?? 0 }

  func save(_ selection: MobileVODSelection, seconds: Double, duration: Double) {
    guard seconds.isFinite, seconds > 0, duration.isFinite, duration > 0 else { return }
    entries.removeAll { $0.id == selection.id }
    if seconds < duration - 15 || seconds < duration * 0.95 {
      entries.insert(.init(video: selection.video, login: selection.channel.login,
        displayName: selection.channel.displayName ?? selection.channel.login,
        avatarURL: selection.channel.profileImageURL, seconds: min(seconds, duration), updatedAt: Date()), at: 0)
    }
    entries = Array(entries.prefix(80))
    Defaults.save(entries, forKey: key, to: defaults)
  }

  func clear() {
    entries = []
    Defaults.save(entries, forKey: key, to: defaults)
  }
}
