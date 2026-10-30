import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class TwitchRenewalExecutionTests: XCTestCase {
  func testInactiveAndUnprotectedRequestsNeverStartAnExchange() async {
    let fixture = Lifetime()
    fixture.active = false
    do {
      try await fixture.execution.run(onEvent: fixture.record) { XCTFail("Inactive operation started") }
      XCTFail("Inactive operation succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.begins, 0)
    XCTAssertEqual(fixture.events, [.deferred])

    fixture.active = true
    fixture.granted = false
    do {
      try await fixture.execution.run(onEvent: fixture.record) { XCTFail("Unprotected operation started") }
      XCTFail("Unprotected operation succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.begins, 1)
    XCTAssertEqual(fixture.ends, 0)
    XCTAssertEqual(fixture.events, [.deferred, .protectionUnavailable])
  }

  func testAlreadyCancelledCallerNeverAcquiresProtection() async {
    let fixture = Lifetime()
    let caller = Task {
      try await fixture.execution.run(onEvent: fixture.record) { XCTFail("Cancelled operation started") }
    }
    caller.cancel()
    do { try await caller.value; XCTFail("Cancelled caller succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.begins, 0)
  }

  func testExpirationDuringAdmissionCannotStartTheOperation() async {
    var ended = false
    let execution = TwitchRenewalExecution(isActive: { true }, beginProtection: { expire in
      expire()
      return { ended = true }
    })
    do {
      try await execution.run(onEvent: { XCTAssertEqual($0, .protectionExpired) }) {
        XCTFail("Expired operation started")
      }
      XCTFail("Expired admission succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(ended)
  }

  func testBackgroundingAndCallerCancellationDoNotDiscardAcceptedCredentials() async throws {
    let fixture = Lifetime()
    let started = expectation(description: "Exchange started")
    var response: CheckedContinuation<String, Never>?
    var journal: String?
    let caller = Task {
      try await fixture.execution.run(onEvent: fixture.record) {
        let accepted = await withCheckedContinuation { response = $0; started.fulfill() }
        try Task.checkCancellation()
        journal = accepted
        return accepted
      }
    }
    await fulfillment(of: [started], timeout: 2)
    fixture.active = false
    caller.cancel()
    XCTAssertEqual(fixture.ends, 0, "Protection lasts through the response and journal")
    response?.resume(returning: "synthetic-rotated-pair")
    let accepted = try await caller.value
    XCTAssertEqual(accepted, journal)
    XCTAssertEqual(fixture.begins, 1)
    XCTAssertEqual(fixture.ends, 1)
  }

  func testExpirationCancelsTheAdmittedNetworkWorkAndReleasesProtection() async {
    let fixture = Lifetime()
    let started = expectation(description: "Exchange started")
    let caller = Task {
      try await fixture.execution.run(onEvent: fixture.record) {
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        XCTFail("Expired exchange continued")
      }
    }
    await fulfillment(of: [started], timeout: 2)
    fixture.expire?()
    do { try await caller.value; XCTFail("Expired exchange succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(fixture.events, [.protectionExpired])
    XCTAssertEqual(fixture.ends, 1)
  }

  func testResponseAlreadyReceivedCanBeJournaledDespiteExpiration() async throws {
    let fixture = Lifetime()
    let started = expectation(description: "Exchange started")
    var response: CheckedContinuation<String, Never>?
    var journal: String?
    let caller = Task {
      try await fixture.execution.run(onEvent: fixture.record) {
        let accepted = await withCheckedContinuation { response = $0; started.fulfill() }
        journal = accepted
        try Task.checkCancellation()
      }
    }
    await fulfillment(of: [started], timeout: 2)
    fixture.expire?()
    response?.resume(returning: "synthetic-rotated-pair")
    do { try await caller.value; XCTFail("Expired caller succeeded") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(journal, "synthetic-rotated-pair")
    XCTAssertEqual(fixture.ends, 1)
  }

  func testFailureReleasesProtectionWithoutRetryingTheOperation() async {
    let fixture = Lifetime()
    var exchanges = 0
    do {
      try await fixture.execution.run(onEvent: fixture.record) {
        exchanges += 1
        throw URLError(.timedOut)
      }
      XCTFail("Timed-out exchange succeeded")
    } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    XCTAssertEqual(exchanges, 1)
    XCTAssertEqual(fixture.ends, 1)
  }
}

@MainActor
private final class Lifetime {
  var active = true
  var granted = true
  var begins = 0
  var ends = 0
  var expire: (@MainActor () -> Void)?
  var events: [TwitchRenewalExecution.Event] = []
  func record(_ event: TwitchRenewalExecution.Event) { events.append(event) }

  lazy var execution = TwitchRenewalExecution(isActive: { [unowned self] in active },
    beginProtection: { [unowned self] expiration in
      begins += 1
      guard granted else { return nil }
      expire = expiration
      return { [unowned self] in ends += 1; expire = nil }
    })
}
