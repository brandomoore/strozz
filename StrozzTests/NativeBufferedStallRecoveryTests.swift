import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeBufferedStallRecoveryTests: XCTestCase {
  func testRefilledBufferResumesOnceThenRequiresClockProgress() {
    var recovery = NativeBufferedStallRecovery()
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 0, buffer: 1.9, waiting: false, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 2, buffer: 0.09, waiting: true, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 4, buffer: 8, waiting: true, allowed: true), .resume)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 6, buffer: 13, waiting: true, allowed: true), .awaitingProgress)
    XCTAssertEqual(recovery.observe(clock: 11, uptime: 7, buffer: 12, waiting: false, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 11, uptime: 8, buffer: 3, waiting: true, allowed: true), .resume)
  }

  func testFailedResumeEscalatesOnceEvenIfPlayerClaimsToBePlaying() {
    var recovery = NativeBufferedStallRecovery()
    _ = recovery.observe(clock: 10, uptime: 0, buffer: 8, waiting: false, allowed: true)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 1, buffer: 8, waiting: true, allowed: true), .resume)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 5.99, buffer: 13, waiting: false, allowed: true), .awaitingProgress)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 6, buffer: 13, waiting: false, allowed: true), .restart)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 7, buffer: 13, waiting: false, allowed: true), .awaitingProgress)
  }

  func testPauseBackgroundAndSeekCancellationPreventResumeAndEscalation() {
    var recovery = NativeBufferedStallRecovery()
    _ = recovery.observe(clock: 10, uptime: 0, buffer: 8, waiting: false, allowed: true)
    _ = recovery.observe(clock: 10, uptime: 1, buffer: 8, waiting: true, allowed: true)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 7, buffer: 13, waiting: true, allowed: false), .none)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 8, buffer: 13, waiting: true, allowed: true), .none)
  }

  func testMissingOrInsufficientBufferCannotForcePlayback() {
    var recovery = NativeBufferedStallRecovery()
    _ = recovery.observe(clock: 10, uptime: 0, buffer: 8, waiting: false, allowed: true)
    for buffer in [nil, .nan, .infinity, -1, 0.09, 2.99] as [Double?] {
      XCTAssertEqual(recovery.observe(clock: 10, uptime: 1, buffer: buffer, waiting: true, allowed: true), .none)
    }
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 2, buffer: 5, minimumBuffer: 7.5,
      waiting: true, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 10, uptime: 3, buffer: 7.5, minimumBuffer: 7.5,
      waiting: true, allowed: true), .resume)
  }

  func testClockMovementAndInvalidTimingNeverLookLikeARefilledDeadlock() {
    var recovery = NativeBufferedStallRecovery()
    _ = recovery.observe(clock: 10, uptime: 0, buffer: 8, waiting: true, allowed: true)
    XCTAssertEqual(recovery.observe(clock: 11, uptime: 1, buffer: 8, waiting: true, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 5, uptime: 2, buffer: 8, waiting: true, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: .nan, uptime: 3, buffer: 8, waiting: true, allowed: true), .none)
    XCTAssertEqual(recovery.observe(clock: 5, uptime: .nan, buffer: 8, waiting: true, allowed: true), .none)
  }
}
