import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class FollowingRecoveryTests: XCTestCase {
  private func auth(loadData: @escaping NetworkClient.DataLoader = { _ in throw URLError(.unsupportedURL) }) -> TwitchAuthSession {
    let suite = "FollowingRecoveryTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suite)
      try CredentialKeychain.remove(service: suite)
    }
    let auth = TwitchAuthSession(userDefaults: defaults, secureService: suite, saveTopShelf: { _ in },
      loadAuthData: loadData)
    auth.isAuthenticated = true
    auth.userID = "viewer"
    auth.accessToken = "synthetic-access"
    return auth
  }

  func testTemporaryFailureKeepsFollowingAndDoesNotBecomeFreshTrending() async {
    let auth = auth()
    let loader = FollowingLoader()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    let channels = service.channels
    let updated = service.lastUpdatedAt
    XCTAssertFalse(service.needsRefresh(staleAfter: 300))
    XCTAssertEqual(channels.count, 1)
    XCTAssertEqual(service.followedLogins, ["followed"])
    XCTAssertEqual(service.followedCategories, ["Game": 1])
    loader.failurePath = "/helix/streams/followed"
    await service.refresh(using: auth)
    XCTAssertEqual(service.channels, channels)
    XCTAssertEqual(service.lastUpdatedAt, updated)
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertTrue(service.needsRefresh(staleAfter: 300), "Failure must not suppress recovery for five minutes")
    XCTAssertEqual(service.followedLogins, ["followed"])
    XCTAssertEqual(service.followedCategories, ["Game": 1])
    XCTAssertFalse(loader.paths.contains("/gql"))
    loader.failurePath = nil
    loader.title = "Refreshed"
    await service.refresh(using: auth)
    XCTAssertEqual(service.channels.first?.title, "Refreshed")
    XCTAssertNil(service.errorMessage)
    XCTAssertFalse(service.needsRefresh(staleAfter: 300))
  }

  func testFirstFailedFollowingLoadShowsAnErrorNotAnonymousContent() async {
    let auth = auth()
    let loader = FollowingLoader()
    loader.failurePath = "/helix/streams/followed"
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    XCTAssertTrue(service.channels.isEmpty)
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertFalse(service.isLoading)
    XCTAssertNil(service.lastUpdatedAt)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertEqual(loader.paths, ["/helix/streams/followed"])
  }

  func testRestoringKnownAccountRetainsFollowingWithoutFetchingTrending() async {
    let auth = auth()
    let loader = FollowingLoader()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    let channels = service.channels
    let requests = loader.paths.count
    auth.isAuthenticated = false
    await service.refresh(using: auth)
    XCTAssertEqual(loader.paths.count, requests)
    XCTAssertEqual(service.channels, channels)
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertNotNil(service.errorMessage)
  }

  func testAnonymousTrendingRequestCannotOverwriteRestoredFollowing() async throws {
    let auth = auth()
    auth.userID = nil
    auth.isAuthenticated = false
    auth.accessToken = nil
    let loader = FollowingLoader()
    loader.heldPath = "/gql"
    let started = expectation(description: "Anonymous request")
    loader.onHeld = { started.fulfill() }
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    let old = Task { await service.refresh(using: auth) }
    await fulfillment(of: [started], timeout: 2)
    auth.userID = "viewer"
    auth.isAuthenticated = true
    auth.accessToken = "synthetic-access"
    await service.refresh(using: auth)
    let following = service.channels
    loader.finish(0, json: #"{"data":{"streams":{"edges":[{"node":{"id":"demo","broadcaster":{"login":"trending"}}}]}}}"#)
    await old.value
    XCTAssertEqual(service.channels, following)
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertNil(service.errorMessage)
  }

  func testSupersededRequestCannotOverwriteOrFinishNewerRefresh() async {
    let auth = auth()
    let loader = FollowingLoader()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    loader.heldPath = "/helix/streams/followed"
    let first = expectation(description: "First refresh")
    loader.onHeld = { first.fulfill() }
    let old = Task { await service.refresh(using: auth) }
    await fulfillment(of: [first], timeout: 2)
    let second = expectation(description: "Second refresh")
    loader.onHeld = { second.fulfill() }
    let new = Task { await service.refresh(using: auth) }
    await fulfillment(of: [second], timeout: 2)
    loader.finish(0, json: FollowingLoader.streams("Stale"))
    await old.value
    XCTAssertEqual(service.channels.first?.title, "Original")
    XCTAssertTrue(service.isLoading)
    loader.finish(1, json: FollowingLoader.streams("Newest"))
    await new.value
    XCTAssertEqual(service.channels.first?.title, "Newest")
    XCTAssertFalse(service.isLoading)
  }

  func testCancelledRefreshCannotPublishSuccessOrFailure() async {
    for fail in [false, true] {
      let auth = auth()
      let loader = FollowingLoader()
      loader.heldPath = "/helix/streams/followed"
      let started = expectation(description: "Pending follows")
      loader.onHeld = { started.fulfill() }
      let service = FollowedChannelsService(loadData: { try await loader.load($0) })
      let request = Task { await service.refresh(using: auth) }
      await fulfillment(of: [started], timeout: 2)
      request.cancel()
      loader.finish(0, json: fail ? nil : FollowingLoader.streams("Cancelled"))
      await request.value
      XCTAssertTrue(service.channels.isEmpty)
      XCTAssertNil(service.lastUpdatedAt)
      XCTAssertNil(service.errorMessage)
      XCTAssertFalse(service.isLoading)
    }
  }

  func testAccountSwitchClearsCachedDirectoryAndRejectsOldResponses() async {
    let auth = auth()
    let loader = FollowingLoader()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    await service.loadDirectory(using: auth)
    XCTAssertEqual(service.directory.count, 1)
    loader.heldPath = "/helix/channels/followed"
    let started = expectation(description: "Old directory")
    loader.onHeld = { started.fulfill() }
    let old = Task { await service.loadDirectory(using: auth, force: true) }
    await fulfillment(of: [started], timeout: 2)
    auth.userID = "different"
    service.accountChanged(using: auth)
    XCTAssertTrue(service.directory.isEmpty)
    XCTAssertTrue(service.channels.isEmpty)
    XCTAssertTrue(service.followedCategories.isEmpty)
    XCTAssertTrue(service.followedLogins.isEmpty)
    loader.finish(0, json: FollowingLoader.follows)
    await old.value
    XCTAssertTrue(service.directory.isEmpty)
    XCTAssertNil(service.directoryLoadedAt)
    XCTAssertNil(service.directoryErrorMessage)
    XCTAssertFalse(service.isLoadingDirectory)
  }

  func testLateCategoryProfileCannotCrossAccountBoundary() async {
    let auth = auth()
    let loader = FollowingLoader()
    loader.heldPath = "/helix/channels"
    let started = expectation(description: "Old category profile")
    loader.onHeld = { started.fulfill() }
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    let old = Task { await service.refresh(using: auth) }
    await fulfillment(of: [started], timeout: 2)
    auth.userID = "different"
    service.accountChanged(using: auth)
    loader.finish(0, json: #"{"data":[{"broadcaster_id":"channel","game_name":"Old"}]}"#)
    await old.value
    XCTAssertTrue(service.followedCategories.isEmpty)
    XCTAssertTrue(service.followedLogins.isEmpty)
    XCTAssertTrue(service.channels.isEmpty)
  }

  func testEmptyFollowingIsSuccessfulAndSignedOutStillGetsTrending() async {
    let auth = auth()
    let loader = FollowingLoader()
    loader.title = nil
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    XCTAssertTrue(service.channels.isEmpty)
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertNotNil(service.lastUpdatedAt)
    XCTAssertNil(service.errorMessage)
    auth.isAuthenticated = false
    auth.userID = nil
    auth.accessToken = nil
    await service.refresh(using: auth)
    XCTAssertTrue(service.isUsingDemoData)
    XCTAssertEqual(service.channels.first?.login, "trending")
    XCTAssertTrue(service.directory.isEmpty)
    XCTAssertTrue(service.followedLogins.isEmpty)
  }
  func testUnauthorizedFollowRequestRefreshesOnceAndRetriesWithoutDemo() async throws {
    let loader = FollowingLoader()
    let auth = auth(loadData: { try await loader.load($0) })
    auth.refreshToken = "synthetic-refresh"
    loader.rejectedAccessToken = auth.accessToken
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.refresh(using: auth)
    XCTAssertEqual(service.channels.count, 1)
    XCTAssertEqual(auth.accessToken, "rotated-access")
    XCTAssertFalse(service.isUsingDemoData)
    XCTAssertNil(service.errorMessage)
    XCTAssertEqual(loader.paths.filter { $0 == "/oauth2/token" }.count, 1)
    XCTAssertEqual(loader.paths.filter { $0 == "/helix/streams/followed" }.count, 2)
    XCTAssertFalse(loader.paths.contains("/gql"))
  }

  func testFailureAndRetryKeepDirectoryUntilFreshDataArrives() async {
    let loader = FollowingLoader()
    let auth = auth()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    await service.loadDirectory(using: auth)
    let original = service.directory
    let updated = service.directoryLoadedAt
    loader.failurePath = "/helix/channels/followed"
    await service.loadDirectory(using: auth, force: true)
    XCTAssertEqual(service.directory, original)
    XCTAssertEqual(service.directoryLoadedAt, updated)
    XCTAssertNotNil(service.directoryErrorMessage)
    loader.failurePath = nil
    loader.title = "New directory"
    await service.loadDirectory(using: auth)
    XCTAssertEqual(service.directory.first?.title, "New directory")
    XCTAssertNil(service.directoryErrorMessage)
  }

  func testLateFailureCannotEraseNewerSuccess() async {
    let loader = FollowingLoader()
    let auth = auth()
    let service = FollowedChannelsService(loadData: { try await loader.load($0) })
    loader.heldPath = "/helix/streams/followed"
    let started = expectation(description: "Old refresh")
    loader.onHeld = { started.fulfill() }
    let old = Task { await service.refresh(using: auth) }
    await fulfillment(of: [started], timeout: 2)
    loader.heldPath = nil
    loader.title = "Newest"
    await service.refresh(using: auth)
    let updated = service.lastUpdatedAt
    loader.finish(0, json: nil)
    await old.value
    XCTAssertEqual(service.channels.first?.title, "Newest")
    XCTAssertEqual(service.lastUpdatedAt, updated)
    XCTAssertNil(service.errorMessage)
    XCTAssertFalse(service.isUsingDemoData)
  }
}

@MainActor
private final class FollowingLoader {
  var title: String? = "Original"
  var failurePath: String?
  var heldPath: String?
  var rejectedAccessToken: String?
  var onHeld: (() -> Void)?
  var paths: [String] = []
  private var nextID = 0
  private var pending: [Int: (URL, CheckedContinuation<(Data, URLResponse), Error>)] = [:]

  static let follows = #"{"data":[{"broadcaster_id":"channel","broadcaster_login":"followed"}]}"#
  static func streams(_ title: String) -> String {
    #"{"data":[{"user_id":"channel","user_login":"followed","user_name":"Followed","game_name":"Game","title":"\#(title)","viewer_count":1,"is_mature":false,"thumbnail_url":"","type":"live"}]}"#
  }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    paths.append(url.path)
    if url.path == heldPath {
      let id = nextID
      nextID += 1
      return try await withCheckedThrowingContinuation { continuation in
        pending[id] = (url, continuation)
        onHeld?()
      }
    }
    if url.path == failurePath { throw URLError(.notConnectedToInternet) }
    if url.path == "/helix/streams/followed", let rejectedAccessToken,
       request.value(forHTTPHeaderField: "Authorization") == "Bearer \(rejectedAccessToken)" {
      return (Data(#"{"error":"Unauthorized","status":401,"message":"Expired token"}"#.utf8),
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
    let json: String
    switch url.path {
    case "/helix/streams/followed", "/helix/streams": json = title.map(Self.streams) ?? #"{"data":[]}"#
    case "/helix/users": json = #"{"data":[{"id":"channel","login":"followed","display_name":"Followed"}]}"#
    case "/helix/channels/followed": json = Self.follows
    case "/helix/channels": json = #"{"data":[{"broadcaster_id":"channel","game_name":"Game"}]}"#
    case "/gql": json = #"{"data":{"streams":{"edges":[{"node":{"id":"demo","broadcaster":{"login":"trending"}}}]}}}"#
    case "/oauth2/token": json = #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","token_type":"bearer","expires_in":3600}"#
    default: throw URLError(.unsupportedURL)
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }

  func finish(_ id: Int, json: String?) {
    guard let (url, continuation) = pending.removeValue(forKey: id) else { XCTFail("Missing held request"); return }
    if let json {
      continuation.resume(returning: (Data(json.utf8),
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    } else {
      continuation.resume(throwing: URLError(.notConnectedToInternet))
    }
  }
}
