import Foundation

enum BroadcastUptime {
  static func duration(since startedAt: Date, now: Date) -> Duration? {
    let seconds = now.timeIntervalSince(startedAt)
    guard seconds.isFinite, seconds >= 0 else { return nil }
    return .seconds((seconds / 60).rounded(.down) * 60)
  }
}
