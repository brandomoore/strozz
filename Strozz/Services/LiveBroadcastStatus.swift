import Foundation

/// A failed lookup or disconnected event transport is unknown, never offline.
enum StreamLiveStatus: String, Sendable {
  case live, offline, unknown
}

struct TwitchBroadcastState: Equatable, Sendable {
  private(set) var status = StreamLiveStatus.unknown
  private(set) var revision = UUID()
  private var observedAt: Date?
  private var latestServerTime: Double?

  mutating func reset() {
    status = .unknown
    latestServerTime = nil
    observedAt = nil
    revision = UUID()
  }

  @discardableResult
  mutating func receive(type: String, serverTime: Double?, at now: Date = Date()) -> Bool {
    let next: StreamLiveStatus
    switch type {
    case "stream-down": next = .offline
    case "stream-up": next = .live
    default: return false
    }
    if let serverTime {
      guard serverTime.isFinite, serverTime >= 0,
        latestServerTime.map({ serverTime > $0 }) ?? true else { return false }
      latestServerTime = serverTime
    }
    status = next
    observedAt = now
    revision = UUID()
    return true
  }

  func acceptsStatusCheck(startedRevision: UUID, at now: Date) -> Bool {
    guard startedRevision == revision else { return false }
    // Give push events precedence over briefly stale API metadata, but continue
    // checking for missed events even when the socket still appears connected.
    return observedAt.map { now.timeIntervalSince($0) >= 10 } ?? true
  }
}

enum BroadcastEndPolicy {
  static func shouldPresentOffline(
    playbackAllowed: Bool, hasItem: Bool, terminalFailure: Bool,
    atLiveEdge: Bool, bufferAhead: Double?, stalled: Bool, reachedEnd: Bool
  ) -> Bool {
    guard playbackAllowed else { return false }
    if reachedEnd || terminalFailure || !hasItem { return true }
    // Keep healthy video, including the final buffered frames and DVR, playable.
    guard atLiveEdge, stalled, let bufferAhead, bufferAhead.isFinite else { return false }
    return (0...0.15).contains(bufferAhead)
  }
}
