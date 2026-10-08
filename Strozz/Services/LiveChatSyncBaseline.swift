import Foundation

struct PlaybackDateContinuity {
  private var candidate: (date: Date, clock: Double)?
  private var candidateProgress = 0.0

  static func isConsistent(previousDate: Date, previousClock: Double, date: Date, clock: Double) -> Bool {
    let difference = date.timeIntervalSince(previousDate) - (clock - previousClock)
    return difference.isFinite && abs(difference) <= 0.5
  }

  mutating func accepts(previousDate: Date, previousClock: Double, date: Date, clock: Double) -> Bool {
    if Self.isConsistent(previousDate: previousDate, previousClock: previousClock, date: date, clock: clock) {
      self = Self()
      return true
    }
    let correction = date.timeIntervalSince(previousDate) - (clock - previousClock)
    guard correction.isFinite, (0.5...6).contains(correction), clock - previousClock > 0.2 else {
      self = Self()
      return false
    }
    // AVPlayer can refine the date mapping forward after resume. Require a
    // correction within one Twitch target segment and two seconds of consistent
    // playhead progress. Large/backward or frozen-clock jumps stay invalid.
    if let candidate, (0.2...2.5).contains(clock - candidate.clock),
      Self.isConsistent(previousDate: candidate.date, previousClock: candidate.clock, date: date, clock: clock) {
      candidateProgress += clock - candidate.clock
    } else {
      candidateProgress = 0
    }
    candidate = (date, clock)
    guard candidateProgress >= 2 else { return false }
    self = Self()
    return true
  }
}

enum ChatSyncDefaultsMigration {
  static func runIfNeeded(_ defaults: UserDefaults = .standard) {
    guard !defaults.bool(forKey: PersistenceKey.extraDelayChatDefaultApplied) else { return }
    // Intentionally enable the new extra-delay behavior for existing installs,
    // including a previously stored false. Later user changes remain untouched.
    defaults.set(true, forKey: PersistenceKey.chatSyncToStream)
    defaults.set(true, forKey: PersistenceKey.extraDelayChatDefaultApplied)
  }
}

/// Estimates this session's extra video delay, not other viewers' latency.
/// Native comparisons use two dates on the same source clock, so clock skew cancels.
struct LiveChatSyncBaseline {
  enum Reference: String {
    case unavailable, nativeLiveTarget, calibratedLive
  }

  private(set) var extraDelay: Double?
  private(set) var liveEdgeDelay: Double?
  private(set) var normalDelay: Double?
  private(set) var reference: Reference = .unavailable
  private(set) var nativeCushion: Double?
  private var context = ""
  private var itemID: UUID?
  private var previous: Sample?
  private var calibration: [Sample] = []
  private var continuity = PlaybackDateContinuity()

  private struct Sample {
    let time: TimeInterval
    let clock: Double
    let date: Date
    let age: Double
    let nativeGap: Double?
  }

  mutating func itemChanged() {
    previous = nil
    continuity = PlaybackDateContinuity()
    calibration.removeAll()
    extraDelay = nil
    liveEdgeDelay = nil
    reference = .unavailable
  }

  mutating func observe(
    context: String, itemID: UUID, playbackDate: Date?, playbackTime: Double,
    liveTarget: Date?, liveEdge: Date? = nil, canCalibrate: Bool, now: Date,
    uptime: TimeInterval
  ) {
    if self.context != context {
      self = Self()
      self.context = context
    }
    if self.itemID != itemID {
      itemChanged()
      self.itemID = itemID
    }
    guard let playbackDate, playbackDate.timeIntervalSinceReferenceDate.isFinite,
      playbackTime.isFinite, uptime.isFinite, now.timeIntervalSinceReferenceDate.isFinite else {
      itemChanged()
      return
    }
    let age = now.timeIntervalSince(playbackDate)
    guard age.isFinite else { itemChanged(); return }
    let nativeGap = liveTarget.flatMap { target -> Double? in
      let gap = target.timeIntervalSince(playbackDate)
      return gap.isFinite ? gap : nil
    }
    let sample = Sample(time: uptime, clock: playbackTime, date: playbackDate, age: age, nativeGap: nativeGap)

    var progressing = false
    if let previous {
      let elapsed = uptime - previous.time
      let clockAdvance = playbackTime - previous.clock
      // A stale AVPlayer date must not create an ever-growing chat delay.
      if !continuity.accepts(
        previousDate: previous.date, previousClock: previous.clock, date: playbackDate, clock: playbackTime) {
        calibration.removeAll()
        extraDelay = nil
        liveEdgeDelay = nil
        reference = .unavailable
        return
      }
      progressing = elapsed >= 0.5 && elapsed <= 2.5
        && clockAdvance >= elapsed * 0.8 && clockAdvance <= elapsed * 1.2
    }
    defer { previous = sample }
    liveEdgeDelay = liveEdge.flatMap { edge in
      let delay = edge.timeIntervalSince(playbackDate)
      return delay.isFinite ? max(0, delay) : nil
    }

    if canCalibrate, progressing, nativeGap.map({ (-0.75...2).contains($0) }) ?? true {
      if calibration.last.map({ ($0.nativeGap == nil) != (nativeGap == nil) }) == true {
        calibration.removeAll()
      }
      calibration.append(sample)
      if calibration.count > 5 { calibration.removeFirst() }
      if calibration.count == 5, uptime - calibration[0].time >= 4 {
        let values = calibration.map { $0.nativeGap ?? $0.age }.sorted()
        if values[4] - values[0] <= 0.75 {
          let ages = calibration.map(\.age).sorted()
          // A stall must never teach the estimator that slower playback is normal.
          normalDelay = min(normalDelay ?? ages[2], ages[2])
          if nativeGap != nil {
            let cushion = max(0, values[2])
            nativeCushion = min(nativeCushion ?? cushion, cushion)
          }
        }
      }
    } else {
      calibration.removeAll()
    }

    let extra: Double?
    if let nativeGap {
      reference = .nativeLiveTarget
      extra = nativeGap - (nativeCushion ?? 0)
    } else if let normalDelay {
      reference = .calibratedLive
      extra = age - normalDelay
    } else {
      reference = .unavailable
      extra = nil
    }
    extraDelay = extra.map { $0 < 0.75 ? 0 : $0 }
  }
}
