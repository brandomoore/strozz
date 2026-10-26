import XCTest

#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class KickFollowingTests: XCTestCase {
  private let account = Data(#"{"id":42,"username":"Viewer"}"#.utf8)

  func testImportReadsEveryPageAndChecksAccountAgain() async throws {
    var paths: [String] = []
    let result = try await KickFollowImport.read { path in
      paths.append(path)
      if path == "/api/v1/user" { return self.account }
      if path.hasSuffix("cursor=0") {
        return Data(#"{"channels":[{"channel_slug":"first","user_username":"First","is_live":true}],"nextCursor":3}"#.utf8)
      }
      return Data(#"{"channels":[{"channel_slug":"second","is_live":false}],"nextCursor":null}"#.utf8)
    }
    XCTAssertEqual(result.follows.map(\.slug), ["first", "second"])
    XCTAssertTrue(result.follows[0].isLive)
    XCTAssertEqual(paths, ["/api/v1/user", "/api/v2/channels/followed?cursor=0",
      "/api/v2/channels/followed?cursor=3", "/api/v1/user"])
  }

  func testOnlyExplicitEmptyListIsAValidEmptyImport() throws {
    XCTAssertTrue(try KickFollowImport.decodePage(Data(#"{"channels":[],"nextCursor":null}"#.utf8)).follows.isEmpty)
    for json in ["{}", #"{"message":"blocked"}"#, #"{"channels":null}"#,
      #"{"channels":[]}"#, #"{"channels":[{"channel_slug":"valid","is_live":true}]}"#,
      #"{"channels":[{"channel_slug":"valid"}]}"#,
      #"{"channels":[{"channel_slug":"../bad","is_live":true}],"nextCursor":null}"#] {
      XCTAssertThrowsError(try KickFollowImport.decodePage(Data(json.utf8)), json)
    }
    XCTAssertThrowsError(try KickFollowImport.decodeAccount(Data("{}".utf8)))
  }

  func testPaginationFailureCannotReturnPartialSuccess() async {
    do {
      _ = try await KickFollowImport.read { path in
        if path == "/api/v1/user" { return self.account }
        if path.hasSuffix("cursor=0") {
          return Data(#"{"channels":[{"channel_slug":"first","is_live":true}],"nextCursor":5}"#.utf8)
        }
        throw URLError(.notConnectedToInternet)
      }
      XCTFail("Partial list must not be accepted")
    } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
  }

  func testRepeatingCursorCannotLoopOrCommitPartialRoster() async {
    do {
      _ = try await KickFollowImport.read { path in
        if path == "/api/v1/user" { return self.account }
        return Data(#"{"channels":[{"channel_slug":"first","is_live":true}],"nextCursor":0}"#.utf8)
      }
      XCTFail("Repeating cursor must fail")
    } catch { XCTAssertEqual(error as? KickFollowingError, .incomplete) }
  }

  func testAccountSwitchDuringImportIsRejected() async {
    var identitiesRead = 0
    do {
      _ = try await KickFollowImport.read { path in
        if path == "/api/v1/user" {
          identitiesRead += 1
          return identitiesRead == 1 ? self.account : Data(#"{"id":43,"username":"Other"}"#.utf8)
        }
        return Data(#"{"channels":[],"nextCursor":null}"#.utf8)
      }
      XCTFail("Account switching cannot publish another account's roster")
    } catch { XCTAssertEqual(error as? KickFollowingError, .accountChanged) }
  }

  func testCancelledImportDoesNotContinuePagination() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await KickFollowImport.read { path in
        XCTAssertEqual(path, "/api/v1/user")
        return self.account
      }
    }
    do { _ = try await task.value; XCTFail("Cancelled import must fail") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testDuplicateFollowsAcrossPagesAreDeduplicated() async throws {
    let value = try await KickFollowImport.read { path in
      if path == "/api/v1/user" { return self.account }
      let next = path.hasSuffix("cursor=0") ? "1" : "null"
      return Data("{\"channels\":[{\"channel_slug\":\"first\",\"is_live\":true}],\"nextCursor\":\(next)}".utf8)
    }
    XCTAssertEqual(value.follows.count, 1)
  }

  func testCancellationDuringFinalAccountCheckCannotReturnSuccess() async {
    var reads = 0
    do {
      _ = try await Task {
        try await KickFollowImport.read { path in
          if path == "/api/v1/user" {
            reads += 1
            if reads == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            return self.account
          }
          return Data(#"{"channels":[],"nextCursor":null}"#.utf8)
        }
      }.value
      XCTFail("Cancelled final verification must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testFollowSnapshotRejectsCredentialURLsAndOversizedMetadata() throws {
    let account = KickFollowAccount(id: 42, username: "Viewer")
    let invalid = KickFollow(slug: "first", displayName: "First", imageURL: URL(string: "file:///private/fixture"))
    XCTAssertThrowsError(try KickFollowDocument(
      connectionID: UUID(), account: account, follows: [invalid], importedAt: Date()).validated())
    XCTAssertThrowsError(try KickFollowDocument(
      connectionID: UUID(), account: nil, follows: [follow("first")], importedAt: Date()).validated())
    XCTAssertThrowsError(try KickFollowDocument(
      connectionID: UUID(), account: account, follows: [follow("first"), follow("first")], importedAt: Date()).validated())
  }

  func testImportPublishesMetadataAndRestoresOnSecondDeviceWithoutSession() async throws {
    let database = KickFollowingTestDatabase()
    let localDefaults = defaults()
    let store = KickFollowingStore(database: database, defaults: localDefaults)
    try await store.publish(imported(), interactive: true)
    XCTAssertTrue(store.isImporter)
    let other = KickFollowingStore(database: database, defaults: defaults())
    await other.synchronize()
    XCTAssertTrue(other.isConnected)
    XCTAssertFalse(other.isImporter)
    XCTAssertEqual(other.document?.follows.map(\.slug), ["first"])
    let data = try JSONEncoder().encode(XCTUnwrap(other.document))
    let json = String(decoding: data, as: UTF8.self)
    for secret in ["session_token", "Authorization", "password", "access_token"] {
      XCTAssertFalse(json.contains(secret))
    }
  }

  func testAutomaticRefreshDoesNotResurrectDisconnectedConnection() async throws {
    let database = KickFollowingTestDatabase()
    let source = KickFollowingStore(database: database, defaults: defaults())
    try await source.publish(imported(), interactive: true)
    let tv = KickFollowingStore(database: database, defaults: defaults())
    await tv.synchronize()
    try await tv.disconnect()
    XCTAssertFalse(tv.isConnected)
    do { try await source.publish(imported(), interactive: false); XCTFail("Revoked importer must not restore follows") }
    catch { XCTAssertEqual(error as? KickFollowingError, .accountChanged) }
    await source.synchronize()
    XCTAssertFalse(source.isConnected)
    XCTAssertFalse(source.isImporter)
  }

  func testDifferentKickAccountCannotSilentlyReplaceExistingConnection() async throws {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(), defaults: defaults())
    try await store.publish(imported(), interactive: true)
    do {
      try await store.publish(.init(account: .init(id: 43, username: "Other"), follows: []), interactive: true)
      XCTFail("Must disconnect the previous account explicitly")
    } catch { XCTAssertEqual(error as? KickFollowingError, .conflict) }
    XCTAssertEqual(store.document?.account?.id, 42)
  }

  func testFailedCloudWritePreservesLastSavedList() async throws {
    let database = KickFollowingTestDatabase()
    let store = KickFollowingStore(database: database, defaults: defaults())
    try await store.publish(imported(), interactive: true)
    await database.failWrites()
    do {
      try await store.publish(.init(account: imported().account, follows: []), interactive: false)
      XCTFail("A failed write must be reported")
    } catch { XCTAssertNotNil(store.errorMessage) }
    XCTAssertEqual(store.document?.follows.map(\.slug), ["first"])
  }

  func testChangingAppleAccountClearsRosterAndImporterBinding() async throws {
    let database = KickFollowingTestDatabase()
    let store = KickFollowingStore(database: database, defaults: defaults())
    try await store.publish(imported(), interactive: true)
    await database.switchOwner()
    await store.synchronize()
    XCTAssertNil(store.document)
    XCTAssertFalse(store.isImporter)
    XCTAssertEqual(store.cloudOwner, "other")
  }

  func testSavedRosterIsNotExposedBeforeAppleAccountIsChecked() async throws {
    let database = KickFollowingTestDatabase()
    let sharedDefaults = defaults()
    let first = KickFollowingStore(database: database, defaults: sharedDefaults)
    try await first.publish(imported(), interactive: true)
    let reopened = KickFollowingStore(database: database, defaults: sharedDefaults)
    XCTAssertNil(reopened.document)
    await database.switchOwner()
    await reopened.synchronize()
    XCTAssertNil(reopened.document)
    XCTAssertFalse(reopened.isImporter)
  }

  func testSameNameWithoutVerifiedLinkRemainsTwoCreators() {
    let rows = KickUnifiedFeed.merge(twitch: [twitch("first")], kick: [kick("first")], links: [:])
    XCTAssertEqual(rows.map(\.channelKey), ["first", "kick:first"])
  }

  func testVerifiedSimulcastMergesCountsWithoutChangingTwitchIdentity() {
    let rows = KickUnifiedFeed.merge(twitch: [twitch("first")], kick: [kick("second")], links: ["first": "second"])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].platform, .twitch)
    XCTAssertEqual(rows[0].kick?.slug, "second")
    XCTAssertEqual(rows[0].combinedViewerCount, 30)
  }

  func testOfflineTwitchPromotesTheLiveKickSource() {
    let rows = KickUnifiedFeed.merge(twitch: [twitch("first", live: false)],
      kick: [kick("second")], links: ["first": "second"])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].platform, .kick)
    XCTAssertEqual(rows[0].login, "second")
    XCTAssertTrue(rows[0].isLive)
  }

  func testAmbiguousCreatorLinksDoNotCollapseUnrelatedAccounts() {
    let rows = KickUnifiedFeed.merge(twitch: [twitch("one"), twitch("two")],
      kick: [kick("shared")], links: ["one": "shared", "two": "shared"])
    XCTAssertEqual(rows.count, 3)
  }

  func testRecommendationsInterleavePlatformsAndDeduplicateQualifiedIdentities() {
    let rows = KickUnifiedFeed.interleave(
      [twitch("one"), twitch("two")], [kick("one").followedChannel, kick("one").followedChannel])
    XCTAssertEqual(rows.map(\.channelKey), ["one", "kick:one", "two"])
  }

  func testMetadataFailureRetainsKnownLiveStatus() async throws {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(), defaults: defaults())
    var followed = follow("first")
    followed.isLive = true
    try await store.publish(.init(account: imported().account, follows: [followed]), interactive: true)
    let discovery = KickDiscoveryService(follows: store, load: { _ in throw URLError(.timedOut) })
    await discovery.refresh(twitch: [])
    XCTAssertTrue(try XCTUnwrap(discovery.directory.first).isLive)
    XCTAssertNotNil(discovery.errorMessage)
  }

  func testFollowLivenessLoadsBeforeIdentityDiscoveryAndLimitsConcurrency() async throws {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(), defaults: defaults())
    try await store.publish(.init(account: imported().account,
      follows: (0..<9).map { follow("follow-\($0)") }), interactive: true)
    let probe = KickDiscoveryProbe()
    let discovery = KickDiscoveryService(follows: store, load: { slug in
      await probe.begin("live:\(slug)")
      try await Task.sleep(for: .milliseconds(15))
      await probe.end()
      return KickChannel(slug: slug, displayName: slug, title: "", category: "", viewerCount: 20,
        isLive: true, chatroomID: nil, imageURL: nil)
    }, resolve: { root in
      await probe.begin("identity:\(root.channel)")
      try await Task.sleep(for: .milliseconds(15))
      await probe.end()
      return CreatorLiveSources(root: root)
    })
    await discovery.refresh(twitch: (0..<9).map { twitch("creator-\($0)") })
    let events = await probe.events
    let maximum = await probe.maximum
    XCTAssertEqual(events.count, 18)
    XCTAssertTrue(events.prefix(9).allSatisfy { $0.hasPrefix("live:") })
    XCTAssertEqual(maximum, 4)
    XCTAssertEqual(discovery.directory.count, 9)
    XCTAssertTrue(discovery.directory.allSatisfy(\.isLive))
  }

  func testAccountChangeFencesInFlightIdentityResults() async throws {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(), defaults: defaults())
    let entered = expectation(description: "Identity resolution entered")
    var continuation: CheckedContinuation<CreatorLiveSources, Never>?
    let discovery = KickDiscoveryService(follows: store, load: { _ in
      XCTFail("Stale identity must not start metadata requests")
      throw URLError(.cancelled)
    }, resolve: { _ in
      await withCheckedContinuation { continuation = $0; entered.fulfill() }
    })
    let refresh = Task { await discovery.refresh(twitch: [twitch("creator")]) }
    await fulfillment(of: [entered], timeout: 2)
    discovery.accountChanged()
    var result = CreatorLiveSources(root: .init(platform: .twitch, channel: "creator"))
    result.kick = "different"
    continuation?.resume(returning: result)
    await refresh.value
    XCTAssertTrue(discovery.links.isEmpty)
    XCTAssertTrue(discovery.recommended.isEmpty)
    XCTAssertNil(discovery.lastUpdatedAt)
  }

  func testUnifiedSearchKeepsSameNamedProvidersDistinct() async {
    let service = SearchService(loadData: { request in
      let data = Data(#"{"data":{"searchFor":{"channels":{"edges":[{"item":{"id":"1","login":"first","displayName":"First"}}]},"games":{"edges":[]}}}}"#.utf8)
      return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }, loadKick: { slug in
      KickChannel(slug: slug, displayName: "First", title: "", category: "", viewerCount: 10,
        isLive: true, chatroomID: nil, imageURL: nil)
    })
    await service.search("first")
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["first", "kick:first"])
    XCTAssertNil(service.errorMessage)
  }

  func testKickSearchStillReturnsItsChannelWhenTwitchFails() async {
    let service = SearchService(loadData: { _ in throw URLError(.timedOut) }, loadKick: { slug in
      KickChannel(slug: slug, displayName: slug, title: "", category: "", viewerCount: nil,
        isLive: false, chatroomID: nil, imageURL: nil)
    })
    await service.search("https://kick.com/first")
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["kick:first"])
    XCTAssertNotNil(service.errorMessage)
  }

  #if os(tvOS)
  func testMultiviewKeepsSameNamedTwitchAndKickChannelsAsSeparatePanes() {
    let controller = MultiviewController(channels: [twitch("first"), kick("first").followedChannel])
    XCTAssertEqual(controller.panes.map(\.channel.channelKey), ["first", "kick:first"])
    XCTAssertEqual(Set(controller.panes.map(\.id)).count, 2)
    XCTAssertFalse(controller.panes[0].model === controller.panes[1].model)
    XCTAssertNil(controller.addPane(kick("first").followedChannel))
    XCTAssertEqual(controller.panes.count, 2)
  }

  func testMultiviewSwitchPreservesPaneAndPlayerButUpdatesProviderAndSlug() {
    let pane = MultiviewPane(channel: twitch("first"))
    let model = pane.model
    let id = pane.id
    pane.model.livePlatform = .kick
    pane.model.kickPlaybackTarget = "different"
    pane.synchronizeChannel()
    XCTAssertEqual(pane.channel.channelKey, "kick:different")
    XCTAssertEqual(pane.id, id)
    XCTAssertTrue(pane.model === model)
    pane.model.livePlatform = .twitch
    pane.model.activeChannel = "different"
    pane.synchronizeChannel()
    XCTAssertEqual(pane.channel.channelKey, "different")
  }

  func testKickAndYouTubeMultiviewSourcesCannotReportTwitchWatchActivity() {
    let kickPane = MultiviewPane(channel: kick("first").followedChannel)
    XCTAssertFalse(kickPane.isTwitchLive)
    let twitchPane = MultiviewPane(channel: twitch("first"))
    XCTAssertTrue(twitchPane.isTwitchLive)
    twitchPane.model.livePlatform = .kick
    XCTAssertFalse(twitchPane.isTwitchLive)
    twitchPane.model.livePlatform = .twitch
    twitchPane.model.isUsingAltSource = true
    XCTAssertFalse(twitchPane.isTwitchLive)
  }
  #endif

  #if os(iOS)
  func testCancellingKickSetupResetsPresentationBeforeReconnecting() {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(), defaults: defaults())
    let signIn = MobileKickSignIn(defaults: defaults())
    signIn.connect(using: store)
    XCTAssertTrue(signIn.isPresented)
    signIn.dismiss()
    XCTAssertFalse(signIn.isPresented)
    signIn.connect(using: store)
    XCTAssertTrue(signIn.isPresented)
    signIn.dismiss()
  }

  func testKickWebsiteNetworkErrorsExplainRecoveryWithoutRawCodes() {
    let error = MobileKickSignIn.message(for: URLError(.networkConnectionLost))
    XCTAssertFalse(error.contains("-1005"))
    XCTAssertTrue(error.contains("try again"))
  }

  func testKickSetupPreparationTimesOutWithoutLeavingControlsDisabled() async throws {
    let store = KickFollowingStore(database: KickFollowingTestDatabase(ownerDelay: .seconds(60)),
      defaults: defaults())
    let signIn = MobileKickSignIn(defaults: defaults(), preparationTimeout: .milliseconds(20))
    signIn.connect(using: store)
    defer { signIn.dismiss() }
    let deadline = ContinuousClock.now + .seconds(2)
    while signIn.isPreparing, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(signIn.isPreparing)
    XCTAssertFalse(signIn.isImporting)
    XCTAssertTrue(signIn.isPresented)
    XCTAssertNotNil(signIn.errorMessage)
    XCTAssertNotNil(store.errorMessage)
  }
  #endif

  private func follow(_ slug: String) -> KickFollow {
    .init(slug: slug, displayName: slug, imageURL: nil)
  }
  private func imported() -> KickFollowImport {
    .init(account: .init(id: 42, username: "Viewer"), follows: [follow("first")])
  }
  private func kick(_ slug: String) -> KickChannel {
    .init(slug: slug, displayName: slug, title: "", category: "", viewerCount: 20,
      isLive: true, chatroomID: nil, imageURL: nil)
  }
  private func twitch(_ login: String, live: Bool = true) -> FollowedChannel {
    .init(id: login, login: login, displayName: login, title: "", gameName: "", viewerCount: 10,
      thumbnailURL: nil, profileImageURL: nil, isLive: live)
  }
  private func defaults() -> UserDefaults {
    let name = "KickFollowingTests.\(UUID().uuidString)"
    let value = UserDefaults(suiteName: name)!
    addTeardownBlock { value.removePersistentDomain(forName: name) }
    return value
  }
}

private actor KickDiscoveryProbe {
  private(set) var events: [String] = []
  private(set) var maximum = 0
  private var active = 0
  func begin(_ event: String) {
    events.append(event)
    active += 1
    maximum = max(maximum, active)
  }
  func end() { active -= 1 }
}

private actor KickFollowingTestDatabase: KickFollowingDatabase {
  private var ownerID = "owner"
  private var snapshot: KickCloudSnapshot?
  private var writesFail = false
  private let ownerDelay: Duration
  init(ownerDelay: Duration = .zero) { self.ownerDelay = ownerDelay }
  func owner() async throws -> String {
    if ownerDelay > .zero { try await Task.sleep(for: ownerDelay) }
    return ownerID
  }
  func fetch(owner: String) throws -> KickCloudSnapshot? {
    guard owner == ownerID else { throw KickFollowingError.accountChanged }
    return snapshot
  }
  func save(_ document: KickFollowDocument, owner: String, replacing: KickCloudSnapshot?) throws -> KickCloudSnapshot {
    guard owner == ownerID else { throw KickFollowingError.accountChanged }
    if writesFail { throw URLError(.notConnectedToInternet) }
    guard replacing?.version == snapshot?.version else { throw KickFollowingError.conflict }
    let saved = KickCloudSnapshot(document: try document.validated(), version: Data(UUID().uuidString.utf8))
    snapshot = saved
    return saved
  }
  func failWrites() { writesFail = true }
  func switchOwner() { ownerID = "other"; snapshot = nil }
}
