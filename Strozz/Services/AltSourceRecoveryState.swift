import Foundation

/// One automatic fresh resolution per source selection, not per "playing" tick.
/// Recover terminal errors, a stuck clock, or repeated short stalls. Brief
/// clock progress must not hide a source that keeps running out of media.
struct AltSourceRecoveryState {
  let generation = UUID()
  private(set) var retryCount = 0
  private var terminalFailure = false
  private var lastClock: Double?
  private var lastProgressAt: TimeInterval?
  private var recentStalls: [TimeInterval] = []

  var canRetry: Bool { retryCount == 0 }

  static func retryDelay(sinceLastAttempt elapsed: TimeInterval) -> TimeInterval {
    max(0, 10 - elapsed)
  }

  mutating func beginItem() {
    terminalFailure = false
    lastClock = nil
    lastProgressAt = nil
    recentStalls.removeAll()
  }

  mutating func notePlaybackStall(now: TimeInterval) {
    recentStalls.removeAll { now - $0 > 30 }
    if let last = recentStalls.last, now - last < 1 { return }
    recentStalls.append(now)
    if recentStalls.count > 3 { recentStalls.removeFirst() }
  }

  func hasRepeatedStalls(now: TimeInterval) -> Bool {
    guard recentStalls.count == 3, let first = recentStalls.first else { return false }
    return now - first <= 30
  }

  mutating func noteTerminalFailure() {
    terminalFailure = true
  }

  mutating func beginRetry() -> Bool {
    guard canRetry else { return false }
    retryCount += 1
    return true
  }

  mutating func needsRecovery(clock: Double, shouldPlay: Bool, now: TimeInterval) -> Bool {
    guard shouldPlay else {
      lastClock = nil
      lastProgressAt = nil
      recentStalls.removeAll()
      return false
    }
    if terminalFailure || hasRepeatedStalls(now: now) { return true }
    if lastProgressAt == nil { lastProgressAt = now }
    if clock.isFinite, lastClock == nil || abs(clock - (lastClock ?? clock)) > 0.05 {
      lastClock = clock
      lastProgressAt = now
    }
    return now - (lastProgressAt ?? now) >= 20
  }
}
