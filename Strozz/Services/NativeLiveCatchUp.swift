import Foundation

/// Recover small live drift by consuming buffered video slightly faster, never
/// by seeking or replacing the item. Rebuffering and manual intent take priority.
struct NativeLiveCatchUp {
  static let minimumExcessSeconds: TimeInterval = 3
  static let settlingSeconds: TimeInterval = 4
  static let minimumBufferSeconds: TimeInterval = 1
  static let maximumRate: Float = 1.08
  static let settledExcessSeconds: TimeInterval = 0.75

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
  }

  private(set) var rate: Float = 1
  private(set) var extraDelay: TimeInterval?
  var isActive: Bool { rate > 1 }
  private var previous: Sample?
  private var settledSince: TimeInterval?
  private var behindSince: TimeInterval?

  mutating func observe(_ sample: Sample) -> Float {
    guard sample.allowed, sample.isPlaying, sample.hasFreshVideo,
      sample.buffer.isFinite, sample.buffer >= Self.minimumBufferSeconds,
      sample.playbackRate.isFinite, (1...Self.maximumRate + 0.001).contains(sample.playbackRate),
      sample.uptime.isFinite, sample.clock.isFinite, sample.rendition != nil,
      let playback = sample.playbackDate, let target = sample.targetDate,
      playback.timeIntervalSinceReferenceDate.isFinite, target.timeIntervalSinceReferenceDate.isFinite
    else {
      interrupt()
      return rate
    }
    defer { previous = sample }
    extraDelay = target.timeIntervalSince(playback)
    if let previous, let previousDate = previous.playbackDate {
      let elapsed = sample.uptime - previous.uptime
      let advance = sample.clock - previous.clock
      let dateAdvance = playback.timeIntervalSince(previousDate)
      let expectedAdvance = elapsed * Double(previous.playbackRate)
      if previous.rendition != sample.rendition || !(0.5...2.5).contains(elapsed)
        || advance < expectedAdvance * 0.8 || advance > expectedAdvance * 1.2
        || abs(advance - dateAdvance) > 0.5 {
        rate = 1
        settledSince = sample.uptime
        behindSince = nil
      }
    } else {
      settledSince = sample.uptime
    }
    let gap = target.timeIntervalSince(playback)
    guard gap > Self.settledExcessSeconds,
      isActive || gap >= Self.minimumExcessSeconds else {
      rate = 1
      behindSince = nil
      return rate
    }
    if behindSince == nil { behindSince = sample.uptime }
    guard let settledSince, let behindSince,
      sample.uptime - settledSince >= Self.settlingSeconds,
      sample.uptime - behindSince >= Self.settlingSeconds else { return rate }
    let bufferLimitedRate = 1 + Float(sample.buffer - Self.minimumBufferSeconds) * 0.08
    let requested = min(Self.maximumRate, bufferLimitedRate, 1 + max(0.02, Float(gap) * 0.02))
    // Quantize small timestamp fluctuations and ramp up at most 2% per sample.
    let quantized = (requested * 100).rounded(.down) / 100
    rate = min(quantized, rate + 0.02)
    return rate
  }

  mutating func interrupt() {
    rate = 1
    extraDelay = nil
    previous = nil
    settledSince = nil
    behindSince = nil
  }
}
