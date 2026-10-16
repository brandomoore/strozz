import XCTest
@testable import Strozz

@MainActor
final class TwitchFollowLiveTests: XCTestCase {
  func testTVRewardsFollowRoundTrip() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_FOLLOW_ROUND_TRIP"] == "twitch" else {
      throw XCTSkip("Requires explicit permission to follow and unfollow twitch on the signed-in account.")
    }
    #if targetEnvironment(simulator)
    throw XCTSkip("Run on the authorized Apple TV with its existing account.")
    #else
    for _ in 0..<120 {
      if let environment = AppEnvironment.playbackTestEnvironment,
        environment.auth.isAuthenticated, environment.watchRewards.isConnected { break }
      try await Task.sleep(for: .milliseconds(500))
    }
    let environment = try XCTUnwrap(AppEnvironment.playbackTestEnvironment)
    let auth = environment.auth
    guard auth.isAuthenticated, let userID = auth.userID,
      let clientID = auth.clientID, let accessToken = auth.accessToken else {
      throw ProbeFailure.notConnected
    }
    let credential = try await environment.watchRewards.validatedCredential(expectedUserID: userID)
    let api = TwitchWatchRewardsAPI()
    _ = try await api.validate(credential.token, expectedUserID: userID)
    let targetID = try await auth.resolveBroadcasterID(
      forLogin: "twitch", clientID: clientID, accessToken: accessToken)
    guard try await !auth.isFollowing(channelLogin: "twitch") else {
      throw XCTSkip("Already following twitch; no account changes made.")
    }
    let generation = auth.sessionGeneration
    var mutationFailure: Error?
    do {
      guard auth.sessionGeneration == generation else { throw ProbeFailure.accountChanged }
      try await mutate(follow: true, targetID: targetID, token: credential.token)
    } catch {
      mutationFailure = error
    }
    // Reconcile even after an error: a response can be lost after Twitch commits the follow.
    var followed = false
    do {
      followed = try await pollState(expected: true, auth: auth, generation: generation)
    } catch {
      if mutationFailure == nil { mutationFailure = error }
    }
    print("FOLLOW_PROBE follow_confirmed_by_helix=\(followed)")
    // The initial relationship was absent, so this also safely reconciles an ambiguous follow.
    try await mutate(follow: false, targetID: targetID, token: credential.token)
    guard try await !pollState(expected: false, auth: auth, generation: generation) else {
      throw ProbeFailure.restoreFailed
    }
    print("FOLLOW_PROBE original_unfollowed_state_restored=true")
    if let mutationFailure { throw mutationFailure }
    XCTAssertTrue(followed, "Twitch did not confirm the follow through Helix.")
    #endif
  }

  private func pollState(
    expected: Bool, auth: TwitchAuthSession, generation: UUID
  ) async throws -> Bool {
    var state = !expected
    for _ in 0..<6 {
      guard auth.sessionGeneration == generation else { throw ProbeFailure.accountChanged }
      state = try await auth.isFollowing(channelLogin: "twitch")
      if state == expected { return state }
      try await Task.sleep(for: .seconds(1))
    }
    return state
  }

  private func mutate(follow: Bool, targetID: String, token: String) async throws {
    try await TwitchWatchRewardsAPI().setFollowing(follow, channelID: targetID, token: token)
  }

  private enum ProbeFailure: Error {
    case notConnected, accountChanged, restoreFailed
  }
}
