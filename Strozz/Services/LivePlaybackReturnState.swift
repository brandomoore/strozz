import Foundation

/// Keep the original viewing intent through overlapping channel-page/app trips.
/// Restore only when the player is visible again, and consume each trip once.
struct LivePlaybackReturnState {
  enum Absence: Hashable {
    case background
    case channelPage
  }

  private var absences: Set<Absence> = []
  private var departedAt: Date?
  private var wasFollowingLive = false

  var isAway: Bool { !absences.isEmpty }

  mutating func leave(_ absence: Absence, followingLive: Bool, now: Date = Date()) {
    if absences.isEmpty {
      departedAt = now
      wasFollowingLive = followingLive
    }
    absences.insert(absence)
  }

  mutating func returnFrom(
    _ absence: Absence,
    canFollowLive: Bool,
    isAtLiveEdge: Bool,
    now: Date = Date()
  ) -> Bool {
    guard absences.remove(absence) != nil, absences.isEmpty else { return false }
    defer { self = Self() }
    guard wasFollowingLive, canFollowLive, let departedAt else { return false }
    // A brief trip that stayed near live needs no reload. After suspension the
    // old seekable tail can itself be stale, so longer trips refresh regardless.
    return now.timeIntervalSince(departedAt) >= 5 || !isAtLiveEdge
  }
}
