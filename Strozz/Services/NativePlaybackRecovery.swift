import Foundation

/// The same rolling budget covers source renewal, origin failures, startup failures, and stalls.
/// Brief network/timeline failures get fresh native attempts, not an immediate downgrade.
struct NativePlaybackRecovery {
  private(set) var attempts: [Date] = []
  static let maximumAttempts = 2
  static let windowSeconds: TimeInterval = 60

  func attemptsInWindow(at now: Date = Date()) -> Int {
    attempts.filter { now.timeIntervalSince($0) <= Self.windowSeconds }.count
  }

  func retryDelay(at now: Date = Date()) -> TimeInterval {
    let active = attempts.filter { now.timeIntervalSince($0) <= Self.windowSeconds }
    guard active.count >= Self.maximumAttempts, let first = active.first else { return 0 }
    return max(0, Self.windowSeconds - now.timeIntervalSince(first))
  }

  mutating func takeResolutionRetry(for error: Error, at now: Date = Date()) -> Bool {
    guard let error = error as? URLError else { return false }
    switch error.code {
    case .timedOut:
      return takeRetry(for: .timeout, at: now)
    case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      .dnsLookupFailed, .notConnectedToInternet:
      return takeRetry(for: .unavailable, at: now)
    default:
      return false
    }
  }

  mutating func takeRetry(for error: NativeHLSError, at now: Date = Date()) -> Bool {
    switch error {
    case .unsupported, .transportTable, .transportCodec, .partDuration:
      return false
    case .unavailable, .timeout, .transition, .invalidMedia, .indexerOverrun, .transportKeyframe:
      break
    }

    attempts.removeAll { now.timeIntervalSince($0) > Self.windowSeconds }
    guard attempts.count < Self.maximumAttempts else { return false }
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
