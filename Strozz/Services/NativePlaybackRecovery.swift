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

/// Recover a refilled wait or an unrequested pause once, then require clock
/// progress. The caller owns viewer intent, interruption and lifecycle gates.
struct NativeBufferedStallRecovery {
  enum Action { case none, resume, resumePaused, awaitingProgress, restart }
  private var previousClock: Double?
  private var pausedSince: TimeInterval?
  private var attemptedAt: TimeInterval?
  private var escalated = false

  mutating func observe(clock: Double, uptime: TimeInterval, buffer: Double?,
                        minimumBuffer: Double = 3, waiting: Bool, paused: Bool = false,
                        allowed: Bool) -> Action {
    guard allowed, clock.isFinite, uptime.isFinite else {
      self = Self()
      return .none
    }
    let previous = previousClock
    previousClock = clock
    if let previous, abs(clock - previous) >= 0.05 {
      pausedSince = nil
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
    if paused {
      if pausedSince == nil { pausedSince = uptime }
      guard let pausedSince, uptime - pausedSince >= 2 else { return .none }
      attemptedAt = uptime
      return .resumePaused
    }
    pausedSince = nil
    guard previous != nil, waiting, let buffer, buffer.isFinite,
      minimumBuffer.isFinite, buffer >= max(3, minimumBuffer) else { return .none }
    attemptedAt = uptime
    return .resume
  }
}
