import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class TwitchChannelFollowModel {
  private(set) var isFollowing: Bool?
  private(set) var isLoading = false
  private(set) var isUpdating = false
  private(set) var errorMessage: String?
  var isBusy: Bool { isLoading || isUpdating }

  struct Context: Equatable {
    let login: String
    let userID: String?
    let authenticated: Bool
    let generation: UUID

    @MainActor init(login: String, auth: TwitchAuthSession) {
      self.login = login.lowercased()
      userID = auth.userID
      authenticated = auth.isAuthenticated
      generation = auth.sessionGeneration
    }
  }

  @ObservationIgnored private var context: Context?
  @ObservationIgnored private var requestID = UUID()
  @ObservationIgnored private let api: TwitchWatchRewardsAPI
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "channel-follow")

  init(api: TwitchWatchRewardsAPI = TwitchWatchRewardsAPI()) {
    self.api = api
  }

  func load(login: String, auth: TwitchAuthSession) async {
    let next = Context(login: login, auth: auth)
    if context != next {
      context = next
      requestID = UUID()
      isFollowing = nil
      isUpdating = false
    } else if isUpdating { return }
    let request = UUID()
    requestID = request
    errorMessage = nil
    isLoading = true
    defer { if requestID == request { isLoading = false } }
    guard auth.isAuthenticated else { return }
    do {
      let following = try await auth.isFollowing(channelLogin: login)
      guard isCurrent(request, next, auth) else { return }
      isFollowing = following
    } catch {
      guard isCurrent(request, next, auth), !(error is CancellationError) else { return }
      isFollowing = nil
      report(error)
    }
  }

  func change(
    to desired: Bool, login: String, auth: TwitchAuthSession,
    rewards: TwitchWatchRewardsSession, follows: FollowedChannelsService
  ) async {
    let expected = Context(login: login, auth: auth)
    guard context == expected, !isBusy, let previous = isFollowing else { return }
    let request = UUID()
    requestID = request
    isUpdating = true
    errorMessage = nil
    defer { if requestID == request { isUpdating = false } }
    do {
      let current = try await auth.isFollowing(channelLogin: login)
      guard isCurrent(request, expected, auth) else { return }
      if current != desired {
        try await auth.setFollowing(desired, login: login, rewards: rewards, api: api)
      }
      for attempt in 0..<4 {
        guard isCurrent(request, expected, auth) else { return }
        let confirmed = try await auth.isFollowing(channelLogin: login)
        guard isCurrent(request, expected, auth) else { return }
        if confirmed == desired {
          isFollowing = confirmed
          await follows.followChanged(login: login, following: confirmed, using: auth)
          return
        }
        if attempt < 3 { try await Task.sleep(for: .milliseconds(500)) }
      }
      throw FollowActionError.notConfirmed
    } catch {
      guard isCurrent(request, expected, auth), !(error is CancellationError) else { return }
      report(error)
      // A response can fail after Twitch commits the change; reconcile instead of leaving stale state.
      isFollowing = nil
      do {
        let actual = try await auth.isFollowing(channelLogin: login)
        guard isCurrent(request, expected, auth) else { return }
        isFollowing = actual
        if actual != previous {
          await follows.followChanged(login: login, following: actual, using: auth)
        }
      } catch {
        guard isCurrent(request, expected, auth) else { return }
        report(error)
      }
    }
  }

  private func isCurrent(_ request: UUID, _ expected: Context, _ auth: TwitchAuthSession) -> Bool {
    !Task.isCancelled && requestID == request && context == expected
      && Context(login: expected.login, auth: auth) == expected
  }

  private func report(_ error: Error) {
    errorMessage = error.localizedDescription
    Self.logger.error("Follow request failed: \((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
  }
}
