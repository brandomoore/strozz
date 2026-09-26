import XCTest
@testable import Strozz

final class TwitchWatchTimeTests: XCTestCase {
  private let item = NSObject()

  private func sample(_ second: Double) -> TwitchWatchPlayback {
    TwitchWatchPlayback(
      target: .init(channel: "channel", userID: "viewer", itemID: ObjectIdentifier(item)),
      uptime: second, playhead: second)
  }

  func testReportsOnlyAfterSixtyObservedSeconds() {
    var clock = TwitchWatchTime()
    for second in 0..<60 { XCTAssertFalse(clock.sample(sample(Double(second)))) }
    XCTAssertTrue(clock.sample(sample(60)))
    XCTAssertEqual(clock.seconds, 0)
    for second in 61..<120 { XCTAssertFalse(clock.sample(sample(Double(second)))) }
    XCTAssertTrue(clock.sample(sample(120)))
  }

  func testEveryIneligiblePlaybackConditionStopsAccumulation() {
    let gates: [WritableKeyPath<TwitchWatchPlayback, Bool>] = [
      \.ready, \.playing, \.twitchLive, \.foreground, \.visible,
      \.userPaused, \.seeking, \.sleeping,
    ]
    for gate in gates {
      var clock = TwitchWatchTime()
      var value = sample(0)
      value[keyPath: gate].toggle()
      for second in 0...180 {
        value.uptime = Double(second)
        value.playhead = Double(second)
        XCTAssertFalse(clock.sample(value), "\(gate)")
      }
      XCTAssertEqual(clock.seconds, 0)
    }
  }

  func testMuteDoesNotInventOrPreventRealViewing() {
    var clock = TwitchWatchTime()
    for second in 0...60 {
      var value = sample(Double(second))
      value.muted = true
      XCTAssertEqual(clock.sample(value), second == 60)
    }
  }

  func testPausedAndBackgroundTimeNeverCatchUpOnReturn() {
    for gate in [\TwitchWatchPlayback.userPaused, \.sleeping] {
      var clock = TwitchWatchTime()
      for second in 0...30 { _ = clock.sample(sample(Double(second))) }
      var paused = sample(31)
      paused[keyPath: gate] = true
      XCTAssertFalse(clock.sample(paused))
      XCTAssertFalse(clock.sample(sample(900)))
      XCTAssertEqual(clock.seconds, 30)
      for second in 901..<930 { XCTAssertFalse(clock.sample(sample(Double(second)))) }
      XCTAssertTrue(clock.sample(sample(930)))
    }
  }

  func testSuspensionWithoutLifecycleNotificationCannotCount() {
    var clock = TwitchWatchTime()
    XCTAssertFalse(clock.sample(sample(0)))
    XCTAssertFalse(clock.sample(sample(900)))
    XCTAssertEqual(clock.seconds, 0)
  }

  func testFrozenClockAndSeeksDoNotCount() {
    var clock = TwitchWatchTime()
    _ = clock.sample(sample(0))
    var frozen = sample(60)
    frozen.playhead = 0
    XCTAssertFalse(clock.sample(frozen))
    for second in 61...90 {
      frozen.uptime = Double(second)
      XCTAssertFalse(clock.sample(frozen))
    }
    var forward = sample(91)
    forward.playhead = 600
    XCTAssertFalse(clock.sample(forward))
    var backward = sample(92)
    backward.playhead = 10
    XCTAssertFalse(clock.sample(backward))
    XCTAssertEqual(clock.seconds, 0)
  }

  func testIdentityChangesDiscardPartialMinutes() {
    let otherItem = NSObject()
    let targets: [TwitchWatchPlayback.Target] = [
      .init(channel: "other", userID: "viewer", itemID: ObjectIdentifier(item)),
      .init(channel: "channel", userID: "other", itemID: ObjectIdentifier(item)),
      .init(channel: "channel", userID: "viewer", itemID: ObjectIdentifier(otherItem)),
    ]
    for target in targets {
      var clock = TwitchWatchTime()
      for second in 0...59 { _ = clock.sample(sample(Double(second))) }
      let changed = TwitchWatchPlayback(target: target, uptime: 60, playhead: 60)
      XCTAssertFalse(clock.sample(changed))
      XCTAssertEqual(clock.seconds, 0)
    }
  }

  func testInvalidAndReversedClocksCannotEarnMinutes() {
    var clock = TwitchWatchTime()
    for value in [Double.nan, .infinity, -.infinity] {
      var invalid = sample(0)
      invalid.playhead = value
      XCTAssertFalse(clock.sample(invalid))
      invalid = sample(0)
      invalid.uptime = value
      XCTAssertFalse(clock.sample(invalid))
      invalid = sample(0)
      invalid.rate = value
      XCTAssertFalse(clock.sample(invalid))
    }
    _ = clock.sample(sample(10))
    _ = clock.sample(sample(9))
    XCTAssertEqual(clock.seconds, 0)
  }

  func testFasterPlaybackCannotEarnMoreThanWallTime() {
    var clock = TwitchWatchTime()
    for second in 0...60 {
      var value = sample(Double(second))
      value.rate = 1.1
      value.playhead = Double(second) * 1.1
      XCTAssertEqual(clock.sample(value), second == 60)
    }
  }
}

private actor WatchRewardsTransport {
  var requests: [URLRequest] = []
  var status = 200
  var response = "{}"

  func set(_ response: String, status: Int = 200) {
    self.response = response
    self.status = status
  }

  func load(_ request: URLRequest) -> (Data, URLResponse) {
    requests.append(request)
    return (
      Data(response.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}

final class TwitchWatchRewardsAPITests: XCTestCase {
  func testDeviceGrantAndActivationURLStayOnTwitch() async throws {
    let transport = WatchRewardsTransport()
    await transport.set(#"{"device_code":"private-code","user_code":"ABCD","verification_uri":"https://www.twitch.tv/activate","expires_in":1800,"interval":5}"#)
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    let code = try await api.deviceCode()
    XCTAssertEqual(code.activationURL?.host, "www.twitch.tv")
    XCTAssertEqual(URLComponents(url: code.activationURL!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "ABCD")
    let request = await transport.requests.first!
    let body = String(data: request.httpBody!, encoding: .utf8)!
    XCTAssertTrue(body.contains("client_id=\(TwitchWatchRewardsAPI.clientID)"))
    XCTAssertTrue(body.contains("scopes="))
    XCTAssertFalse(body.contains("private-code"))
    await transport.set(#"{"device_code":"private-code","user_code":"ABCD","verification_uri":"https://example.org/activate","expires_in":1800,"interval":5}"#)
    do { _ = try await api.deviceCode(); XCTFail("Untrusted activation URL accepted") }
    catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .malformedResponse) }
  }

  func testPollingErrorsAreNotTokens() async {
    let transport = WatchRewardsTransport()
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    let errors: [(String, TwitchWatchRewardsAPI.Failure)] = [
      ("authorization_pending", .authorizationPending), ("slow_down", .slowDown),
      ("access_denied", .denied), ("expired_token", .expiredCode),
      ("invalid_device_code", .expiredCode),
    ]
    for (message, expected) in errors {
      await transport.set("{\"message\":\"\(message)\"}", status: 400)
      do { _ = try await api.exchange("code"); XCTFail("Polling error accepted") }
      catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, expected) }
    }
  }

  func testOnlyServerMilestoneValueSuppliesStreak() async throws {
    let transport = WatchRewardsTransport()
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    await transport.set(#"{"data":{"channel":{"self":{"watchStreakMilestone":{"watchStreakMilestone":{"value":"17"}}}}}}"#)
    let streak = try await api.streak(channelID: "channel", token: "test-token")
    XCTAssertEqual(streak.count, 17)
    await transport.set(#"{"data":{"channel":{"self":{"watchStreakMilestone":null}}}}"#)
    let missing = try await api.streak(channelID: "channel", token: "test-token")
    XCTAssertNil(missing.count)
  }

  func testMissingOrRejectedDataCannotLookLikeAZeroStreak() async {
    let transport = WatchRewardsTransport()
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    for response in [
      #"{"data":null}"#,
      #"{"data":{"channel":{"self":null}}}"#,
      #"{"data":{"channel":{"self":{"watchStreakMilestone":null}}},"errors":[{"message":"rejected"}]}"#,
      #"{"data":{"channel":{"self":{"watchStreakMilestone":{"watchStreakMilestone":{"value":"-1"}}}}}}"#,
      #"{"data":{"channel":{"self":{"watchStreakMilestone":{"watchStreakMilestone":{"value":"invalid"}}}}}}"#,
    ] {
      await transport.set(response)
      do { _ = try await api.streak(channelID: "channel", token: "test-token"); XCTFail(response) }
      catch { XCTAssertTrue(error is TwitchWatchRewardsAPI.Failure) }
    }
  }

  func testReportPayloadIsBoundToActualViewerAndBroadcast() async throws {
    let transport = WatchRewardsTransport()
    await transport.set("", status: 204)
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    try await api.reportMinute(
      stream: .init(channelID: "12", broadcastID: "34", login: "channel"),
      userID: "56", muted: true, now: Date(timeIntervalSince1970: 0))
    let request = await transport.requests.first!
    XCTAssertEqual(request.url?.absoluteString, "https://spade.twitch.tv/track")
    let form = String(data: request.httpBody!, encoding: .utf8)!
    let encoded = String(form.dropFirst("data=".count)).removingPercentEncoding!
    let events = try JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: encoded))) as! [[String: Any]]
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0]["event"] as? String, "minute-watched")
    let properties = try XCTUnwrap(events[0]["properties"] as? [String: Any])
    XCTAssertEqual(properties["user_id"] as? String, "56")
    XCTAssertEqual(properties["broadcast_id"] as? String, "34")
    XCTAssertEqual(properties["channel_id"] as? String, "12")
    XCTAssertEqual(properties["muted"] as? Bool, true)
    XCTAssertEqual(properties["hidden"] as? Bool, false)
    XCTAssertEqual(properties["minutes_logged"] as? Int, 1)
    XCTAssertNil(properties["access_token"])
  }

  func testReportRequiresExactAcknowledgement() async {
    let transport = WatchRewardsTransport()
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    for status in [200, 401, 403, 429, 500] {
      await transport.set("{}", status: status)
      do {
        try await api.reportMinute(
          stream: .init(channelID: "12", broadcastID: "34", login: "channel"),
          userID: "56", muted: false, now: Date())
        XCTFail("Accepted status \(status)")
      } catch { XCTAssertTrue(error is TwitchWatchRewardsAPI.Failure) }
    }
  }

  func testDifferentAccountAndClientCannotConnect() async {
    let transport = WatchRewardsTransport()
    let api = TwitchWatchRewardsAPI(load: { await transport.load($0) })
    await transport.set(#"{"client_id":"other","user_id":"viewer","login":"viewer","expires_in":1000}"#)
    do { _ = try await api.validate("token", expectedUserID: "viewer"); XCTFail() }
    catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .unsupported) }
    await transport.set("{\"client_id\":\"\(TwitchWatchRewardsAPI.clientID)\",\"user_id\":\"other\",\"login\":\"other\",\"expires_in\":1000}")
    do { _ = try await api.validate("token", expectedUserID: "viewer"); XCTFail() }
    catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .accountMismatch) }
  }

  func testZeroLifetimeIsValidAndPositiveLifetimeKeepsItsDeadline() async throws {
    for lifetime in [0, 3600] {
      let scenario = WatchRewardsScenario()
      await scenario.setValidation(lifetime: lifetime)
      let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
      let startedAt = Date()
      let credential = try await api.validate("test-token", expectedUserID: "viewer")
      if lifetime == 0 {
        XCTAssertNil(credential.expiresAt)
      } else {
        let expiresAt = try XCTUnwrap(credential.expiresAt)
        XCTAssertGreaterThanOrEqual(expiresAt, startedAt.addingTimeInterval(3600))
        XCTAssertLessThanOrEqual(expiresAt, Date().addingTimeInterval(3600))
      }
      let requests = await scenario.requests
      XCTAssertEqual(requests.map(\.url?.path), ["/oauth2/validate", "/gql"])
    }
  }

  func testNegativeLifetimeCannotConnect() async {
    let scenario = WatchRewardsScenario()
    await scenario.setValidation(lifetime: -1)
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    do { _ = try await api.validate("test-token", expectedUserID: "viewer"); XCTFail() }
    catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .malformedResponse) }
  }

  func testZeroLifetimeDoesNotBypassPrivateIdentityChecks() async {
    for status in [200, 401] {
      let scenario = WatchRewardsScenario()
      await scenario.setValidation(lifetime: 0)
      let api = TwitchWatchRewardsAPI(load: { request in
        if request.url?.host == "gql.twitch.tv" {
          return (
            Data(#"{"data":{"currentUser":{"id":"other-viewer"}}}"#.utf8),
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return await scenario.load(request)
      })
      do { _ = try await api.validate("test-token", expectedUserID: "viewer"); XCTFail() }
      catch {
        XCTAssertEqual(
          error as? TwitchWatchRewardsAPI.Failure,
          status == 200 ? .accountMismatch : .unauthorized)
      }
    }
  }

  func testPreviouslyStoredFiniteExpiryRemainsDecodable() throws {
    let data = Data(#"{"token":"test-token","userID":"viewer","login":"viewer","expiresAt":123}"#.utf8)
    let credential = try JSONDecoder().decode(TwitchWatchRewardsAPI.Credential.self, from: data)
    XCTAssertEqual(credential.expiresAt, Date(timeIntervalSinceReferenceDate: 123))
  }
}

@MainActor
private final class WatchRewardsMemoryStore {
  var data: Data?
  var writes = 0
  var failWrite = false

  var store: TwitchWatchRewardsStore {
    TwitchWatchRewardsStore(
      read: { self.data },
      write: {
        if self.failWrite { throw TwitchWatchRewardsAPI.Failure.secureStorage(-1) }
        self.data = $0
        self.writes += 1
      },
      remove: { self.data = nil })
  }
}

private actor WatchRewardsScenario {
  var requests: [URLRequest] = []
  var streak = 7
  var broadcastID = "broadcast-id"
  var rejectReports = false
  var blockStream = false
  var streamContinuation: CheckedContinuation<Void, Never>?
  var validationLifetime = 3600
  var validationStatus = 200

  func setValidation(lifetime: Int, status: Int = 200) {
    validationLifetime = lifetime
    validationStatus = status
  }

  func configure(rejectReports: Bool = false, blockStream: Bool = false) {
    self.rejectReports = rejectReports
    self.blockStream = blockStream
  }

  func releaseStream() {
    streamContinuation?.resume()
    streamContinuation = nil
  }

  func setServerState(streak: Int, broadcastID: String = "broadcast-id") {
    self.streak = streak
    self.broadcastID = broadcastID
  }

  var reportCount: Int { requests.filter { $0.url?.host == "spade.twitch.tv" }.count }
  var streamBlocked: Bool { streamContinuation != nil }

  func load(_ request: URLRequest) async -> (Data, URLResponse) {
    requests.append(request)
    var status = 200
    let body: String
    switch request.url!.path {
    case "/oauth2/device":
      body = #"{"device_code":"private","user_code":"CODE","verification_uri":"https://www.twitch.tv/activate","expires_in":1800,"interval":1}"#
    case "/oauth2/token":
      body = #"{"access_token":"test-token"}"#
    case "/oauth2/validate":
      status = validationStatus
      body = "{\"client_id\":\"\(TwitchWatchRewardsAPI.clientID)\",\"user_id\":\"viewer\",\"login\":\"viewer\",\"expires_in\":\(validationLifetime)}"
    case "/track":
      status = rejectReports ? 500 : 204
      body = ""
      // An accepted transport response deliberately does not change the server streak.
    default:
      let requestBody = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
      if requestBody.contains("currentUser") {
        body = #"{"data":{"currentUser":{"id":"viewer"}}}"#
      } else if requestBody.contains("StrozzWatchStream") {
        if blockStream { await withCheckedContinuation { streamContinuation = $0 } }
        body = "{\"data\":{\"user\":{\"id\":\"channel-id\",\"stream\":{\"id\":\"\(broadcastID)\"}}}}"
      } else if requestBody.contains("ChannelPointsContext") {
        body = #"{"data":{"community":{"channel":{"id":"channel-id","self":{"communityPoints":{"balance":0}},"communityPointsSettings":{"isEnabled":true,"customRewards":[],"automaticRewards":[],"emoteVariants":[]}}}}}"#
      } else {
        body = "{\"data\":{\"channel\":{\"self\":{\"watchStreakMilestone\":{\"watchStreakMilestone\":{\"value\":\"\(streak)\"}}}}}}"
      }
    }
    return (Data(body.utf8), HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor
final class TwitchWatchRewardsIntegrationTests: XCTestCase {
  private let item = NSObject()

  private func savedSession(
    _ scenario: WatchRewardsScenario, expiresAt: Date? = Date().addingTimeInterval(3600)
  ) throws -> (TwitchWatchRewardsSession, WatchRewardsMemoryStore, TwitchWatchRewardsAPI) {
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    store.data = try JSONEncoder().encode(TwitchWatchRewardsAPI.Credential(
      token: "test-token", userID: "viewer", login: "viewer", expiresAt: expiresAt))
    return (TwitchWatchRewardsSession(api: api, store: store.store), store, api)
  }

  private func playback(_ second: Int) -> TwitchWatchPlayback {
    TwitchWatchPlayback(
      target: .init(channel: "channel", userID: "viewer", itemID: ObjectIdentifier(item)),
      uptime: Double(second), playhead: Double(second))
  }

  private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true", file: file, line: line)
  }

  func testNoConnectionSendsNothing() async throws {
    let scenario = WatchRewardsScenario()
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let session = TwitchWatchRewardsSession(api: api, store: WatchRewardsMemoryStore().store)
    let tracker = TwitchWatchTracker(api: api)
    for second in 0...180 { tracker.update(playback(second), session: session) }
    await Task.yield()
    let requests = await scenario.requests
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(tracker.state, .idle)
  }

  func testAcceptedMinuteDoesNotInventStreakProgress() async throws {
    let scenario = WatchRewardsScenario()
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.lastCheckedAt != nil }
    XCTAssertEqual(tracker.streak, 7)
    for second in 1...60 { tracker.update(playback(second), session: session) }
    try await eventually { tracker.acceptedReports == 1 }
    XCTAssertEqual(tracker.streak, 7)
    XCTAssertEqual(tracker.observedStreakIncreases, 0)
    let count = await scenario.reportCount
    XCTAssertEqual(count, 1)
  }

  func testRejectedMinuteIsVisibleAndNotReplayed() async throws {
    let scenario = WatchRewardsScenario()
    await scenario.configure(rejectReports: true)
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.lastCheckedAt != nil }
    for second in 1...60 { tracker.update(playback(second), session: session) }
    try await eventually { tracker.state == .unavailable }
    XCTAssertEqual(tracker.acceptedReports, 0)
    XCTAssertNotNil(tracker.errorMessage)
    for second in 61...90 { tracker.update(playback(second), session: session) }
    await Task.yield()
    let count = await scenario.reportCount
    XCTAssertEqual(count, 1)
  }

  func testOnlyServerChangeCountsAsStreakIncrease() async throws {
    let scenario = WatchRewardsScenario()
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.lastCheckedAt != nil }
    await scenario.setServerState(streak: 8)
    for second in 1...60 { tracker.update(playback(second), session: session) }
    try await eventually { tracker.acceptedReports == 1 }
    XCTAssertEqual(tracker.streak, 8)
    XCTAssertEqual(tracker.observedStreakIncreases, 1)
  }

  func testBroadcastRestartCannotReceiveTheOldBroadcastsMinute() async throws {
    let scenario = WatchRewardsScenario()
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.lastCheckedAt != nil }
    await scenario.setServerState(streak: 9, broadcastID: "new-broadcast")
    for second in 1...60 { tracker.update(playback(second), session: session) }
    try await eventually { tracker.streak == 9 }
    let count = await scenario.reportCount
    XCTAssertEqual(count, 0)
    XCTAssertEqual(tracker.acceptedReports, 0)
  }

  func testPausingDuringMinuteLookupCancelsTheReport() async throws {
    let scenario = WatchRewardsScenario()
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.lastCheckedAt != nil }
    await scenario.configure(blockStream: true)
    for second in 1...60 { tracker.update(playback(second), session: session) }
    for _ in 0..<200 {
      if await scenario.streamBlocked { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    var paused = playback(61)
    paused.userPaused = true
    tracker.update(paused, session: session)
    await scenario.releaseStream()
    for _ in 0..<10 { await Task.yield() }
    let count = await scenario.reportCount
    XCTAssertEqual(count, 0)
    XCTAssertEqual(tracker.state, .paused)
  }

  func testClosingDuringLookupCannotSendOrPublishLateResults() async throws {
    let scenario = WatchRewardsScenario()
    await scenario.configure(blockStream: true)
    let (session, _, api) = try savedSession(scenario)
    let tracker = TwitchWatchTracker(api: api)
    tracker.update(playback(0), session: session)
    for _ in 0..<200 {
      if await scenario.streamBlocked { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    tracker.stop()
    await scenario.releaseStream()
    for _ in 0..<10 { await Task.yield() }
    let count = await scenario.reportCount
    XCTAssertEqual(count, 0)
    XCTAssertNil(tracker.streak)
    XCTAssertEqual(tracker.state, .idle)
  }

  func testExpiredAndChangedAccountsNeverReport() async throws {
    let scenario = WatchRewardsScenario()
    let (session, store, api) = try savedSession(scenario, expiresAt: .distantPast)
    let tracker = TwitchWatchTracker(api: api)
    defer { tracker.stop() }
    tracker.update(playback(0), session: session)
    try await eventually { tracker.state == .unavailable }
    XCTAssertFalse(session.isConnected)
    XCTAssertNil(store.data)
    let requests = await scenario.requests
    XCTAssertTrue(requests.isEmpty)

    let (other, otherStore, _) = try savedSession(scenario)
    other.accountChanged(to: "different-viewer")
    XCTAssertFalse(other.isConnected)
    XCTAssertNil(otherStore.data)
  }

  func testDeviceSignInPersistsOnlyValidatedSessionAndDisconnectRemovesIt() async throws {
    let scenario = WatchRewardsScenario()
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    await session.connect(expectedUserID: "viewer")
    XCTAssertTrue(session.isConnected)
    XCTAssertEqual(store.writes, 1)
    XCTAssertNil(session.deviceCode)
    XCTAssertNil(session.errorMessage)
    session.disconnect()
    XCTAssertFalse(session.isConnected)
    XCTAssertNil(store.data)
  }

  func testNonExpiringSessionConnectsAndRevalidatesAfterRestore() async throws {
    let scenario = WatchRewardsScenario()
    await scenario.setValidation(lifetime: 0)
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    await session.connect(expectedUserID: "viewer")
    XCTAssertTrue(session.isConnected)
    XCTAssertNil(session.credential?.expiresAt)
    XCTAssertNil(session.errorMessage)
    XCTAssertEqual(store.writes, 1)

    let restored = TwitchWatchRewardsSession(api: api, store: store.store)
    XCTAssertTrue(restored.isConnected)
    let credential = try await restored.validatedCredential(expectedUserID: "viewer")
    XCTAssertNil(credential.expiresAt)
    let requests = await scenario.requests
    XCTAssertEqual(requests.filter { $0.url?.path == "/oauth2/validate" }.count, 2)
    _ = try await restored.validatedCredential(expectedUserID: "viewer")
    let cachedRequests = await scenario.requests
    XCTAssertEqual(cachedRequests.count, requests.count)
  }

  func testRevokedNonExpiringSessionIsStillDisconnected() async throws {
    let scenario = WatchRewardsScenario()
    await scenario.setValidation(lifetime: 0, status: 401)
    let (session, store, _) = try savedSession(scenario, expiresAt: nil)
    do { _ = try await session.validatedCredential(expectedUserID: "viewer"); XCTFail() }
    catch { XCTAssertEqual(error as? TwitchWatchRewardsAPI.Failure, .unauthorized) }
    XCTAssertFalse(session.isConnected)
    XCTAssertNil(store.data)
    let requests = await scenario.requests
    XCTAssertEqual(requests.map(\.url?.path), ["/oauth2/validate"])
  }

  func testRejectedNewConnectionDoesNotSendUserBackToSettings() async {
    let scenario = WatchRewardsScenario()
    await scenario.setValidation(lifetime: 0, status: 401)
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    await session.connect(expectedUserID: "viewer")
    XCTAssertFalse(session.isConnected)
    XCTAssertNil(store.data)
    XCTAssertEqual(
      session.errorMessage,
      String(localized: "Twitch did not accept this rewards sign-in. Choose Try Again to request a new code."))
  }

  func testSecureStorageFailureCannotLookConnected() async {
    let scenario = WatchRewardsScenario()
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    store.failWrite = true
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    await session.connect(expectedUserID: "viewer")
    XCTAssertFalse(session.isConnected)
    XCTAssertNil(store.data)
    XCTAssertNotNil(session.errorMessage)
  }

  func testPairingAnotherAccountNeverStoresItsToken() async {
    let scenario = WatchRewardsScenario()
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    await session.connect(expectedUserID: "different-viewer")
    XCTAssertFalse(session.isConnected)
    XCTAssertEqual(store.writes, 0)
    XCTAssertNotNil(session.errorMessage)
  }

  func testCancelPairingPreventsTokenExchangeAndStorage() async throws {
    let scenario = WatchRewardsScenario()
    let api = TwitchWatchRewardsAPI(load: { await scenario.load($0) })
    let store = WatchRewardsMemoryStore()
    let session = TwitchWatchRewardsSession(api: api, store: store.store)
    let connection = Task { await session.connect(expectedUserID: "viewer") }
    try await eventually { session.deviceCode != nil }
    session.cancelConnection()
    connection.cancel()
    await connection.value
    XCTAssertFalse(session.isConnected)
    XCTAssertEqual(store.writes, 0)
    let requests = await scenario.requests
    XCTAssertFalse(requests.contains { $0.url?.path == "/oauth2/token" })
  }
}
