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
