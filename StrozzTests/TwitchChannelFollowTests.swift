import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class TwitchChannelFollowTests: XCTestCase {
  private func fixture() throws -> (FollowScenario, TwitchAuthSession, TwitchWatchRewardsSession, FollowedChannelsService) {
    let scenario = FollowScenario()
    let name = "ChannelFollowTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: name)
      try CredentialKeychain.remove(service: name)
    }
    let auth = TwitchAuthSession(userDefaults: defaults, secureService: name, saveTopShelf: { _ in },
      loadAuthData: { try await scenario.load($0) })
    auth.userID = "viewer"
    auth.userLogin = "viewer"
    auth.accessToken = "helix-token"
    auth.isAuthenticated = true
    auth.broadcasterIDCache["channel"] = "target"
    let stored = try JSONEncoder().encode(TwitchWatchRewardsAPI.Credential(
      token: "rewards-token", userID: "viewer", login: "viewer", expiresAt: nil))
    let rewards = TwitchWatchRewardsSession(api: scenario.api, store: .init(
      read: { stored }, write: { _ in }, remove: {}), preferences: defaults)
    let follows = FollowedChannelsService(loadData: { try await scenario.load($0) })
    return (scenario, auth, rewards, follows)
  }

  func testFollowAndUnfollowUseRewardsIdentityAndRefreshBothLists() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    await follows.loadDirectory(using: auth)
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    XCTAssertEqual(model.isFollowing, false, "Helix total is not this channel's follow state")
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(model.isFollowing, true)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(follows.channels.map(\.login), ["channel"])
    XCTAssertEqual(follows.directory.map(\.login), ["channel"])
    XCTAssertEqual(follows.followedLogins, ["channel"])
    await model.change(to: false, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(model.isFollowing, false)
    XCTAssertTrue(follows.channels.isEmpty)
    XCTAssertTrue(follows.directory.isEmpty)
    XCTAssertTrue(follows.followedLogins.isEmpty)
    XCTAssertEqual(scenario.mutations.count, 2)
    for request in scenario.mutations {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Id"), TwitchWatchRewardsAPI.clientID)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth rewards-token")
    }
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(scenario.mutations.first?.httpBody)) as? [String: Any])
    XCTAssertEqual(body["operationName"] as? String, "FollowButton_FollowUser")
    let input = (body["variables"] as? [String: Any])?["input"] as? [String: Any]
    XCTAssertEqual(input?["targetID"] as? String, "target")
    XCTAssertEqual(input?["disableNotifications"] as? Bool, true)
  }

  func testHTTP200WithoutConfirmedRelationshipIsNotSuccess() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    scenario.applyMutation = false
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(model.isFollowing, false)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertNil(follows.lastUpdatedAt)
  }

  func testMissingAndRejectedMutationPayloadsNeverSucceed() async throws {
    let scenario = FollowScenario()
    let responses = [
      #"{"data":null}"#, #"{"data":{}}"#, #"{"data":{"followUser":null}}"#, #"{"data":{"followUser":{}}}"#,
      #"{"data":{"followUser":{"error":{"code":"FORBIDDEN"}}}}"#,
      #"{"data":{"followUser":{}},"errors":[{"message":"failed integrity check"}]}"#,
      #"{"errors":[{}]}"#, #"{}"#,
    ]
    for body in responses {
      scenario.mutationBody = body
      do {
        try await scenario.api.setFollowing(true, channelID: "target", token: "rewards-token")
        XCTFail("Accepted invalid response: \(body)")
      } catch {}
    }
  }

  func testExpiredOrRejectedRewardsTokenRequiresReconnectionNotHelixFallback() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    scenario.mutationStatus = 401
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertFalse(rewards.isConnected)
    XCTAssertTrue(auth.isAuthenticated)
    XCTAssertEqual(auth.accessToken, "helix-token")
    XCTAssertEqual(scenario.mutations.count, 1)
    XCTAssertEqual(model.isFollowing, false)
    XCTAssertEqual(model.errorMessage, FollowActionError.connectionRequired.localizedDescription)
  }

  func testDifferentAccountAndOwnChannelCannotMutate() async throws {
    let (scenario, auth, rewards, _) = try fixture()
    auth.userID = "another-viewer"
    do {
      try await auth.setFollowing(true, login: "channel", rewards: rewards, api: scenario.api)
      XCTFail("Accepted another account's rewards credential")
    } catch {
      XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .accountMismatch)
    }
    auth.userID = "viewer"
    auth.broadcasterIDCache["channel"] = "viewer"
    do {
      try await auth.setFollowing(true, login: "channel", rewards: rewards, api: scenario.api)
      XCTFail("Accepted self-follow")
    } catch {}
    XCTAssertTrue(scenario.mutations.isEmpty)
  }

  func testDuplicatePressDoesNotMutateTwiceAndStateWaitsForConfirmation() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    scenario.holdMutation = true
    let started = expectation(description: "Mutation started")
    scenario.onHeld = { started.fulfill() }
    let pending = Task {
      await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    }
    await fulfillment(of: [started], timeout: 2)
    XCTAssertTrue(model.isUpdating)
    XCTAssertEqual(model.isFollowing, false)
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(scenario.mutations.count, 1)
    scenario.releaseMutation()
    await pending.value
    XCTAssertEqual(model.isFollowing, true)
    XCTAssertFalse(model.isBusy)
  }

  func testAccountChangeDiscardsLateMutationCompletion() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    scenario.holdMutation = true
    let started = expectation(description: "Mutation started")
    scenario.onHeld = { started.fulfill() }
    let pending = Task {
      await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    }
    await fulfillment(of: [started], timeout: 2)
    auth.userID = nil
    auth.isAuthenticated = false
    auth.sessionGeneration = UUID()
    await model.load(login: "channel", auth: auth)
    scenario.releaseMutation()
    await pending.value
    XCTAssertNil(model.isFollowing)
    XCTAssertNil(model.errorMessage)
    XCTAssertNil(follows.lastUpdatedAt)
    XCTAssertFalse(model.isBusy)
  }

  func testLostMutationResponseReconcilesButStillSurfacesTheError() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    scenario.loseMutationResponse = true
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(model.isFollowing, true)
    XCTAssertEqual(follows.followedLogins, ["channel"])
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(scenario.mutations.count, 1)
  }

  func testFailedStatusReadIsUnknownNotUnfollowedAndCanRetry() async throws {
    let (scenario, auth, _, _) = try fixture()
    scenario.failState = true
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    XCTAssertNil(model.isFollowing)
    XCTAssertNotNil(model.errorMessage)
    scenario.failState = false
    scenario.following = true
    await model.load(login: "channel", auth: auth)
    XCTAssertEqual(model.isFollowing, true)
    XCTAssertNil(model.errorMessage)
  }

  func testExternalFollowIsRecheckedWithoutChangingNotificationPreferences() async throws {
    let (scenario, auth, rewards, follows) = try fixture()
    let model = TwitchChannelFollowModel(api: scenario.api)
    await model.load(login: "channel", auth: auth)
    scenario.following = true
    await model.change(to: true, login: "channel", auth: auth, rewards: rewards, follows: follows)
    XCTAssertEqual(model.isFollowing, true)
    XCTAssertTrue(scenario.mutations.isEmpty)
    XCTAssertEqual(follows.followedLogins, ["channel"])
  }
}

@MainActor
private final class FollowScenario {
  var following = false
  var applyMutation = true
  var mutationStatus = 200
  var mutationBody: String?
  var mutations: [URLRequest] = []
  var holdMutation = false
  var loseMutationResponse = false
  var failState = false
  var onHeld: (() -> Void)?
  private var continuation: CheckedContinuation<Void, Never>?
  var api: TwitchWatchRewardsAPI { .init(load: { try await self.load($0) }) }

  func releaseMutation() {
    continuation?.resume()
    continuation = nil
  }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    var status = 200
    let json: String
    switch url.path {
    case "/oauth2/validate":
      json = #"{"client_id":"\#(TwitchWatchRewardsAPI.clientID)","user_id":"viewer","login":"viewer","expires_in":3600}"#
    case "/gql":
      let body = try XCTUnwrap(request.httpBody)
      let operation = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      if let name = operation["operationName"] as? String, name.hasPrefix("FollowButton_") {
        mutations.append(request)
        if holdMutation {
          await withCheckedContinuation { continuation in
            self.continuation = continuation
            onHeld?()
          }
        }
        status = mutationStatus
        let follow = name == "FollowButton_FollowUser"
        if applyMutation, status == 200, mutationBody == nil { following = follow }
        if loseMutationResponse { throw URLError(.timedOut) }
        json = mutationBody ?? #"{"data":{"\#(follow ? "followUser" : "unfollowUser")":{"error":null}}}"#
      } else {
        json = #"{"data":{"currentUser":{"id":"viewer"}}}"#
      }
    case "/helix/channels/followed":
      if failState { throw URLError(.notConnectedToInternet) }
      json = following
        ? #"{"total":123,"data":[{"broadcaster_id":"target","broadcaster_login":"channel","broadcaster_name":"Channel"}]}"#
        : #"{"total":123,"data":[]}"#
    case "/helix/streams/followed", "/helix/streams":
      json = following
        ? #"{"data":[{"user_id":"target","user_login":"channel","user_name":"Channel","game_name":"Game","title":"Live","viewer_count":1,"is_mature":false,"thumbnail_url":"","type":"live"}]}"#
        : #"{"data":[]}"#
    case "/helix/users":
      json = #"{"data":[{"id":"target","login":"channel","display_name":"Channel"}]}"#
    case "/helix/channels":
      json = #"{"data":[{"broadcaster_id":"target","game_name":"Game"}]}"#
    default:
      throw URLError(.unsupportedURL)
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
