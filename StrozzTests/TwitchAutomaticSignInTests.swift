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

  func testExpiredReservedConnectionOffersReapprovalWithoutSpendingOrClearingTheToken() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    let snapshot = try await fixture.requireCloudSnapshot()
    let id = UUID()
    _ = try await fixture.database.save(TwitchCloudRefresh.reserve(snapshot, id: id), replacing: snapshot)
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("An ambiguous reservation must not be reused")
    } catch { XCTAssertEqual(error as? TwitchSyncError, .refreshPending) }
    XCTAssertTrue(fixture.sync.needsRenewalSignIn)
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertNotNil(fixture.auth.storedCredential, "Keep the account and its credentials")
    XCTAssertFalse(fixture.sync.isSignedOutLocally, "Expiry is not an explicit local sign-out")
    let blocked = await fixture.cloudSnapshot()
    XCTAssertEqual(blocked?.account.refreshID, id)
    XCTAssertFalse(try XCTUnwrap(fixture.sync.errorMessage).contains("Another device"))

    await fixture.network.enableRefresh()
    await fixture.auth.beginDeviceCodeSignIn(useSavedConnection: false)
    for _ in 0..<200 {
      if fixture.auth.isAuthenticated && fixture.diagnostics.events.contains(where: { $0.stage == .freshSignInPublished }) {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(fixture.auth.isAuthenticated)
    let renewed = await fixture.cloudSnapshot()
    XCTAssertNil(renewed?.account.refreshID)
    XCTAssertEqual(renewed?.account.credential?.accessToken, "rotated-access")
    let exchanges = await fixture.network.refreshExchanges
    XCTAssertEqual(exchanges, 0, "Fresh device approval must never exchange the uncertain refresh token")
    XCTAssertFalse(fixture.sync.needsRenewalSignIn)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .reservationObservedWithoutJournal && $0.attempt == id })
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .freshSignInRequested })
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .freshSignInPublished })
  }

  func testDismissingAcceptedSignInDoesNotCancelItsCloudPublication() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    fixture.auth.isAuthenticated = false
    await fixture.network.enableRefresh()
    await fixture.database.holdNextSignInPublication()
    await fixture.auth.beginDeviceCodeSignIn(useSavedConnection: false)
    for _ in 0..<200 {
      if fixture.auth.isAuthenticated && fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertTrue(fixture.sync.isBusy)
    fixture.auth.cancelSignIn() // The sign-in view dismisses on authentication.
    await fixture.database.releaseSignInPublication()
    for _ in 0..<200 {
      if !fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let snapshot = await fixture.cloudSnapshot()
    XCTAssertEqual(snapshot?.account.credential?.accessToken, "rotated-access")
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .freshSignInPublished })
    XCTAssertNil(fixture.sync.errorMessage)
  }

  func testFailedExchangeRetainsReservationAndRecordsItsExactStageWithoutCredentials() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.network.failRefresh(.networkConnectionLost)
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("The synthetic exchange should fail")
    } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    let reserved = await fixture.cloudSnapshot()
    let id = try XCTUnwrap(reserved?.account.refreshID)
    XCTAssertEqual(reserved?.account.credential?.accessToken, "synthetic-access")
    let failure = try XCTUnwrap(fixture.diagnostics.events.last { $0.stage == .renewalFailed })
    XCTAssertEqual(failure.attempt, id)
    XCTAssertEqual(failure.failedStage, .exchangeRequested)
    XCTAssertEqual(failure.errorKind, "network")
    XCTAssertEqual(failure.errorCode, URLError.networkConnectionLost.rawValue)
    XCTAssertFalse(fixture.diagnostics.events.contains { $0.stage == .credentialsJournaled })
    let data = try String(contentsOf: fixture.diagnostics.file, encoding: .utf8)
    XCTAssertFalse(data.contains("synthetic-access"))
    XCTAssertFalse(data.contains("synthetic-refresh"))
    XCTAssertFalse(data.contains("fixture"))
  }

  func testAcceptedPublicationCannotRestoreAnExplicitLocalSignOut() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    fixture.auth.isAuthenticated = false
    await fixture.network.enableRefresh()
    await fixture.database.holdNextSignInPublication()
    await fixture.auth.beginDeviceCodeSignIn(useSavedConnection: false)
    for _ in 0..<200 {
      if fixture.auth.isAuthenticated && fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(fixture.sync.isBusy)
    fixture.auth.signOut()
    await fixture.database.releaseSignInPublication()
    for _ in 0..<200 {
      if !fixture.sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(fixture.sync.isSignedOutLocally)
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertNil(fixture.auth.storedCredential)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .signInPublicationFailed && $0.errorKind == "cancelled" })
  }

  func testPublicationFailureResumesJournalAfterRestartWithoutAnotherTokenExchange() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.network.enableRefresh()
    await fixture.database.failNextPublication()
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("The synthetic publication should fail")
    } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    let failure = try XCTUnwrap(fixture.diagnostics.events.last { $0.stage == .renewalFailed })
    XCTAssertEqual(failure.failedStage, .publicationRequested)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .credentialsJournaled })
    fixture.sync.stop()
    let restartedDiagnostics = TwitchCloudRenewalDiagnostics(directory: fixture.diagnosticDirectory)
    let restarted = TwitchAccountSync(database: fixture.database, defaults: fixture.defaults,
      storagePrefix: fixture.prefix, renewalDiagnostics: restartedDiagnostics)
    defer { restarted.stop() }
    await restarted.start(auth: fixture.auth, rewards: fixture.rewards)
    let recovered = await fixture.cloudSnapshot()
    XCTAssertNil(recovered?.account.refreshID)
    XCTAssertEqual(recovered?.account.credential?.accessToken, "rotated-access")
    XCTAssertTrue(fixture.auth.isAuthenticated)
    let exchanges = await fixture.network.refreshExchanges
    XCTAssertEqual(exchanges, 1)
    XCTAssertTrue(restartedDiagnostics.events.contains { $0.stage == .renewalFailed })
    XCTAssertTrue(restartedDiagnostics.events.contains { $0.stage == .pendingPublicationCompleted })
    XCTAssertEqual(Set(restartedDiagnostics.events.map(\.process)).count, 2)
  }

  func testLostReservationSaveResponseDoesNotExchangeAndIsDistinguishableFromExchangeFailure() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.database.loseNextReservationResponse()
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("The synthetic response should be lost")
    } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    let saved = await fixture.cloudSnapshot()
    XCTAssertNotNil(saved?.account.refreshID)
    let failure = try XCTUnwrap(fixture.diagnostics.events.last { $0.stage == .renewalFailed })
    XCTAssertEqual(failure.failedStage, .reservationRequested)
    let exchanges = await fixture.network.refreshExchanges
    XCTAssertEqual(exchanges, 0)
    XCTAssertFalse(fixture.diagnostics.events.contains { $0.stage == .exchangeRequested })
  }

  func testRenewalDiagnosticsAreBoundedPersistentAndExcludeArbitraryErrorDetails() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let secret = "private-access-token-owner-device-url"
    let error = NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret])
    fixture.diagnostics.record(.syncFailed, error: error)
    let stored = try String(contentsOf: fixture.diagnostics.file, encoding: .utf8)
    XCTAssertFalse(stored.contains(secret))
    XCTAssertTrue(stored.contains("other"))
    fixture.diagnostics.record(.renewalFailed,
      error: TwitchAuthHTTPError(context: secret, status: 400, message: "Invalid refresh token"))
    XCTAssertEqual(fixture.diagnostics.events.last?.oauthReason, "invalid_refresh")
    fixture.diagnostics.record(.renewalFailed,
      error: TwitchAuthHTTPError(context: secret, status: 400, message: secret))
    XCTAssertNil(fixture.diagnostics.events.last?.oauthReason)
    XCTAssertFalse(try String(contentsOf: fixture.diagnostics.file, encoding: .utf8).contains(secret))
    for _ in 0..<TwitchCloudRenewalDiagnostics.capacity + 3 {
      fixture.diagnostics.record(.reservationRequested, attempt: UUID())
    }
    let restarted = TwitchCloudRenewalDiagnostics(directory: fixture.diagnosticDirectory)
    XCTAssertEqual(restarted.events.count, TwitchCloudRenewalDiagnostics.capacity)
    XCTAssertEqual(Set(restarted.events.map(\.process)).count, 2)
    XCTAssertLessThan(try Data(contentsOf: restarted.file).count, 256 * 1024)
  }

  func testDefaultRenewalDiagnosticsUsePlatformSupportedStorage() throws {
    #if os(tvOS)
    let root = URL.cachesDirectory
    #else
    let root = URL.applicationSupportDirectory
    #endif
    XCTAssertEqual(TwitchCloudRenewalDiagnostics.directory,
      root.appendingPathComponent("AccountDiagnostics", isDirectory: true))
    let directory = TwitchCloudRenewalDiagnostics.directory
      .appendingPathComponent("StorageProbe-\(UUID())", isDirectory: true)
    defer {
      do { try FileManager.default.removeItem(at: directory) }
      catch { XCTFail("Cannot remove owned diagnostic storage probe: \(error)") }
    }
    let diagnostics = TwitchCloudRenewalDiagnostics(directory: directory)
    let stored = try JSONDecoder().decode([TwitchCloudRenewalDiagnostics.Event].self,
      from: Data(contentsOf: diagnostics.file))
    XCTAssertEqual(stored.last?.stage, .processStarted)
  }

  func testRepeatedBlockedSyncDoesNotFillTheDiagnosticHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    let snapshot = try await fixture.requireCloudSnapshot()
    _ = try await fixture.database.save(TwitchCloudRefresh.reserve(snapshot, id: UUID()), replacing: snapshot)
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    for _ in 0..<10 { await fixture.sync.synchronize() }
    XCTAssertEqual(fixture.diagnostics.events.filter { $0.stage == .reservationObservedWithoutJournal }.count, 1)
    XCTAssertEqual(fixture.diagnostics.events.filter { $0.stage == .syncFailed }.count, 1)
    XCTAssertTrue(fixture.auth.isAuthenticated, "A reservation alone must not invalidate a still-valid access token")
  }

  func testBackgroundStartupDefersAccountWorkUntilForeground() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    fixture.lifetime.active = false
    await fixture.start()
    XCTAssertFalse(fixture.sync.hasCompletedInitialSync)
    XCTAssertTrue(fixture.sync.isRestoringAccount)
    let backgroundOwners = await fixture.database.ownerRequests
    XCTAssertEqual(backgroundOwners, 0)
    let backgroundRequests = await fixture.network.requests
    XCTAssertTrue(backgroundRequests.isEmpty)

    fixture.lifetime.active = true
    await fixture.sync.applicationDidBecomeActive()
    XCTAssertTrue(fixture.sync.hasCompletedInitialSync)
    XCTAssertTrue(fixture.auth.isAuthenticated)
    XCTAssertEqual(fixture.auth.validationTask?.isCancelled, false)
    let foregroundOwners = await fixture.database.ownerRequests
    XCTAssertEqual(foregroundOwners, 1)
  }

  func testBackgroundSyncValidationAndUnauthorizedRecoveryDoNotRenew() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    fixture.lifetime.active = false
    let before = await fixture.network.requests
    let owners = await fixture.database.ownerRequests
    await fixture.sync.synchronize()
    await fixture.auth.validateSessionIfNeeded(force: true)
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("Background renewal was admitted")
    } catch { XCTAssertTrue(error is CancellationError) }
    let after = await fixture.network.requests
    let afterOwners = await fixture.database.ownerRequests
    XCTAssertEqual(before, after)
    XCTAssertEqual(owners, afterOwners)
    XCTAssertNil(fixture.sync.errorMessage)
    let snapshot = await fixture.cloudSnapshot()
    XCTAssertNil(snapshot?.account.refreshID)
  }

  func testBackgroundTransitionDuringPreflightCannotReserveAToken() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    await fixture.database.holdOwner()
    let renewal = Task { try await fixture.sync.renew(rejectedAccessToken: "synthetic-access") }
    try await waitForBusy(fixture.sync)
    fixture.lifetime.active = false
    await fixture.database.releaseOwner()
    do { _ = try await renewal.value; XCTFail("Background renewal was admitted") }
    catch { XCTAssertTrue(error is CancellationError) }
    let snapshot = await fixture.cloudSnapshot()
    XCTAssertNil(snapshot?.account.refreshID)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .renewalDeferred })
    XCTAssertFalse(fixture.diagnostics.events.contains { $0.stage == .reservationRequested })
  }

  func testBackgroundingAndCancellingReservationCallerStillPublishesAcceptedPair() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    await fixture.network.enableRefresh()
    await fixture.database.holdNextReservationResponse()
    let renewal = Task { try await fixture.sync.renew(rejectedAccessToken: "synthetic-access") }
    for _ in 0..<200 {
      if await fixture.cloudSnapshot()?.account.refreshID != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let reserved = await fixture.cloudSnapshot()
    XCTAssertNotNil(reserved?.account.refreshID)
    XCTAssertEqual(fixture.lifetime.begins, 1)
    XCTAssertEqual(fixture.lifetime.ends, 0)
    fixture.lifetime.active = false
    renewal.cancel()
    await fixture.database.releaseReservationResponse()
    do { _ = try await renewal.value; XCTFail("Cancelled caller installed credentials") }
    catch { XCTAssertTrue(error is CancellationError) }
    let published = await fixture.cloudSnapshot()
    XCTAssertNil(published?.account.refreshID)
    XCTAssertEqual(published?.account.credential?.accessToken, "rotated-access")
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .credentialsJournaled })
    XCTAssertEqual(fixture.lifetime.ends, 1)
    fixture.lifetime.active = true
    await fixture.sync.applicationDidBecomeActive()
    XCTAssertEqual(fixture.auth.accessToken, "rotated-access")
    let exchanges = await fixture.network.refreshExchanges
    XCTAssertEqual(exchanges, 1)
  }

  func testExpiringProtectionDuringExchangeDoesNotRetryAmbiguousToken() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    await fixture.network.holdRefresh()
    let renewal = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    for _ in 0..<200 {
      if await fixture.network.refreshExchanges == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    fixture.lifetime.expire?()
    do { _ = try await renewal.value; XCTFail("Expired renewal succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    let reserved = await fixture.cloudSnapshot()
    XCTAssertNotNil(reserved?.account.refreshID)
    do {
      _ = try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access")
      XCTFail("Ambiguous refresh token was retried")
    } catch { XCTAssertEqual(error as? TwitchSyncError, .refreshPending) }
    let exchanges = await fixture.network.refreshExchanges
    XCTAssertEqual(exchanges, 1)
    XCTAssertEqual(fixture.lifetime.ends, fixture.lifetime.begins)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .renewalProtectionExpired })
  }

  func testSignOutDuringProtectedExchangeCannotRestoreLocalAccount() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    await fixture.network.enableRefresh()
    await fixture.network.holdRefresh()
    let renewal = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    for _ in 0..<200 {
      if await fixture.network.refreshExchanges == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    fixture.auth.signOut()
    await fixture.network.releaseRefresh()
    do { _ = try await renewal.value; XCTFail("Signed-out account was restored") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(fixture.auth.isAuthenticated)
    XCTAssertNil(fixture.auth.storedCredential)
    XCTAssertTrue(fixture.sync.isSignedOutLocally)
    XCTAssertTrue(fixture.diagnostics.events.contains { $0.stage == .credentialsJournaled })
    let published = await fixture.cloudSnapshot()
    XCTAssertNil(published?.account.refreshID, "Other devices keep the accepted pair after a local sign-out")
  }

  func testCredentialExchangeSessionIsSingleShotAndDoesNotWaitForConnectivity() {
    let configuration = NetworkClient.credentialExchange.configuration
    XCTAssertFalse(configuration.waitsForConnectivity)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 20)
  }

  func testChangingCloudAccountDuringExchangeCannotPublishIntoNewAccount() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try await fixture.saveCloudAccount()
    await fixture.start()
    fixture.auth.validationTask?.cancel()
    await fixture.auth.validationTask?.value
    await fixture.network.enableRefresh()
    await fixture.network.holdRefresh()
    let renewal = Task { try await fixture.auth.recoverAccessToken(afterUnauthorized: "synthetic-access") }
    for _ in 0..<200 {
      if await fixture.network.refreshExchanges == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let reserved = try await fixture.requireCloudSnapshot()
    var replacement = try fixture.credential()
    replacement.userID = "replacement-user"
    replacement.accessToken = "replacement-access"
    replacement.refreshToken = "replacement-refresh"
    _ = try await fixture.database.save(.init(owner: "owner", credential: replacement), replacing: reserved)
    fixture.auth.clearStoredAuthState()
    try fixture.auth.useCredential(replacement)
    await fixture.network.releaseRefresh()
    do { _ = try await renewal.value; XCTFail("Superseded renewal succeeded") }
    catch { XCTAssertEqual(error as? TwitchSyncError, .conflict) }
    let current = try await fixture.requireCloudSnapshot()
    XCTAssertEqual(current.account.credential, replacement)
    XCTAssertEqual(fixture.auth.storedCredential, replacement)
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
  let diagnostics: TwitchCloudRenewalDiagnostics
  let diagnosticDirectory: URL
  let database = AutomaticSignInDatabase()
  let network = AutomaticSignInNetwork()
  let lifetime = RenewalLifetime()

  init() throws {
    defaults = try XCTUnwrap(UserDefaults(suiteName: prefix))
    let network = network
    auth = TwitchAuthSession(userDefaults: defaults, secureService: prefix + ".auth", saveTopShelf: { _ in },
      loadAuthData: { try await network.load($0) }, renewalExecution: lifetime.execution)
    diagnosticDirectory = URL.temporaryDirectory.appendingPathComponent(prefix, isDirectory: true)
    diagnostics = TwitchCloudRenewalDiagnostics(directory: diagnosticDirectory)
    sync = TwitchAccountSync(database: database, defaults: defaults, storagePrefix: prefix,
      renewalDiagnostics: diagnostics)
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

  func cloudSnapshot() async -> TwitchCloudSnapshot? { await database.fetch(owner: "owner") }

  func requireCloudSnapshot() async throws -> TwitchCloudSnapshot {
    let snapshot = await cloudSnapshot()
    return try XCTUnwrap(snapshot)
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
    do { try FileManager.default.removeItem(at: diagnosticDirectory) }
    catch { XCTFail("Synthetic diagnostic cleanup failed: \(error)") }
  }
}

private actor AutomaticSignInNetwork {
  private var client = ""
  private var refreshEnabled = false
  private var refreshFailure: URLError.Code?
  private var holdingRefresh = false
  private(set) var refreshExchanges = 0
  private(set) var requests: [String] = []
  func setClientID(_ value: String) { client = value }
  func enableRefresh() { refreshEnabled = true }
  func failRefresh(_ code: URLError.Code) { refreshFailure = code }
  func holdRefresh() { holdingRefresh = true }
  func releaseRefresh() { holdingRefresh = false }
  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
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
      if String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("grant_type=refresh_token") == true {
        refreshExchanges += 1
        while holdingRefresh { try await Task.sleep(for: .milliseconds(5)) }
        if let refreshFailure { throw URLError(refreshFailure) }
      }
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
  private var publicationFailure = false
  private var lostReservationResponse = false
  private var holdSignInPublication = false
  private var holdReservationResponse = false
  private(set) var ownerRequests = 0
  func setUnavailable() { unavailable = true }
  func holdOwner() { hold = true }
  func releaseOwner() { hold = false }
  func failNextPublication() { publicationFailure = true }
  func loseNextReservationResponse() { lostReservationResponse = true }
  func holdNextSignInPublication() { holdSignInPublication = true }
  func releaseSignInPublication() { holdSignInPublication = false }
  func holdNextReservationResponse() { holdReservationResponse = true }
  func releaseReservationResponse() { holdReservationResponse = false }
  func owner() async throws -> String {
    ownerRequests += 1
    while hold { try await Task.sleep(for: .milliseconds(5)) }
    if unavailable { throw TwitchSyncError.unavailable }
    return "owner"
  }
  func fetch(owner: String) -> TwitchCloudSnapshot? { snapshot }
  func save(_ account: TwitchCloudAccount, replacing previous: TwitchCloudSnapshot?) async throws -> TwitchCloudSnapshot {
    if account.refreshID == nil {
      while holdSignInPublication { try await Task.sleep(for: .milliseconds(5)) }
      try Task.checkCancellation()
    }
    guard previous?.version == snapshot?.version else { throw TwitchSyncError.conflict }
    if publicationFailure, account.refreshID == nil, previous?.account.refreshID != nil {
      publicationFailure = false
      throw URLError(.notConnectedToInternet)
    }
    let next = TwitchCloudSnapshot(account: try account.validated(), version: Data(UUID().uuidString.utf8))
    snapshot = next
    if account.refreshID != nil {
      while holdReservationResponse { try await Task.sleep(for: .milliseconds(5)) }
    }
    if lostReservationResponse, account.refreshID != nil {
      lostReservationResponse = false
      throw URLError(.networkConnectionLost)
    }
    return next
  }
}

@MainActor
private final class RenewalLifetime {
  var active = true
  var begins = 0
  var ends = 0
  var expire: (@MainActor () -> Void)?
  lazy var execution = TwitchRenewalExecution(isActive: { [unowned self] in active },
    beginProtection: { [unowned self] expiration in
      begins += 1
      expire = expiration
      return { [unowned self] in ends += 1; expire = nil }
    })
}
