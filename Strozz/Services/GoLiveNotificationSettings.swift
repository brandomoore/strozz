import Foundation
import Observation
import OSLog

/// In-app alerts on this Apple TV only; never changes Twitch's bell preferences.
@MainActor
@Observable
final class GoLiveNotificationSettings {
  enum Mode: String, Codable {
    case off
    case all
    case selected
  }

  private struct Preferences: Codable, Equatable {
    var mode: Mode = .off
    var selectedLogins: Set<String> = []
    var hasPrompted = false
  }

  private static let log = Logger(subsystem: "com.thatcube.Strozz", category: "GoLiveAlerts")
  private let defaults: UserDefaults
  private var preferences: Preferences

  /// The shared watcher immediately drops alerts made ineligible by an edit.
  @ObservationIgnored var onSelectionChange: (() -> Void)?

  var mode: Mode { preferences.mode }
  var hasPrompted: Bool { preferences.hasPrompted }
  var hasEnabledChannels: Bool {
    mode == .all || (mode == .selected && !preferences.selectedLogins.isEmpty)
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // V1 was implicitly on. Do not treat those old values or mutes as consent:
    // both fresh installs and existing installs start off and get one new ask.
    if let data = defaults.data(forKey: PersistenceKey.goLivePreferences) {
      do {
        preferences = try JSONDecoder().decode(Preferences.self, from: data)
      } catch {
        Self.log.error("Invalid go-live preferences; alerts remain off until configured again")
        preferences = Preferences()
      }
    } else {
      preferences = Preferences()
    }
  }

  func isAlerting(login: String) -> Bool {
    let key = Self.normalize(login)
    guard !key.isEmpty else { return false }
    switch mode {
    case .off: return false
    case .all: return true
    case .selected: return preferences.selectedLogins.contains(key)
    }
  }

  func markPromptPresented() {
    guard !hasPrompted else { return }
    preferences.hasPrompted = true
    persist()
  }

  func disableAll() {
    update(mode: .off, selectedLogins: [])
  }

  /// Includes future follows until a per-channel edit switches to a custom list.
  func enableAll() {
    update(mode: .all, selectedLogins: [])
  }

  /// Opening the picker from Off starts empty. Opening it from All does not
  /// change that policy until a channel is actually switched off.
  func beginChoosingChannels() {
    if mode == .off {
      update(mode: .selected, selectedLogins: [])
    } else {
      markPromptPresented()
    }
  }

  func setAlerting(_ on: Bool, login: String, followedLogins: [String]) {
    setAlerting(on, logins: [login], followedLogins: followedLogins)
  }

  /// `followedLogins` is the full, unfiltered directory. When leaving All,
  /// snapshot every current follow, not just search matches or live channels.
  func setAlerting(_ on: Bool, logins: [String], followedLogins: [String]) {
    let keys = Set(logins.map(Self.normalize).filter { !$0.isEmpty })
    guard !keys.isEmpty else {
      Self.log.error("Cannot change go-live alerts without a channel login")
      return
    }
    if mode == .all && on { return }
    let selection = mode == .all
      ? Set(followedLogins.map(Self.normalize).filter { !$0.isEmpty })
      : preferences.selectedLogins
    update(mode: .selected, selectedLogins: on ? selection.union(keys) : selection.subtracting(keys))
  }

  private func update(mode: Mode, selectedLogins: Set<String>) {
    let updated = Preferences(mode: mode, selectedLogins: selectedLogins, hasPrompted: true)
    guard updated != preferences else { return }
    preferences = updated
    persist()
    onSelectionChange?()
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(preferences)
      defaults.set(data, forKey: PersistenceKey.goLivePreferences)
    } catch {
      Self.log.error("Could not save go-live preferences (code \((error as NSError).code))")
    }
  }

  private static func normalize(_ login: String) -> String {
    login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
