import Foundation

/// Native catch-up is a forward correction after a sustained excess delay, not
/// a side effect of changing resolution. Owns at most one request per item.
struct NativeLiveCatchUp {
  static let minimumExcessSeconds: TimeInterval = 3
  static let settlingSeconds: TimeInterval = 4
  static let cooldownSeconds: TimeInterval = 15
  static let timeoutSeconds: TimeInterval = 5

  struct Sample {
    let uptime: TimeInterval
    let clock: Double
    let playbackDate: Date?
    let targetDate: Date?
    let rendition: String?
    let isPlaying: Bool
    let buffer: Double
    let allowed: Bool
  }

  struct Request {
    let id = UUID()
    let target: Date
    let startedAt: TimeInterval
  }

  private(set) var inFlight: Request?
  private var previous: Sample?
  private var settledSince: TimeInterval?
  private var behindSince: TimeInterval?
  private var lastFinishedAt: TimeInterval?

  mutating func observe(_ sample: Sample) -> Request? {
    guard inFlight == nil else { return nil }
    guard sample.allowed, sample.isPlaying, sample.buffer.isFinite, sample.buffer >= 1,
      sample.uptime.isFinite, sample.clock.isFinite, sample.rendition != nil,
      let playback = sample.playbackDate, let target = sample.targetDate,
      playback.timeIntervalSinceReferenceDate.isFinite, target.timeIntervalSinceReferenceDate.isFinite
    else {
      clearObservations()
      return nil
    }
    defer { previous = sample }
    if let previous, let previousDate = previous.playbackDate {
      let elapsed = sample.uptime - previous.uptime
      let advance = sample.clock - previous.clock
      let dateAdvance = playback.timeIntervalSince(previousDate)
      if previous.rendition != sample.rendition || !(0.5...2.5).contains(elapsed)
        || advance < elapsed * 0.8 || advance > elapsed * 1.2
        || abs(advance - dateAdvance) > 0.5 {
        settledSince = sample.uptime
        behindSince = nil
      }
    } else {
      settledSince = sample.uptime
    }
    guard target.timeIntervalSince(playback) >= Self.minimumExcessSeconds else {
      behindSince = nil
      return nil
    }
    if behindSince == nil { behindSince = sample.uptime }
    guard let settledSince, let behindSince,
      sample.uptime - settledSince >= Self.settlingSeconds,
      sample.uptime - behindSince >= Self.settlingSeconds,
      lastFinishedAt.map({ sample.uptime - $0 >= Self.cooldownSeconds }) ?? true else { return nil }
    let request = Request(target: target, startedAt: sample.uptime)
    inFlight = request
    return request
  }

  func timedOut(at uptime: TimeInterval) -> Bool {
    inFlight.map { uptime - $0.startedAt >= Self.timeoutSeconds } ?? false
  }

  @discardableResult
  mutating func finish(_ id: UUID, at uptime: TimeInterval) -> Bool {
    guard inFlight?.id == id else { return false }
    inFlight = nil
    lastFinishedAt = uptime
    clearObservations()
    return true
  }

  mutating func interrupt(at uptime: TimeInterval) {
    if let request = inFlight { finish(request.id, at: uptime) }
    else { clearObservations() }
  }

  private mutating func clearObservations() {
    previous = nil
    settledSince = nil
    behindSince = nil
  }
}
