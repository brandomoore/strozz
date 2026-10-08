import Foundation

/// The same rolling budget covers origin failures, startup failures, and stalls.
/// Brief network/timeline failures get fresh native attempts, not an immediate downgrade.
struct NativePlaybackRecovery {
  private(set) var attempts: [Date] = []

  mutating func takeRetry(for error: NativeHLSError, at now: Date = Date()) -> Bool {
    switch error {
    case .unsupported, .transportTable, .transportCodec, .partDuration:
      return false
    case .unavailable, .timeout, .transition, .invalidMedia, .indexerOverrun, .transportKeyframe:
      break
    }

    attempts.removeAll { now.timeIntervalSince($0) > 60 }
    guard attempts.count < 2 else { return false }
    attempts.append(now)
    return true
  }
}

/// A refilled range is stronger evidence than AVPlayer's stale likely-to-keep-up
/// flag. Resume it once without seeking; escalate only if its clock stays stuck.
struct NativeBufferedStallRecovery {
  enum Action { case none, resume, awaitingProgress, restart }
  private var previousClock: Double?
  private var attemptedAt: TimeInterval?
  private var escalated = false

  mutating func observe(clock: Double, uptime: TimeInterval, buffer: Double?,
                        minimumBuffer: Double = 3, waiting: Bool, allowed: Bool) -> Action {
    guard allowed, clock.isFinite, uptime.isFinite else {
      self = Self()
      return .none
    }
    let previous = previousClock
    previousClock = clock
    if let previous, abs(clock - previous) >= 0.05 {
      attemptedAt = nil
      escalated = false
      return .none
    }
    if let attemptedAt {
      if !escalated, uptime - attemptedAt >= 5 {
        escalated = true
        return .restart
      }
      return .awaitingProgress
    }
    guard previous != nil, waiting, let buffer, buffer.isFinite,
      minimumBuffer.isFinite, buffer >= max(3, minimumBuffer) else { return .none }
    attemptedAt = uptime
    return .resume
  }
}
