import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class TwitchAutomaticSignInTests: XCTestCase {
  func testFirstFrameAndSlowSavedAccountRestoreNeverLookSignedOut() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    try fixture.auth.persistCredential(fixture.credential())
    XCTAssertTrue(fixture.sync.isRestoringAccount, "The first frame precedes every startup task")
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    await fixture.database.holdOwner()
    let startup = Task { await fixture.start() }
    for _ in 0..<100 {
      if fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(fixture.auth.userID, "fixture", "A cached account is not a known signed-out state")
    XCTAssertFalse(fixture.auth.isAuthenticated, "Cloud ownership is still being checked")
    for _ in 0..<10 {
      XCTAssertTrue(fixture.sync.isRestoringAccount)
      XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
      await Task.yield()
    }
    await fixture.database.releaseOwner()
    await startup.value
    XCTAssertFalse(fixture.sync.isRestoringAccount)
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
  }

  func testMissingAndUnavailableAccountsEndThePlaceholderWithoutHidingErrors() async throws {
    let missing = try Fixture()
    defer { missing.stop() }
    XCTAssertTrue(missing.sync.isRestoringAccount)
    await missing.start()
    XCTAssertFalse(missing.sync.isRestoringAccount)
    XCTAssertTrue(missing.sync.shouldOfferInitialSignIn)

    let unavailable = try Fixture()
    defer { unavailable.stop() }
    await unavailable.database.setUnavailable()
    await unavailable.start()
    XCTAssertFalse(unavailable.sync.isRestoringAccount)
    XCTAssertNotNil(unavailable.sync.errorMessage)
    XCTAssertFalse(unavailable.sync.shouldOfferInitialSignIn)
  }

  func testSavedCloudAccountRestoresBeforeInitialSignInIsOffered() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    await fixture.start()
    XCTAssertTrue(fixture.sync.hasCompletedInitialSync)
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertEqual(fixture.auth.userID, "fixture")
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    XCTAssertFalse(fixture.auth.isAuthenticating)
    let requests = await fixture.network.requests
    XCTAssertFalse(requests.contains("/oauth2/device"))
  }

  func testLocalCacheRestorationPrecedesCloudImportAndConflictsAreExplicit() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    var local = try fixture.credential()
    local.userID = "another-user"
    try fixture.auth.persistCredential(local)
    await fixture.start()
    XCTAssertEqual(fixture.auth.userID, "another-user")
    XCTAssertTrue(fixture.sync.hasAccountConflict)
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    let stored = await fixture.database.fetch(owner: "owner")
    XCTAssertEqual(stored?.account.credential?.userID, "fixture")
  }

  func testLocalSignOutStaysSignedOutUntilOrdinarySignInIsChosen() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.signOut()
    await fixture.sync.synchronize()
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertTrue(fixture.sync.isSignedOutLocally)
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    let remote = await fixture.database.fetch(owner: "owner")
    XCTAssertNotNil(remote?.account.credential)
    await fixture.auth.beginDeviceCodeSignIn()
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertFalse(fixture.sync.isSignedOutLocally)
    XCTAssertNil(fixture.auth.activationCode)
    let requests = await fixture.network.requests
    XCTAssertFalse(requests.contains("/oauth2/device"), "Sign in must reuse the saved connection")
  }

  func testRelaunchHonorsPersistedLocalSignOut() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    fixture.defaults.set(true, forKey: PersistenceKey.icloudAccountSignedOut)
    let sync = TwitchAccountSync(database: fixture.database, defaults: fixture.defaults,
      storagePrefix: fixture.prefix)
    defer { sync.stop() }
    XCTAssertFalse(sync.isRestoringAccount, "An explicit local sign-out is already known on the first frame")
    try await fixture.saveCloudAccount()
    await sync.start(auth: fixture.auth, rewards: fixture.rewards)
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertTrue(sync.isSignedOutLocally)
    XCTAssertFalse(sync.shouldOfferInitialSignIn)
  }

  func testSignOutEverywherePublishesTombstoneAndClearsThisDevice() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.sync.signOutAllDevices()
    let remote = await fixture.database.fetch(owner: "owner")
    XCTAssertNil(remote?.account.credential)
    XCTAssertNil(remote?.account.rewards)
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertTrue(fixture.sync.isSignedOutLocally)
    await fixture.sync.synchronize()
    XCTAssertFalse(fixture.auth.isAuthenticated)
  }

  func testMissingCloudAccountOffersNormalOAuthWithoutExtraSyncButton() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    await fixture.start()
    XCTAssertTrue(fixture.sync.shouldOfferInitialSignIn)
    await fixture.auth.beginDeviceCodeSignIn()
    XCTAssertTrue(fixture.auth.isAuthenticating)
    XCTAssertEqual(fixture.auth.activationCode, "TEST-CODE")
    let requests = await fixture.network.requests
    XCTAssertEqual(requests.filter { $0 == "/oauth2/device" }.count, 1)
  }

  func testUnavailableCloudDoesNotStartACompetingOAuthFlowUntilExplicitlyChosen() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    await fixture.database.setUnavailable()
    await fixture.start()
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    XCTAssertNotNil(fixture.sync.errorMessage)
    await fixture.auth.beginDeviceCodeSignIn()
    XCTAssertFalse(fixture.auth.isAuthenticating)
    XCTAssertNotNil(fixture.auth.errorMessage)
    await fixture.auth.beginDeviceCodeSignIn(useSavedConnection: false)
    XCTAssertTrue(fixture.auth.isAuthenticating)
    XCTAssertEqual(fixture.auth.activationCode, "TEST-CODE")
  }

  func testConcurrentStartupAndSignInJoinInitialCloudCheck() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.database.holdOwner()
    let first = Task { await fixture.start() }
    for _ in 0..<100 {
      if fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(fixture.sync.isBusy)
    XCTAssertFalse(fixture.sync.shouldOfferInitialSignIn)
    let second = Task { await fixture.start() }
    let signIn = Task { await fixture.auth.beginDeviceCodeSignIn() }
    await Task.yield()
    XCTAssertFalse(fixture.auth.isAuthenticating, "OAuth must not block an in-flight iCloud check")
    await fixture.database.releaseOwner()
    await first.value
    await second.value
    await signIn.value
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertNil(fixture.auth.activationCode)
    let owners = await fixture.database.ownerRequests
    XCTAssertEqual(owners, 1)
  }
  func testForegroundSyncWaitsForExistingAccountUpdate() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.database.holdOwner()
    let first = Task { await fixture.sync.synchronize() }
    try await waitForBusy(fixture.sync)
    var secondFinished = false
    let second = Task { await fixture.sync.synchronize(); secondFinished = true }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(secondFinished, "Foreground callers must not refresh follows before sync finishes")
    await fixture.database.releaseOwner()
    await first.value
    await second.value
    XCTAssertTrue(secondFinished)
    XCTAssertFalse(fixture.sync.isBusy)
    XCTAssertNil(fixture.sync.errorMessage)
  }

  func testUnauthorizedRecoveryWaitsForSyncAndRotatesOnlyOnce() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.network.enableRefresh()
    await fixture.database.holdOwner()
    let sync = Task { await fixture.sync.synchronize() }
    try await waitForBusy(fixture.sync)
    let first = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    let second = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(fixture.sync.isBusy)
    let before = await fixture.network.requests
    XCTAssertFalse(before.contains("/oauth2/token"))
    await fixture.database.releaseOwner()
    await sync.value
    let tokens = try await [first.value, second.value]
    XCTAssertEqual(tokens, ["rotated-access", "rotated-access"])
    let requests = await fixture.network.requests
    XCTAssertEqual(requests.filter { $0 == "/oauth2/token" }.count, 1)
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertNil(fixture.sync.errorMessage)
    let snapshot = await fixture.database.fetch(owner: "owner")
    XCTAssertEqual(snapshot?.account.credential?.accessToken, "rotated-access")
    XCTAssertNil(snapshot?.account.refreshID)
  }

  func testCancelledRenewalWaiterDoesNotCancelSyncOrSpendRefreshToken() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.network.enableRefresh()
    await fixture.database.holdOwner()
    let sync = Task { await fixture.sync.synchronize() }
    try await waitForBusy(fixture.sync)
    let cancelled = expectation(description: "Cancelled waiter returns")
    let renewal = Task {
      do { _ = try await fixture.sync.renew(rejectedAccessToken: "synthetic-access"); XCTFail("Cancelled renewal succeeded") }
      catch { XCTAssertTrue(error is CancellationError) }
      cancelled.fulfill()
    }
    await Task.yield()
    renewal.cancel()
    await fulfillment(of: [cancelled], timeout: 2)
    XCTAssertTrue(fixture.sync.isBusy)
    await fixture.database.releaseOwner()
    await sync.value
    let requests = await fixture.network.requests
    XCTAssertFalse(requests.contains("/oauth2/token"))
    XCTAssertTrue(fixture.auth.isAuthenticated)
  }

  func testSignOutWhileRenewalWaitsCannotRestoreOldAccount() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.database.holdOwner()
    let sync = Task { await fixture.sync.synchronize() }
    try await waitForBusy(fixture.sync)
    let renewal = Task { try await fixture.sync.renew(rejectedAccessToken: "synthetic-access") }
    try await Task.sleep(for: .milliseconds(30))
    fixture.auth.signOut()
    await fixture.database.releaseOwner()
    await sync.value
    do { _ = try await renewal.value; XCTFail("Signed-out renewal succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertNil(fixture.auth.accessToken)
    let requests = await fixture.network.requests
    XCTAssertFalse(requests.contains("/oauth2/token"))
  }

  func testRenewalReusesTokenAdoptedByTheInFlightSync() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    let saved = await fixture.database.fetch(owner: "owner")
    var next = try fixture.credential()
    next.accessToken = "another-device-access"
    next.refreshToken = "another-device-refresh"
    _ = try await fixture.database.save(.init(owner: "owner", credential: next), replacing: saved)
    await fixture.database.holdOwner()
    let sync = Task { await fixture.sync.synchronize() }
    try await waitForBusy(fixture.sync)
    let renewal = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    try await Task.sleep(for: .milliseconds(30))
    await fixture.database.releaseOwner()
    await sync.value
    let token = try await renewal.value
    XCTAssertEqual(token, "another-device-access")
    let requests = await fixture.network.requests
    XCTAssertFalse(requests.contains("/oauth2/token"), "Do not spend the rotated token again after cloud adoption")
    XCTAssertNil(fixture.sync.errorMessage)
  }

  private func waitForBusy(_ sync: TwitchAccountSync) async throws {
    for _ in 0..<100 {
      if sync.isBusy { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Account update did not start")
  }
}

@MainActor
private final class Fixture {
  let prefix = "StrozzAutomaticSignInTests.\(UUID())"
  let defaults: UserDefaults
  let auth: TwitchAuthSession
  let sync: TwitchAccountSync
  let rewards: TwitchWatchRewardsSession
  let database = AutomaticSignInDatabase()
  let network = AutomaticSignInNetwork()

  init() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: prefix))
    let network = network
    auth = TwitchAuthSession(userDefaults: defaults, secureService: prefix + ".auth", saveTopShelf: { _ in },
      loadAuthData: { try await network.load($0) })
    sync = TwitchAccountSync(database: database, defaults: defaults, storagePrefix: prefix)
    rewards = TwitchWatchRewardsSession(store: .init(read: { nil }, write: { _ in }, remove: {}),
      preferences: defaults)
  }

  func credential() throws -> TwitchCredential {
    .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", userID: "fixture",
      clientID: try XCTUnwrap(auth.clientID), login: "fixture", displayName: "Fixture", cloudOwner: "owner")
  }

  func saveCloudAccount() async throws {
    let credential = try credential()
    await network.setClientID(credential.clientID)
    _ = try await database.save(.init(owner: "owner", credential: credential), replacing: nil)
  }

  func start() async {
    if let client = auth.clientID { await network.setClientID(client) }
    await sync.start(auth: auth, rewards: rewards)
  }

  func stop() {
    sync.stop()
    auth.cancelSignIn()
    auth.validationTask?.cancel()
    auth.refreshInFlight?.cancel()
    do {
      for suffix in [".auth", ".pending-token-publication", ".pending-rewards-change"] {
        try CredentialKeychain.remove(service: prefix + suffix)
      }
    } catch { XCTFail("Synthetic credential cleanup failed: \(error)") }
    defaults.removePersistentDomain(forName: prefix)
  }
}

private actor AutomaticSignInNetwork {
  private var client = ""
  private var refreshEnabled = false
  private(set) var requests: [String] = []
  func setClientID(_ value: String) { client = value }
  func enableRefresh() { refreshEnabled = true }
  func load(_ request: URLRequest) throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    requests.append(url.path)
    let body: [String: Any]
    let status: Int
    switch url.path {
    case "/oauth2/validate":
      body = ["client_id": client, "login": "fixture", "user_id": "fixture",
        "scopes": [], "expires_in": 3600]
      status = 200
    case "/oauth2/device":
      body = ["device_code": "synthetic-device", "user_code": "TEST-CODE",
        "verification_uri": "https://www.twitch.tv/activate", "expires_in": 600, "interval": 2]
      status = 200
    case "/oauth2/token":
      if refreshEnabled {
        body = ["access_token": "rotated-access", "refresh_token": "rotated-refresh",
          "token_type": "bearer", "expires_in": 3600]
        status = 200
      } else {
        body = ["error": "authorization_pending", "message": "authorization_pending"]
        status = 400
      }
    default:
      throw URLError(.unsupportedURL)
    }
    return (try JSONSerialization.data(withJSONObject: body),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
  }
}

private actor AutomaticSignInDatabase: TwitchCloudDatabase {
  private var snapshot: TwitchCloudSnapshot?
  private var unavailable = false
  private var hold = false
  private(set) var ownerRequests = 0
  func setUnavailable() { unavailable = true }
  func holdOwner() { hold = true }
  func releaseOwner() { hold = false }
  func owner() async throws -> String {
    ownerRequests += 1
    while hold { try await Task.sleep(for: .milliseconds(5)) }
    if unavailable { throw TwitchSyncError.unavailable }
    return "owner"
  }
  func fetch(owner: String) -> TwitchCloudSnapshot? { snapshot }
  func save(_ account: TwitchCloudAccount, replacing previous: TwitchCloudSnapshot?) throws -> TwitchCloudSnapshot {
    guard previous?.version == snapshot?.version else { throw TwitchSyncError.conflict }
    let next = TwitchCloudSnapshot(account: try account.validated(), version: Data(UUID().uuidString.utf8))
    snapshot = next
    return next
  }
}
