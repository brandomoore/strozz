import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class TwitchChannelRewards {
  private(set) var points: TwitchChannelPoints?
  private(set) var isBusy = false
  private(set) var errorMessage: String?
  private(set) var statusMessage: String?
  private(set) var votedPollIDs: Set<String> = []
  private(set) var bonusesClaimed = 0
  private(set) var canInteract = false

  @ObservationIgnored private let api: TwitchWatchRewardsAPI
  @ObservationIgnored private weak var session: TwitchWatchRewardsSession?
  @ObservationIgnored private var current: TwitchWatchPlayback?
  @ObservationIgnored private var watching = false
  @ObservationIgnored private var token: String?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshID = UUID()
  @ObservationIgnored private var lastRefresh: TimeInterval?
  @ObservationIgnored private var attemptedClaims = BoundedCache<String, Bool>(capacity: 512, ttl: 86_400)
  @ObservationIgnored private var voteIDs: [String: String] = [:]
  @ObservationIgnored private var recorder: PlaybackTelemetryRecorder?
  @ObservationIgnored private var pendingRedemption: PendingRedemption?
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "ChannelRewards")

  private struct PendingRedemption {
    let userID: String
    let channelID: String
    let reward: TwitchChannelReward
    let message: String
    let emoteID: String?
    let transactionID: String
  }

  init(api: TwitchWatchRewardsAPI = TwitchWatchRewardsAPI()) { self.api = api }

  func update(
    _ playback: TwitchWatchPlayback, session: TwitchWatchRewardsSession,
    recorder: PlaybackTelemetryRecorder? = nil
  ) {
    if current?.target != playback.target || token != session.credential?.token { stop() }
    let previous = current
    current = playback
    self.session = session
    self.recorder = recorder
    token = session.credential?.token
    canInteract = playback.twitchLive && playback.foreground && playback.visible && !playback.sleeping
      && session.credential?.userID == playback.target.userID
    watching = previous.flatMap { playback.observedSeconds(since: $0) } != nil
    guard watching, canInteract else {
      cancelRefresh()
      return
    }
    guard !isBusy, refreshTask == nil,
      lastRefresh == nil || playback.uptime - (lastRefresh ?? 0) >= 60 else { return }
    lastRefresh = playback.uptime
    let attempt = generation
    let refresh = UUID()
    refreshID = refresh
    refreshTask = Task { [weak self] in
      guard let self else { return }
      defer { if generation == attempt, refreshID == refresh { refreshTask = nil } }
      do {
        let credential = try await validatedCredential(attempt)
        let snapshot = try await api.channelPoints(login: playback.target.channel, token: credential.token)
        try check(attempt)
        points = snapshot
        if watching, session.autoClaimBonuses, let claimID = snapshot.claimID,
          attemptedClaims.value(forKey: "\(credential.userID):\(snapshot.channelID):\(claimID)") == nil {
          attemptedClaims.insert(true, forKey: "\(credential.userID):\(snapshot.channelID):\(claimID)")
          let balance = try await api.claimWatchBonus(
            channelID: snapshot.channelID, claimID: claimID, token: credential.token)
          try check(attempt)
          points?.balance = balance
          points?.claimID = nil
          bonusesClaimed += 1
          recorder?.recordEvent("watch_bonus_claimed", counters: ["claims": bonusesClaimed])
        }
        errorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        if generation == attempt { report(error, operation: "bonus_refresh") }
      }
    }
  }

  func reload() async {
    guard !isBusy else { return }
    cancelRefresh()
    let attempt = generation
    isBusy = true
    errorMessage = nil
    defer { if generation == attempt { isBusy = false } }
    do {
      let credential = try await validatedCredential(attempt)
      guard let current else { throw CancellationError() }
      let value = try await api.channelPoints(login: current.target.channel, token: credential.token)
      try check(attempt)
      points = value
    } catch is CancellationError {
      return
    } catch {
      if generation == attempt { report(error, operation: "read_points") }
    }
  }

  func vote(in poll: LivePoll, choiceID: String, currentPoll: @escaping () -> LivePoll?) async {
    guard !isBusy else { return }
    cancelRefresh()
    let attempt = generation
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { if generation == attempt { isBusy = false } }
    do {
      let credential = try await validatedCredential(attempt)
      guard let active = currentPoll(), active.id == poll.id, active.isActive,
        active.choices.contains(where: { $0.id == choiceID }) else {
        throw TwitchRewardsActionError.pollClosed
      }
      guard !votedPollIDs.contains(poll.id) else { throw TwitchRewardsActionError.alreadyVoted }
      let voteID = voteIDs[poll.id] ?? Self.transactionID()
      voteIDs[poll.id] = voteID
      try check(attempt)
      try await api.vote(pollID: poll.id, choiceID: choiceID, voteID: voteID, credential: credential)
      try check(attempt)
      votedPollIDs.insert(poll.id)
      recorder?.recordEvent("poll_vote_submitted")
    } catch is CancellationError {
      return
    } catch {
      if generation == attempt {
        if error as? TwitchRewardsActionError == .alreadyVoted { votedPollIDs.insert(poll.id) }
        report(error, operation: "vote")
      }
    }
  }

  func redeem(_ reward: TwitchChannelReward, message: String, emoteID: String?) async {
    guard !isBusy else { return }
    cancelRefresh()
    let attempt = generation
    isBusy = true
    errorMessage = nil
    statusMessage = nil
    defer { if generation == attempt { isBusy = false } }
    var submitted = false
    do {
      let credential = try await validatedCredential(attempt)
      guard let current else { throw CancellationError() }
      let latest = try await api.channelPoints(login: current.target.channel, token: credential.token)
      try check(attempt)
      points = latest
      guard let fresh = latest.rewards.first(where: { $0.id == reward.id }), fresh.isAvailable else {
        throw TwitchRewardsActionError.unavailable
      }
      guard fresh == reward else { throw TwitchRewardsActionError.changed }
      guard latest.balance >= reward.cost else { throw TwitchRewardsActionError.insufficientPoints }
      if reward.requiresInput {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          message.utf16.count <= 500 else { throw TwitchRewardsActionError.invalidInput }
      }
      if reward.needsEmote {
        let allowed = reward.kind == .modifiedEmote
          ? latest.emotes.flatMap(\.modifications) : latest.emotes
        guard allowed.contains(where: { $0.id == emoteID }) else {
          throw TwitchRewardsActionError.unavailable
        }
      }
      try check(attempt)
      if pendingRedemption?.userID != credential.userID
        || pendingRedemption?.channelID != latest.channelID
        || pendingRedemption?.reward != reward || pendingRedemption?.message != message
        || pendingRedemption?.emoteID != emoteID {
        pendingRedemption = PendingRedemption(
          userID: credential.userID, channelID: latest.channelID, reward: reward,
          message: message, emoteID: emoteID, transactionID: Self.transactionID())
      }
      guard let transactionID = pendingRedemption?.transactionID else {
        throw TwitchWatchRewardsAPI.Failure.malformedResponse
      }
      submitted = true
      try await api.redeem(
        reward, channelID: latest.channelID, message: message, emoteID: emoteID,
        transactionID: transactionID, token: credential.token)
      try check(attempt)
      pendingRedemption = nil
      statusMessage = String(localized: "Reward redeemed.")
      recorder?.recordEvent("channel_reward_redeemed")
      // Only a server read updates the balance; never subtract an assumed cost locally.
      points = nil
      let updated = try await api.channelPoints(login: current.target.channel, token: credential.token)
      try check(attempt)
      points = updated
    } catch is CancellationError {
      return
    } catch {
      if generation == attempt {
        if submitted, error is TwitchRewardsActionError { pendingRedemption = nil }
        let uncertain = submitted && statusMessage == nil && !(error is TwitchRewardsActionError)
        report(uncertain ? TwitchRewardsActionError.uncertain : error, operation: "redeem")
      }
    }
  }

  func stop() {
    generation = UUID()
    cancelRefresh()
    current = nil
    token = nil
    session = nil
    watching = false
    canInteract = false
    points = nil
    isBusy = false
    lastRefresh = nil
    errorMessage = nil
    statusMessage = nil
    votedPollIDs.removeAll()
    voteIDs.removeAll()
  }

  private func cancelRefresh() {
    refreshID = UUID()
    refreshTask?.cancel()
    refreshTask = nil
  }

  private func validatedCredential(_ attempt: UUID) async throws -> TwitchWatchRewardsAPI.Credential {
    try check(attempt)
    guard let session, let current else { throw TwitchWatchRewardsAPI.Failure.unauthorized }
    let credential = try await session.validatedCredential(expectedUserID: current.target.userID)
    try check(attempt)
    return credential
  }

  private func check(_ attempt: UUID) throws {
    try Task.checkCancellation()
    guard generation == attempt, canInteract, let current, let session,
      session.credential?.token == token,
      session.credential?.userID == current.target.userID else { throw CancellationError() }
  }

  private func report(_ error: Error, operation: String) {
    if error as? TwitchWatchRewardsAPI.Failure == .unauthorized { session?.invalidate() }
    errorMessage = error.localizedDescription
    Self.logger.error("Channel rewards \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    recorder?.recordEvent("channel_rewards_failed", level: .warning, attributes: [
      "operation": operation,
      "reason": (error as? TwitchWatchRewardsAPI.Failure)?.diagnosticCode
        ?? (error is TwitchRewardsActionError ? "action_rejected" : "network_error"),
    ])
  }

  private static func transactionID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
