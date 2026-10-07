import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class TwitchAutomaticSignInTests: XCTestCase {
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
  private(set) var requests: [String] = []
  func setClientID(_ value: String) { client = value }
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
      body = ["error": "authorization_pending", "message": "authorization_pending"]
      status = 400
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
