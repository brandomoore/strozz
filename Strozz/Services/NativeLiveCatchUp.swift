import Foundation

/// Recover small live drift by consuming buffered video slightly faster, never
/// by seeking or replacing the item. Rebuffering and manual intent take priority.
struct NativeLiveCatchUp {
  enum Interruption: String {
    case cancelled, unavailableSample, renditionChanged, samplingGap, clockChanged, dateChanged, rateReset, reachedLive
  }
  static let minimumExcessSeconds: TimeInterval = 3
  static let startupToleranceSeconds: TimeInterval = 1.5
  static let settlingSeconds: TimeInterval = 4
  static let minimumBufferSeconds: TimeInterval = 0.75
  static let startBufferSeconds: TimeInterval = 2
  static let maximumRate: Float = 1.05
  static let settledExcessSeconds: TimeInterval = 0.75
  static let cooldownSeconds: TimeInterval = 15

  struct Sample {
    let uptime: TimeInterval
    let clock: Double
    let playbackDate: Date?
    let targetDate: Date?
    let rendition: String?
    let isPlaying: Bool
    let buffer: Double
    let allowed: Bool
    var hasFreshVideo = true
    var playbackRate: Float = 1
    var normalOffset: TimeInterval = 0
  }

  private(set) var rate: Float = 1
  private(set) var extraDelay: TimeInterval?
  private(set) var lastInterruption: Interruption?
  private(set) var dateClockDifference: Double?
  var isActive: Bool { rate > 1 }

  private var previous: Sample?
  private var settledSince: TimeInterval?
  private var behindSince: TimeInterval?
  private var cooldownUntil: TimeInterval = -.infinity

  mutating func observe(_ sample: Sample) -> Float {
    guard sample.allowed, sample.isPlaying, sample.hasFreshVideo,
      sample.buffer.isFinite, sample.buffer >= Self.minimumBufferSeconds,
      sample.playbackRate.isFinite, (1...Self.maximumRate + 0.001).contains(sample.playbackRate),
      sample.normalOffset.isFinite, sample.normalOffset >= 0,
      sample.uptime.isFinite, sample.clock.isFinite, sample.rendition != nil,
      let playback = sample.playbackDate, let target = sample.targetDate,
      playback.timeIntervalSinceReferenceDate.isFinite, target.timeIntervalSinceReferenceDate.isFinite
    else {
      interrupt(at: sample.uptime, reason: .unavailableSample)
      return rate
    }
    defer { previous = sample }
    extraDelay = target.timeIntervalSince(playback) - sample.normalOffset
    if let previous, let previousDate = previous.playbackDate {
      let elapsed = sample.uptime - previous.uptime
      let advance = sample.clock - previous.clock
      let dateAdvance = playback.timeIntervalSince(previousDate)
      let expectedAdvance = elapsed * Double(previous.playbackRate)
      dateClockDifference = dateAdvance - advance
      if previous.rendition != sample.rendition || !(0.5...2.5).contains(elapsed)
        || advance < expectedAdvance * 0.8 || advance > expectedAdvance * 1.2
        || abs(advance - dateAdvance) > 0.5 {
        let reason: Interruption = previous.rendition != sample.rendition ? .renditionChanged
          : !(0.5...2.5).contains(elapsed) ? .samplingGap
          : abs(advance - dateAdvance) > 0.5 ? .dateChanged : .clockChanged
        interrupt(at: sample.uptime, reason: reason)
        settledSince = sample.uptime
      }
    }
    if settledSince == nil { settledSince = sample.uptime }
    let gap = target.timeIntervalSince(playback) - sample.normalOffset
    if isActive {
      // A fixed correction has only two commands: enter, then exit. Segment
      // buffer oscillation must not retime AVPlayer every second.
      if gap <= Self.settledExcessSeconds || abs(sample.playbackRate - rate) > 0.01 {
        interrupt(at: sample.uptime, reason: gap <= Self.settledExcessSeconds ? .reachedLive : .rateReset)
      }
      return rate
    }
    guard gap > Self.settledExcessSeconds,
      gap >= Self.minimumExcessSeconds else {
      behindSince = nil
      return rate
    }
    if behindSince == nil { behindSince = sample.uptime }
    guard let settledSince, let behindSince,
      sample.uptime - settledSince >= Self.settlingSeconds,
      sample.uptime - behindSince >= Self.settlingSeconds,
      sample.uptime >= cooldownUntil,
      sample.buffer >= Self.startBufferSeconds else { return rate }
    rate = Self.maximumRate
    lastInterruption = nil
    return rate
  }

  mutating func interrupt(at uptime: TimeInterval, reason: Interruption = .cancelled) {
    if isActive, uptime.isFinite { cooldownUntil = uptime + Self.cooldownSeconds }
    rate = 1
    lastInterruption = reason
    extraDelay = nil
    previous = nil
    settledSince = nil
    behindSince = nil
  }
}
