import XCTest
import SwiftUI
@testable import Strozz

private func rewardsContext(balance: Int = 1000, cost: Int = 100, input: Bool = false) -> String {
  """
  {"data":{"community":{"channel":{"id":"channel-id","self":{"communityPoints":{"balance":\(balance),"availableClaim":{"id":"bonus-id"}}},"communityPointsSettings":{"isEnabled":true,"name":"Leaves","customRewards":[{"id":"custom","title":"Choose a song","prompt":"Song name","cost":\(cost),"isEnabled":true,"isInStock":true,"isPaused":false,"isUserInputRequired":\(input)}],"automaticRewards":[
  {"id":"highlight","type":"SEND_HIGHLIGHTED_MESSAGE","pricingType":"POINTS","cost":null,"defaultCost":200,"minimumCost":1,"isEnabled":true,"isInStock":true},
  {"id":"random","type":"RANDOM_SUB_EMOTE_UNLOCK","pricingType":"POINTS","cost":300,"defaultCost":500,"isEnabled":true,"isInStock":true},
  {"id":"chosen","type":"CHOSEN_SUB_EMOTE_UNLOCK","pricingType":"POINTS","cost":400,"isEnabled":true,"isInStock":true},
  {"id":"modified","type":"CHOSEN_MODIFIED_SUB_EMOTE_UNLOCK","pricingType":"POINTS","cost":500,"isEnabled":true,"isInStock":true},
  {"id":"bits","type":"SEND_GIGANTIFIED_EMOTE","pricingType":"BITS","cost":10,"isEnabled":true,"isInStock":true},
  {"id":"unknown","type":"FUTURE_REWARD","pricingType":"POINTS","cost":10,"isEnabled":true,"isInStock":true}
  ],"emoteVariants":[{"isUnlockable":true,"emote":{"id":"emote","token":"Hello"},"modifications":[{"emote":{"id":"emote_BW","token":"Hello_BW"}}]},{"isUnlockable":false,"emote":{"id":"owned","token":"Owned"},"modifications":[]}]}}}}}
  """
}

private actor ChannelRewardsTransport {
  var requests: [URLRequest] = []
  var context = rewardsContext()
  var mutationResponse: String?
  var mutationTimesOut = false
  var blockContext = false
  var contextContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
  var mutationCount = 0
  var contextCount = 0
  var validationStatus = 200

  func setContext(_ value: String) { context = value }
  func setMutation(_ value: String?) { mutationResponse = value }
  func setTimeout(_ value: Bool) { mutationTimesOut = value }
  func setValidationStatus(_ value: Int) { validationStatus = value }
  func block() { blockContext = true }
  var isBlocked: Bool { !contextContinuations.isEmpty }
  func release() {
    blockContext = false
    let pending = contextContinuations.values
    contextContinuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
  func releaseFirst() {
    if let key = contextContinuations.keys.min() {
      contextContinuations.removeValue(forKey: key)?.resume()
    }
  }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let payload = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    let body: String
    var status = 200
    if request.url?.path == "/oauth2/validate" {
      status = validationStatus
      body = """
      {"client_id":"\(TwitchWatchRewardsAPI.clientID)","user_id":"viewer","login":"viewer","expires_in":0}
      """
    } else if payload.contains("currentUser") {
      body = #"{"data":{"currentUser":{"id":"viewer"}}}"#
    } else if payload.contains("ChannelPointsContext") {
      contextCount += 1
      let read = contextCount
      if blockContext { await withCheckedContinuation { contextContinuations[read] = $0 } }
      body = context
    } else {
      mutationCount += 1
      if mutationTimesOut { throw URLError(.timedOut) }
      if let mutationResponse {
        body = mutationResponse
      } else {
        let key: String
        if payload.contains("StrozzClaimBonus") { key = "claimCommunityPoints" }
        else if payload.contains("VoteInPoll") { key = "voteInPoll" }
        else if payload.contains("RedeemCustomReward") { key = "redeemCommunityPointsCustomReward" }
        else if payload.contains("SendHighlightedChatMessage") { key = "sendHighlightedChatMessage" }
        else if payload.contains("UnlockRandomSubscriberEmote") { key = "unlockRandomSubscriberEmote" }
        else if payload.contains("UnlockModifiedEmote") { key = "unlockChosenModifiedSubscriberEmote" }
        else if payload.contains("StrozzUnlockEmote") { key = "unlockChosenSubscriberEmote" }
        else { throw TwitchWatchRewardsAPI.Failure.malformedResponse }
        body = "{\"data\":{\"\(key)\":{\"error\":null,\"currentPoints\":1050}}}"
      }
    }
    return (Data(body.utf8), HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor
final class TwitchChannelRewardsTests: XCTestCase {
  private let item = NSObject()
  private var sessions: [TwitchWatchRewardsSession] = []

  private func fixture(_ transport: ChannelRewardsTransport) throws
    -> (TwitchWatchRewardsAPI, TwitchWatchRewardsSession, TwitchChannelRewards) {
    let api = TwitchWatchRewardsAPI(load: { try await transport.load($0) })
    let credential = try JSONEncoder().encode(TwitchWatchRewardsAPI.Credential(
      token: "test-token", userID: "viewer", login: "viewer", expiresAt: nil))
    let name = "TwitchChannelRewardsTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    addTeardownBlock { preferences.removePersistentDomain(forName: name) }
    let session = TwitchWatchRewardsSession(
      api: api, store: .init(read: { credential }, write: { _ in }, remove: {}),
      preferences: preferences)
    sessions.append(session)
    let controller = TwitchChannelRewards(api: api)
    controller.update(playback(0), session: session)
    return (api, session, controller)
  }

  private func playback(_ second: Double) -> TwitchWatchPlayback {
    .init(target: .init(channel: "channel", userID: "viewer", itemID: ObjectIdentifier(item)),
      uptime: second, playhead: second)
  }

  private func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true")
  }

  private func input(_ request: URLRequest) throws -> [String: Any] {
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    let variables = try XCTUnwrap(body["variables"] as? [String: Any])
    return try XCTUnwrap(variables["input"] as? [String: Any])
  }

  func testContextUsesActualPointCostsAndEligibleEmotesOnly() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    let points = try await api.channelPoints(login: "CHANNEL", token: "test-token")
    XCTAssertEqual(points.balance, 1000)
    XCTAssertEqual(points.name, "Leaves")
    XCTAssertEqual(points.claimID, "bonus-id")
    XCTAssertEqual(points.rewards.count, 5)
    XCTAssertEqual(points.rewards.first { $0.id == "highlight" }?.cost, 200)
    XCTAssertEqual(points.rewards.first { $0.id == "random" }?.cost, 300)
    XCTAssertEqual(points.emotes.map(\.id), ["emote"])
    XCTAssertEqual(points.emotes.first?.modifications.map(\.id), ["emote_BW"])
    let request = await transport.requests.last!
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OAuth test-token")
    XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("\"channelLogin\":\"channel\""))
  }

  func testInvalidContextNeverFabricatesBalanceOrAvailability() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    let invalid = [
      rewardsContext(balance: -1), rewardsContext(cost: -1),
      rewardsContext().replacingOccurrences(of: "\"balance\":1000", with: "\"balance\":null"),
      rewardsContext().replacingOccurrences(of: "\"isInStock\":true", with: "\"isInStock\":null"),
      rewardsContext().replacingOccurrences(of: "\"isPaused\":false,", with: ""),
      rewardsContext().replacingOccurrences(of: "\"availableClaim\":{\"id\":\"bonus-id\"}", with: "\"availableClaim\":{\"id\":\"\"}"),
    ]
    for json in invalid {
      await transport.setContext(json)
      do {
        _ = try await api.channelPoints(login: "channel", token: "test-token")
        XCTFail("Invalid context accepted")
      } catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .malformedResponse) }
    }
  }

  func testChannelIconUsesExistingContextAndIsOptional() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    let withoutIcon = try await api.channelPoints(login: "channel", token: "test-token")
    XCTAssertNil(withoutIcon.imageURL)
    await transport.setContext(rewardsContext().replacingOccurrences(of: "\"name\":\"Leaves\"",
      with: "\"name\":\"Leaves\",\"image\":{\"url\":\"https://example.com/icon-1.png\",\"url2x\":\"https://example.com/icon-2.png\",\"url4x\":\"https://example.com/icon-4.png\"}"))
    let withIcon = try await api.channelPoints(login: "channel", token: "test-token")
    XCTAssertEqual(withIcon.imageURL?.absoluteString, "https://example.com/icon-2.png")
    XCTAssertEqual(withIcon.balance, withoutIcon.balance)
    XCTAssertEqual(withIcon.rewards, withoutIcon.rewards)
    await transport.setContext(rewardsContext().replacingOccurrences(of: "\"name\":\"Leaves\"",
      with: "\"name\":\"Leaves\",\"image\":{\"url2x\":\"http://example.com/icon.png\"}"))
    let unusableIcon = try await api.channelPoints(login: "channel", token: "test-token")
    XCTAssertNil(unusableIcon.imageURL)
    XCTAssertEqual(unusableIcon.balance, withoutIcon.balance, "Cosmetic icon data must not discard the real balance")
  }

  func testBitsCustomRewardsAndUnsupportedMessageRedemptionsCannotSpend() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    await transport.setContext(rewardsContext().replacingOccurrences(
      of: "\"id\":\"custom\"", with: "\"id\":\"custom\",\"pricingType\":\"BITS\""))
    let points = try await api.channelPoints(login: "channel", token: "test-token")
    XCTAssertFalse(points.rewards.contains { $0.id == "custom" })
    let unsupported = TwitchChannelReward(
      id: "sub-only", title: "Sub-only message", cost: 100, prompt: nil,
      kind: .subOnlyMessage, requiresInput: true, enabled: true,
      inStock: true, paused: false, cooldownUntil: nil)
    do {
      try await api.redeem(unsupported, channelID: "channel", message: "Hello",
        emoteID: nil, transactionID: "transaction", token: "test-token")
      XCTFail("Unsupported reward was accepted")
    } catch { XCTAssertEqual(error as? TwitchRewardsActionError, .unavailable) }
    let mutations = await transport.mutationCount
    XCTAssertEqual(mutations, 0)
  }

  func testMutationsRequireExplicitAcknowledgementAndRealBonusBalance() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    for json in [
      #"{"data":{"claimCommunityPoints":{}}}"#,
      #"{"data":{"claimCommunityPoints":{"error":null}}}"#,
      #"{"data":{"claimCommunityPoints":{"error":null,"currentPoints":-1}}}"#,
      #"{"data":{}}"#,
    ] {
      await transport.setMutation(json)
      do {
        _ = try await api.claimWatchBonus(channelID: "channel", claimID: "claim", token: "test-token")
        XCTFail("Unconfirmed claim accepted")
      } catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .malformedResponse) }
    }
    await transport.setMutation(#"{"data":{"claimCommunityPoints":{"error":null,"currentPoints":173}}}"#)
    let actual = try await api.claimWatchBonus(channelID: "channel", claimID: "claim", token: "test-token")
    XCTAssertEqual(actual, 173)
  }

  func testEachSupportedRewardUsesTheExpectedInput() async throws {
    let transport = ChannelRewardsTransport()
    let (api, _, _) = try fixture(transport)
    let points = try await api.channelPoints(login: "channel", token: "test-token")
    for reward in points.rewards {
      let emoteID = reward.kind == .modifiedEmote ? "emote_BW" : "emote"
      try await api.redeem(reward, channelID: points.channelID, message: "Hello",
        emoteID: emoteID, transactionID: "stable-id", token: "test-token")
      let value = try input(await transport.requests.last!)
      XCTAssertEqual(value["transactionID"] as? String, "stable-id")
      XCTAssertEqual(value["cost"] as? Int, reward.cost)
      XCTAssertEqual(value["channelID"] as? String, "channel-id")
      switch reward.kind {
      case .custom:
        XCTAssertEqual(value["pricingType"] as? String, "POINTS")
        XCTAssertEqual(value["prompt"] as? String, "Hello")
        XCTAssertEqual(value["rewardID"] as? String, "custom")
      case .highlightedMessage: XCTAssertEqual(value["message"] as? String, "Hello")
      case .chosenEmote, .modifiedEmote: XCTAssertEqual(value["emoteID"] as? String, emoteID)
      default: XCTAssertNil(value["emoteID"])
      }
    }
  }

  func testEveryIneligiblePlaybackStatePreventsAutomaticClaims() async throws {
    let gates: [WritableKeyPath<TwitchWatchPlayback, Bool>] = [
      \.ready, \.playing, \.twitchLive, \.foreground, \.visible,
      \.userPaused, \.seeking, \.sleeping,
    ]
    for gate in gates {
      let transport = ChannelRewardsTransport()
      let (_, session, controller) = try fixture(transport)
      for second in 0...70 {
        var sample = playback(Double(second))
        sample[keyPath: gate].toggle()
        controller.update(sample, session: session)
      }
      await Task.yield()
      let count = await transport.mutationCount
      XCTAssertEqual(count, 0, "\(gate)")
      controller.stop()
    }
  }

  func testFrozenPlaybackAndSeeksCannotClaim() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    for second in 1...70 {
      var sample = playback(Double(second))
      sample.playhead = 0
      controller.update(sample, session: session)
    }
    var seek = playback(71)
    seek.playhead = 900
    controller.update(seek, session: session)
    await Task.yield()
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
    controller.stop()
  }

  func testAdvancingPlaybackClaimsOnceAndUsesServerBalance() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    defer { controller.stop() }
    controller.update(playback(1), session: session)
    try await waitFor { controller.bonusesClaimed == 1 }
    XCTAssertEqual(controller.points?.balance, 1050)
    for second in 2...61 { controller.update(playback(Double(second)), session: session) }
    try await waitFor { await transport.contextCount == 2 }
    await controller.reload()
    let count = await transport.mutationCount
    XCTAssertEqual(count, 1)
  }

  func testAutomaticClaimSettingCanBeDisabledDuringLookup() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    defer { controller.stop() }
    await transport.block()
    controller.update(playback(1), session: session)
    try await waitFor { await transport.isBlocked }
    session.autoClaimBonuses = false
    await transport.release()
    try await waitFor { controller.points != nil }
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testPauseCloseAndAccountChangeCancelInFlightLookup() async throws {
    for transition in 0..<3 {
      let transport = ChannelRewardsTransport()
      let (_, session, controller) = try fixture(transport)
      await transport.block()
      controller.update(playback(1), session: session)
      try await waitFor { await transport.isBlocked }
      if transition == 0 {
        var paused = playback(2)
        paused.userPaused = true
        controller.update(paused, session: session)
      } else if transition == 1 { controller.stop() }
      else { session.accountChanged(to: "other-user") }
      await transport.release()
      for _ in 0..<20 { await Task.yield() }
      let count = await transport.mutationCount
      XCTAssertEqual(count, 0)
      XCTAssertNil(controller.points)
      controller.stop()
    }
  }

  func testReadingMenuDoesNotClaimOrRedeem() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    await controller.reload()
    XCTAssertNotNil(controller.points)
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testRewardChangesAndInsufficientPointsPreventSpending() async throws {
    for context in [
      rewardsContext(cost: 101), rewardsContext(balance: 99),
      rewardsContext().replacingOccurrences(of: "\"isPaused\":false", with: "\"isPaused\":true"),
    ] {
      let transport = ChannelRewardsTransport()
      let (_, _, controller) = try fixture(transport)
      await controller.reload()
      let reward = try XCTUnwrap(controller.points?.rewards.first)
      await transport.setContext(context)
      await controller.redeem(reward, message: "", emoteID: nil)
      XCTAssertNotNil(controller.errorMessage)
      XCTAssertNil(controller.statusMessage)
      let count = await transport.mutationCount
      XCTAssertEqual(count, 0)
    }
  }

  func testRequiredMessageAndEmoteAreValidatedBeforeSpending() async throws {
    let transport = ChannelRewardsTransport()
    await transport.setContext(rewardsContext(input: true))
    let (_, _, controller) = try fixture(transport)
    await controller.reload()
    let custom = try XCTUnwrap(controller.points?.rewards.first { $0.kind == .custom })
    for text in [" ", String(repeating: "x", count: 501)] {
      await controller.redeem(custom, message: text, emoteID: nil)
      XCTAssertEqual(controller.errorMessage, TwitchRewardsActionError.invalidInput.localizedDescription)
    }
    let chosen = try XCTUnwrap(controller.points?.rewards.first { $0.kind == .chosenEmote })
    await controller.redeem(chosen, message: "", emoteID: "owned")
    XCTAssertNotNil(controller.errorMessage)
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testConfirmedRedemptionRefreshesWithoutInventingBalance() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    await controller.reload()
    let reward = try XCTUnwrap(controller.points?.rewards.first)
    await controller.redeem(reward, message: "", emoteID: nil)
    XCTAssertNotNil(controller.statusMessage)
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(controller.points?.balance, 1000)
    let reads = await transport.contextCount
    XCTAssertEqual(reads, 3)
    let mutations = await transport.mutationCount
    XCTAssertEqual(mutations, 1)
  }

  func testUnconfirmedRedemptionReusesTransactionRatherThanBlindlyRepeating() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    await controller.reload()
    let reward = try XCTUnwrap(controller.points?.rewards.first)
    await transport.setTimeout(true)
    await controller.redeem(reward, message: "", emoteID: nil)
    let first = try input(await transport.requests.last!)["transactionID"] as? String
    XCTAssertNil(controller.statusMessage)
    XCTAssertEqual(controller.errorMessage, TwitchRewardsActionError.uncertain.localizedDescription)
    await transport.setTimeout(false)
    await controller.redeem(reward, message: "", emoteID: nil)
    let requests = await transport.requests
    let retries = requests.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("RedeemCustomReward") }
    XCTAssertEqual(retries.count, 2)
    XCTAssertEqual(try input(retries.last!)["transactionID"] as? String, first)
  }

  func testExplicitRejectionAndEmptyRedemptionAreNotSuccessful() async throws {
    for body in [
      #"{"data":{"redeemCommunityPointsCustomReward":{"error":{"code":"INSUFFICIENT_POINTS"}}}}"#,
      #"{"data":{"redeemCommunityPointsCustomReward":{}}}"#,
    ] {
      let transport = ChannelRewardsTransport()
      let (_, _, controller) = try fixture(transport)
      await controller.reload()
      let reward = try XCTUnwrap(controller.points?.rewards.first)
      await transport.setMutation(body)
      await controller.redeem(reward, message: "", emoteID: nil)
      XCTAssertNil(controller.statusMessage)
      XCTAssertNotNil(controller.errorMessage)
    }
  }

  func testClosingDuringRedemptionPreflightPreventsSpending() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    await controller.reload()
    let reward = try XCTUnwrap(controller.points?.rewards.first)
    await transport.block()
    let action = Task { await controller.redeem(reward, message: "", emoteID: nil) }
    try await waitFor { await transport.isBlocked }
    action.cancel()
    await transport.release()
    await action.value
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
    XCTAssertFalse(controller.isBusy)
  }

  func testFreePollVoteUsesValidatedOwnerAndNeverSpendsPoints() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    let poll = LivePoll(id: "poll", title: "Choose", choices: [
      .init(id: "choice", title: "One", votes: 0),
    ], isActive: true)
    await controller.vote(in: poll, choiceID: "choice", currentPoll: { poll })
    XCTAssertTrue(controller.votedPollIDs.contains(poll.id))
    let value = try input(await transport.requests.last!)
    XCTAssertEqual(value["userID"] as? String, "viewer")
    XCTAssertEqual(value["choiceID"] as? String, "choice")
    XCTAssertTrue(value["tokens"] is NSNull)
    XCTAssertEqual((value["voteID"] as? String)?.count, 32)
    await controller.vote(in: poll, choiceID: "choice", currentPoll: { poll })
    let count = await transport.mutationCount
    XCTAssertEqual(count, 1)
  }

  func testStalePollOrInvalidChoiceCannotBeSubmitted() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    let poll = LivePoll(id: "poll", title: "Choose", choices: [
      .init(id: "choice", title: "One", votes: 0),
    ], isActive: true)
    await controller.vote(in: poll, choiceID: "choice", currentPoll: { nil })
    await controller.vote(in: poll, choiceID: "missing", currentPoll: { poll })
    XCTAssertTrue(controller.votedPollIDs.isEmpty)
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testRevokedSessionStopsAllRewardMutations() async throws {
    let transport = ChannelRewardsTransport()
    await transport.setValidationStatus(401)
    let (_, session, controller) = try fixture(transport)
    await controller.reload()
    XCTAssertFalse(session.isConnected)
    XCTAssertNotNil(controller.errorMessage)
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testUnconfirmedBonusIsNotRetriedOnTheNextRefresh() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    defer { controller.stop() }
    await transport.setTimeout(true)
    controller.update(playback(1), session: session)
    try await waitFor { controller.errorMessage != nil }
    XCTAssertEqual(controller.bonusesClaimed, 0)
    for second in 2...61 { controller.update(playback(Double(second)), session: session) }
    try await waitFor { await transport.contextCount == 2 }
    try await waitFor { controller.errorMessage == nil }
    let count = await transport.mutationCount
    XCTAssertEqual(count, 1)
  }

  func testCanceledRefreshCannotClearItsReplacementsOwnership() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    defer { controller.stop() }
    session.autoClaimBonuses = false
    await transport.block()
    controller.update(playback(1), session: session)
    try await waitFor { await transport.isBlocked }
    var paused = playback(2)
    paused.userPaused = true
    controller.update(paused, session: session)
    for second in 3...61 { controller.update(playback(Double(second)), session: session) }
    try await waitFor { await transport.contextCount == 2 }
    await transport.releaseFirst()
    try await Task.sleep(for: .milliseconds(20))
    for second in 62...121 { controller.update(playback(Double(second)), session: session) }
    try await Task.sleep(for: .milliseconds(20))
    let reads = await transport.contextCount
    await transport.release()
    try await waitFor { controller.points != nil }
    XCTAssertEqual(reads, 2, "Canceled task discarded the replacement, allowing a third concurrent read")
    XCTAssertNotNil(controller.points)
    XCTAssertFalse(controller.isBusy)
    let mutations = await transport.mutationCount
    XCTAssertEqual(mutations, 0)
  }

  func testChannelChangeDuringRedemptionPreflightCannotSpendOnEitherChannel() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    await controller.reload()
    let reward = try XCTUnwrap(controller.points?.rewards.first)
    await transport.block()
    let action = Task { await controller.redeem(reward, message: "", emoteID: nil) }
    try await waitFor { await transport.isBlocked }
    controller.update(.init(
      target: .init(channel: "other", userID: "viewer", itemID: ObjectIdentifier(item)),
      uptime: 1, playhead: 1), session: session)
    await transport.release()
    await action.value
    XCTAssertNil(controller.points)
    XCTAssertNil(controller.statusMessage)
    let count = await transport.mutationCount
    XCTAssertEqual(count, 0)
  }

  func testPollRetryUsesTheSameVoteIdentityAndRequiresAcknowledgement() async throws {
    let transport = ChannelRewardsTransport()
    let (_, _, controller) = try fixture(transport)
    let poll = LivePoll(id: "poll", title: "Choose", choices: [
      .init(id: "choice", title: "One", votes: 0),
    ], isActive: true)
    await transport.setMutation(#"{"data":{"voteInPoll":{}}}"#)
    await controller.vote(in: poll, choiceID: "choice", currentPoll: { poll })
    let first = try input(await transport.requests.last!)["voteID"] as? String
    XCTAssertTrue(controller.votedPollIDs.isEmpty)
    await transport.setMutation(nil)
    await controller.vote(in: poll, choiceID: "choice", currentPoll: { poll })
    let second = try input(await transport.requests.last!)["voteID"] as? String
    XCTAssertEqual(first, second)
    XCTAssertTrue(controller.votedPollIDs.contains(poll.id))
  }

  func testBonusPreferencePersistsIndependentlyOfCredentials() throws {
    let name = "TwitchBonusPreferenceTests.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: name)!
    defer { preferences.removePersistentDomain(forName: name) }
    let store = TwitchWatchRewardsStore(read: { nil }, write: { _ in }, remove: {})
    let session = TwitchWatchRewardsSession(store: store, preferences: preferences)
    XCTAssertTrue(session.autoClaimBonuses)
    session.autoClaimBonuses = false
    let restored = TwitchWatchRewardsSession(store: store, preferences: preferences)
    XCTAssertFalse(restored.autoClaimBonuses)
    XCTAssertFalse(restored.isConnected)
  }

  func testPanelRendersAcrossThemesWithoutSpendingPoints() async throws {
    let transport = ChannelRewardsTransport()
    let (_, session, controller) = try fixture(transport)
    await controller.reload()
    let events = HermesEventService()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    defer { previousKeyWindow?.makeKey() }
    for theme in AppTheme.allCases {
      for scheme in [ColorScheme.dark, .light] {
        let palette = theme.palette(systemColorScheme: scheme)
        for opaque in [false, true] {
          let host = UIHostingController(rootView:
            TwitchChannelRewardsView(
              rewards: controller, session: session, events: events, onClose: {})
              .frame(width: 680, height: 1000)
              .environment(\.themePalette, palette)
              .environment(\.colorScheme, palette.chromeColorScheme)
              .environment(\.glassDisabled, opaque)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(palette.playerBackdrop)
              .ignoresSafeArea())
          let window = UIWindow(windowScene: scene)
          window.rootViewController = host
          window.makeKeyAndVisible()
          defer {
            window.isHidden = true
            window.rootViewController = nil
          }
          try await Task.sleep(for: .milliseconds(250))
          host.view.layoutIfNeeded()
          XCTAssertFalse(controller.isBusy)
          let scroll = try XCTUnwrap(findScroll(in: host.view))
          XCTAssertGreaterThan(scroll.contentSize.height, 400, "Reward rows are missing")
          XCTAssertGreaterThan(scroll.bounds.height, 300)
          let format = UIGraphicsImageRendererFormat()
          format.scale = 1
          let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
          }
          let attachment = XCTAttachment(image: image)
          attachment.name = "Rewards-\(theme.rawValue)-\(scheme)-opaque-\(opaque)"
          attachment.lifetime = .keepAlways
          add(attachment)
        }
      }
    }
    let mutations = await transport.mutationCount
    XCTAssertEqual(mutations, 0)
  }

  private func findScroll(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
  }
}
