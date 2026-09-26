import XCTest

@testable import Strozz

final class AltSourceRecoveryStateTests: XCTestCase {
  func testTerminalFailureDoesNotDependOnItemStatusOrClock() {
    var state = AltSourceRecoveryState()
    state.noteTerminalFailure()
    XCTAssertTrue(state.needsRecovery(clock: 123, shouldPlay: true, now: 1))
  }

  func testRetryBudgetDoesNotResetWhenPlaybackBrieflyResumes() {
    var state = AltSourceRecoveryState()
    XCTAssertTrue(state.beginRetry())
    state.beginItem()
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 1))
    XCTAssertFalse(state.needsRecovery(clock: 2, shouldPlay: true, now: 2))
    state.noteTerminalFailure()
    XCTAssertTrue(state.needsRecovery(clock: 2, shouldPlay: true, now: 3))
    XCTAssertFalse(state.canRetry)
    XCTAssertFalse(state.beginRetry())
    XCTAssertEqual(state.retryCount, 1)
  }

  func testNewSelectionInvalidatesOldWorkAndResetsBudget() {
    var state = AltSourceRecoveryState()
    let oldGeneration = state.generation
    XCTAssertTrue(state.beginRetry())
    state = AltSourceRecoveryState()
    XCTAssertNotEqual(oldGeneration, state.generation)
    XCTAssertTrue(state.canRetry)
  }

  func testBriefBufferingDoesNotTriggerRecovery() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 0))
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 19))
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 20))
    XCTAssertFalse(state.needsRecovery(clock: 1, shouldPlay: true, now: 39))
    XCTAssertTrue(state.needsRecovery(clock: 1, shouldPlay: true, now: 40))
  }

  func testPauseScrubAndBackgroundTimeDoNotCountAsStalls() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 0))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: false, now: 100))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 200))
    XCTAssertFalse(state.needsRecovery(clock: 5, shouldPlay: true, now: 219))
    XCTAssertTrue(state.needsRecovery(clock: 5, shouldPlay: true, now: 220))
  }

  func testTerminalErrorWhilePausedIsRememberedUntilResume() {
    var state = AltSourceRecoveryState()
    state.noteTerminalFailure()
    XCTAssertFalse(state.needsRecovery(clock: 10, shouldPlay: false, now: 10))
    XCTAssertTrue(state.needsRecovery(clock: 10, shouldPlay: true, now: 30))
    state.beginItem()
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 31))
  }

  func testUnknownClockStillHasABoundedStartupDeadline() {
    var state = AltSourceRecoveryState()
    XCTAssertFalse(state.needsRecovery(clock: .nan, shouldPlay: true, now: 0))
    XCTAssertTrue(state.needsRecovery(clock: .nan, shouldPlay: true, now: 20))
  }

  func testFreshResolveRespectsCooldown() {
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 0), 10)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 3), 7)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 10), 0)
    XCTAssertEqual(AltSourceRecoveryState.retryDelay(sinceLastAttempt: 100), 0)
  }

  func testRepeatedBriefStallsTriggerRecoveryDespiteClockProgress() {
    var state = AltSourceRecoveryState()
    for now in [0.0, 8.0] {
      state.notePlaybackStall(now: now)
      XCTAssertFalse(state.needsRecovery(clock: now, shouldPlay: true, now: now))
    }
    state.notePlaybackStall(now: 20)
    XCTAssertTrue(state.hasRepeatedStalls(now: 20))
    XCTAssertTrue(state.needsRecovery(clock: 20, shouldPlay: true, now: 20))
  }

  func testIsolatedStallsDoNotIncreaseDelay() {
    var state = AltSourceRecoveryState()
    for now in [0.0, 20.0, 40.0, 60.0] {
      state.notePlaybackStall(now: now)
      XCTAssertFalse(state.hasRepeatedStalls(now: now))
      XCTAssertFalse(state.needsRecovery(clock: now, shouldPlay: true, now: now))
    }
  }

  func testDuplicateStallNotificationsDoNotExhaustRecovery() {
    var state = AltSourceRecoveryState()
    for now in [0.0, 0.2, 0.4] { state.notePlaybackStall(now: now) }
    XCTAssertFalse(state.hasRepeatedStalls(now: 0.4))
  }

  func testExpiredStallWindowDoesNotTriggerRecovery() {
    var state = AltSourceRecoveryState()
    for now in [0.0, 10.0, 20.0] { state.notePlaybackStall(now: now) }
    XCTAssertTrue(state.hasRepeatedStalls(now: 30))
    XCTAssertFalse(state.hasRepeatedStalls(now: 31))
  }

  func testIntentionalPauseClearsRepeatedStallWindow() {
    var state = AltSourceRecoveryState()
    state.notePlaybackStall(now: 0)
    state.notePlaybackStall(now: 5)
    XCTAssertFalse(state.needsRecovery(clock: 10, shouldPlay: false, now: 6))
    state.notePlaybackStall(now: 10)
    XCTAssertFalse(state.needsRecovery(clock: 10, shouldPlay: true, now: 10))
  }

  func testRepeatedStallsAfterFreshItemDoNotCreateUnlimitedRetries() {
    var state = AltSourceRecoveryState()
    for now in [0.0, 5.0, 10.0] { state.notePlaybackStall(now: now) }
    XCTAssertTrue(state.beginRetry())
    state.beginItem()
    XCTAssertFalse(state.hasRepeatedStalls(now: 11))
    XCTAssertFalse(state.needsRecovery(clock: 0, shouldPlay: true, now: 11))
    for now in [15.0, 20.0, 25.0] { state.notePlaybackStall(now: now) }
    XCTAssertTrue(state.needsRecovery(clock: 10, shouldPlay: true, now: 25))
    XCTAssertFalse(state.canRetry)
    XCTAssertFalse(state.beginRetry())
  }
}
