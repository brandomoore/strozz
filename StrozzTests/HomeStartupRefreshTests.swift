import XCTest
@testable import Strozz

@MainActor
final class HomeStartupRefreshTests: XCTestCase {
  private func auth() -> TwitchAuthSession {
    let suite = "HomeStartupRefreshTests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return TwitchAuthSession(userDefaults: defaults, secureService: suite, saveTopShelf: { _ in },
      loadAuthData: { _ in throw URLError(.unsupportedURL) })
  }

  func testRestorationEventsProduceOneLoadForTheFinalAccount() async {
    let auth = auth()
    let coordinator = HomeRefreshCoordinator()
    var restores = 0
    var loads: [HomeAccountIdentity] = []
    await coordinator.start(account: { HomeAccountIdentity(auth) }, restore: {
      restores += 1
      auth.userID = "viewer"
      await coordinator.accountChanged { XCTFail("User-ID restoration must not fetch Home") }
      auth.isAuthenticated = true
      await coordinator.accountChanged { XCTFail("Authentication restoration must not fetch Home") }
      auth.isAuthenticated = false
      await coordinator.accountChanged { XCTFail("Cloud ownership checking must not fetch Home") }
      auth.isAuthenticated = true
      await coordinator.accountChanged { XCTFail("Cloud restoration must not fetch Home") }
    }, load: {
      await coordinator.accountChanged { XCTFail("Restoration events must not queue behind the first load") }
      await coordinator.refresh { loads.append(HomeAccountIdentity(auth)) }
    })
    XCTAssertEqual(restores, 1)
    XCTAssertEqual(loads, [HomeAccountIdentity(auth)])
    XCTAssertTrue(coordinator.hasCompletedInitialLoad)
    await coordinator.start(account: { HomeAccountIdentity(auth) },
      restore: { XCTFail("A remounted Home must not restore twice") },
      load: { XCTFail("A remounted Home must not force a startup refresh") })
  }

  func testConcurrentStartupJoinsTheExistingRestoration() async {
    let auth = auth()
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeStartupGate()
    let restoring = expectation(description: "Restoration started")
    var loads = 0
    let first = Task {
      await coordinator.start(account: { HomeAccountIdentity(auth) }, restore: {
        restoring.fulfill()
        await gate.wait()
      }, load: { loads += 1 })
    }
    await fulfillment(of: [restoring], timeout: 2)
    let second = Task {
      await coordinator.start(account: { HomeAccountIdentity(auth) },
        restore: { XCTFail("Startup restoration must be shared") },
        load: { XCTFail("Startup loading must be shared") })
    }
    await Task.yield()
    gate.release()
    await first.value
    await second.value
    XCTAssertEqual(loads, 1)
    XCTAssertTrue(coordinator.hasCompletedInitialLoad)
  }

  func testAccountSwitchDuringInitialFetchGetsOneAdditionalCurrentPass() async {
    let auth = auth()
    auth.userID = "first"
    auth.isAuthenticated = true
    let coordinator = HomeRefreshCoordinator()
    var accounts: [String?] = []
    await coordinator.start(account: { HomeAccountIdentity(auth) }, restore: {}, load: {
      accounts.append(auth.userID)
      if accounts.count == 1 {
        auth.userID = "second"
        await coordinator.accountChanged { XCTFail("Startup owns an account switch during loading") }
      }
    })
    XCTAssertEqual(accounts, ["first", "second"])
    XCTAssertTrue(coordinator.hasCompletedInitialLoad)
    auth.isAuthenticated = false
    await coordinator.accountChanged { accounts.append(auth.userID) }
    XCTAssertEqual(accounts.count, 3, "Later account changes must still force fresh Home data")
  }

  func testTokenRotationDoesNotChangeTheAccountRefreshIdentity() {
    let auth = auth()
    auth.userID = "viewer"
    auth.isAuthenticated = true
    auth.accessToken = "synthetic-original"
    let before = HomeAccountIdentity(auth)
    auth.accessToken = "synthetic-rotated"
    XCTAssertEqual(before, HomeAccountIdentity(auth))
    auth.userID = "another"
    XCTAssertNotEqual(before, HomeAccountIdentity(auth))
  }

  func testManualRefreshesRemainSerializedInsteadOfDropped() async {
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeStartupGate()
    let started = expectation(description: "First refresh started")
    var events: [String] = []
    let first = Task {
      await coordinator.refresh {
        events.append("first-start")
        started.fulfill()
        await gate.wait()
        events.append("first-end")
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let second = Task { await coordinator.refresh { events.append("second") } }
    await Task.yield()
    XCTAssertEqual(events, ["first-start"])
    gate.release()
    await first.value
    await second.value
    XCTAssertEqual(events, ["first-start", "first-end", "second"])
  }

  func testCancelledStartupCanBeRetriedAndDoesNotPublishCompletion() async {
    let auth = auth()
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeStartupGate()
    let restoring = expectation(description: "Held startup")
    let first = Task {
      await coordinator.start(account: { HomeAccountIdentity(auth) }, restore: {
        restoring.fulfill()
        await gate.wait()
      }, load: { XCTFail("Cancelled startup must not fetch") })
    }
    await fulfillment(of: [restoring], timeout: 2)
    first.cancel()
    gate.release()
    await first.value
    XCTAssertFalse(coordinator.hasCompletedInitialLoad)
    var loads = 0
    await coordinator.start(account: { HomeAccountIdentity(auth) }, restore: {}, load: { loads += 1 })
    XCTAssertEqual(loads, 1)
    XCTAssertTrue(coordinator.hasCompletedInitialLoad)
  }

  func testCancellingTheCallerCancelsItsActiveRefreshAndUnblocksTheNextOne() async {
    let coordinator = HomeRefreshCoordinator()
    let gate = HomeStartupGate()
    let loading = expectation(description: "Refresh started")
    var observedCancellation = false
    let first = Task {
      await coordinator.refresh {
        loading.fulfill()
        await gate.wait()
        observedCancellation = Task.isCancelled
      }
    }
    await fulfillment(of: [loading], timeout: 2)
    first.cancel()
    gate.release()
    await first.value
    XCTAssertTrue(observedCancellation)
    var followUp = false
    await coordinator.refresh { followUp = true }
    XCTAssertTrue(followUp)
  }
}

@MainActor
private final class HomeStartupGate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}
