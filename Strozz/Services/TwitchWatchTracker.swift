import Foundation
import Observation
import OSLog

struct TwitchWatchPlayback: Equatable {
  struct Target: Equatable {
    let channel: String
    let userID: String
    let itemID: ObjectIdentifier
  }

  let target: Target
  var uptime: TimeInterval
  var playhead: Double
  var rate: Double = 1
  var ready = true
  var playing = true
  var twitchLive = true
  var foreground = true
  var visible = true
  var userPaused = false
  var seeking = false
  var sleeping = false
  var muted = false

  var eligible: Bool {
    ready && playing && twitchLive && foreground && visible
      && !userPaused && !seeking && !sleeping
      && rate.isFinite && rate > 0 && playhead.isFinite && uptime.isFinite
  }

  func observedSeconds(since previous: Self) -> TimeInterval? {
    guard eligible, previous.eligible, target == previous.target else { return nil }
    let elapsed = uptime - previous.uptime
    let advanced = playhead - previous.playhead
    guard elapsed > 0, elapsed <= 3, advanced > 0,
      advanced <= max(3, elapsed * max(rate, previous.rate) * 1.5) else { return nil }
    return min(elapsed, advanced)
  }
}

/// Accumulates observed playback, never elapsed wall time across a suspension or a seek.
struct TwitchWatchTime {
  private(set) var seconds: TimeInterval = 0
  private var target: TwitchWatchPlayback.Target?
  private var previous: TwitchWatchPlayback?

  mutating func sample(_ sample: TwitchWatchPlayback) -> Bool {
    if target != sample.target {
      self = TwitchWatchTime()
      target = sample.target
    }
    guard sample.eligible else {
      previous = nil
      return false
    }
    defer { previous = sample }
    guard let previous else { return false }
    guard let observed = sample.observedSeconds(since: previous) else { return false }
    seconds += observed
    guard seconds >= 60 else { return false }
    seconds -= 60
    return true
  }
}

@MainActor
@Observable
final class TwitchWatchTracker {
  let channelRewards: TwitchChannelRewards
  enum State: String { case idle, paused, watching, unavailable }
  private(set) var state: State = .idle
  private(set) var streak: Int?
  private(set) var errorMessage: String?
  private(set) var lastCheckedAt: Date?
  private(set) var acceptedReports = 0
  private(set) var observedStreakIncreases = 0

  @ObservationIgnored private var clock = TwitchWatchTime()
  @ObservationIgnored private var current: TwitchWatchPlayback?
  @ObservationIgnored private var lastAttempt: TimeInterval?
  @ObservationIgnored private var broadcastID: String?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private let api: TwitchWatchRewardsAPI
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "WatchRewards")

  init(api: TwitchWatchRewardsAPI = TwitchWatchRewardsAPI()) {
    self.api = api
    channelRewards = TwitchChannelRewards(api: api)
  }

  func update(
    _ playback: TwitchWatchPlayback?,
    session: TwitchWatchRewardsSession,
    recorder: PlaybackTelemetryRecorder? = nil
  ) {
    guard let playback, let saved = session.credential,
      saved.userID == playback.target.userID else {
      stop()
      if let error = session.errorMessage {
        errorMessage = error
        state = .unavailable
      }
      return
    }
    if current?.target != playback.target { stop() }
    channelRewards.update(playback, session: session, recorder: recorder)
    current = playback
    let earnedMinute = clock.sample(playback)
    guard playback.eligible else {
      cancelRequest()
      state = .paused
      return
    }
    if state == .idle || state == .paused { state = .watching }
    guard task == nil,
      earnedMinute || lastAttempt == nil || playback.uptime - (lastAttempt ?? 0) >= 60 else { return }
    lastAttempt = playback.uptime
    let attempt = generation
    task = Task { [weak self] in
      guard let self else { return }
      defer { if generation == attempt { task = nil } }
      var operation = "validate"
      do {
        let credential = try await session.validatedCredential(expectedUserID: playback.target.userID)
        try check(attempt, credential: credential, session: session)
        operation = "stream"
        guard let stream = try await api.stream(login: playback.target.channel, token: credential.token) else {
          throw TwitchWatchRewardsAPI.Failure.unsupported
        }
        try check(attempt, credential: credential, session: session)
        let broadcastChanged = broadcastID != nil && broadcastID != stream.broadcastID
        broadcastID = stream.broadcastID
        if broadcastChanged {
          clock = TwitchWatchTime()
          streak = nil
        }
        // Reading first also checks that this session can access the private rewards surface.
        operation = "read_streak"
        let before = try await api.streak(channelID: stream.channelID, token: credential.token)
        try check(attempt, credential: credential, session: session)
        apply(before)
        if earnedMinute && !broadcastChanged {
          operation = "report_minute"
          try await api.reportMinute(
            stream: stream, userID: credential.userID, muted: playback.muted, now: Date())
          try check(attempt, credential: credential, session: session)
          acceptedReports += 1
          recorder?.recordEvent("watch_rewards_report_accepted", counters: ["accepted_reports": acceptedReports])
          operation = "verify_streak"
          let after = try await api.streak(channelID: stream.channelID, token: credential.token)
          try check(attempt, credential: credential, session: session)
          apply(after)
        }
        errorMessage = nil
        state = .watching
        recorder?.recordEvent(
          "watch_rewards_checked",
          counters: streak.map { ["streak": $0, "observed_increases": observedStreakIncreases] } ?? [:],
          flags: ["milestone_available": streak != nil])
      } catch is CancellationError {
        return
      } catch {
        guard generation == attempt else { return }
        if error as? TwitchWatchRewardsAPI.Failure == .unauthorized { session.invalidate() }
        errorMessage = error.localizedDescription
        state = .unavailable
        Self.logger.error("Watch reporting stopped: \(error.localizedDescription, privacy: .public)")
        recorder?.recordEvent(
          "watch_rewards_failed", level: .warning,
          attributes: [
            "operation": operation,
            "reason": (error as? TwitchWatchRewardsAPI.Failure)?.diagnosticCode ?? "network_error",
          ])
      }
    }
  }

  func stop() {
    channelRewards.stop()
    cancelRequest()
    current = nil
    clock = TwitchWatchTime()
    lastAttempt = nil
    broadcastID = nil
    streak = nil
    lastCheckedAt = nil
    errorMessage = nil
    state = .idle
  }

  private func cancelRequest() {
    generation = UUID()
    task?.cancel()
    task = nil
  }

  private func check(
    _ attempt: UUID,
    credential: TwitchWatchRewardsAPI.Credential,
    session: TwitchWatchRewardsSession
  ) throws {
    try Task.checkCancellation()
    guard generation == attempt, current?.eligible == true,
      session.credential?.token == credential.token,
      session.credential?.userID == current?.target.userID else { throw CancellationError() }
  }

  private func apply(_ value: TwitchWatchRewardsAPI.Streak) {
    if let old = streak, let new = value.count, new > old { observedStreakIncreases += 1 }
    streak = value.count
    lastCheckedAt = Date()
  }
}
