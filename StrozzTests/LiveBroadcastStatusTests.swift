import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class LiveBroadcastStatusTests: XCTestCase {
  func testOnlyExplicitBroadcastEventsChangeStatus() {
    var state = TwitchBroadcastState()
    for type in ["viewcount", "commercial", "reconnect", "timeout"] {
      XCTAssertFalse(state.receive(type: type, serverTime: nil))
      XCTAssertEqual(state.status, .unknown)
    }
    XCTAssertTrue(state.receive(type: "stream-down", serverTime: 100))
    XCTAssertEqual(state.status, .offline)
    XCTAssertTrue(state.receive(type: "stream-up", serverTime: 101))
    XCTAssertEqual(state.status, .live)
    XCTAssertFalse(state.receive(type: "stream-down", serverTime: 100))
    XCTAssertEqual(state.status, .live)
  }

  func testMalformedAndDuplicateTimestampsAreRejected() {
    var state = TwitchBroadcastState()
    for time in [Double.nan, .infinity, -.infinity, -1] {
      XCTAssertFalse(state.receive(type: "stream-down", serverTime: time))
    }
    XCTAssertEqual(state.status, .unknown)
    XCTAssertTrue(state.receive(type: "stream-down", serverTime: 100))
    let revision = state.revision
    XCTAssertFalse(state.receive(type: "stream-down", serverTime: 100))
    XCTAssertEqual(state.revision, revision)
  }

  func testDisconnectAndChannelReplacementDiscardOldEvidence() {
    var state = TwitchBroadcastState()
    state.receive(type: "stream-down", serverTime: 100)
    let old = state.revision
    state.reset()
    XCTAssertEqual(state.status, .unknown)
    XCTAssertFalse(state.acceptsStatusCheck(startedRevision: old, at: Date()))
    XCTAssertTrue(state.acceptsStatusCheck(startedRevision: state.revision, at: Date()))
    XCTAssertTrue(state.receive(type: "stream-up", serverTime: 1))
  }

  func testPushWinsOverStaleQueriesButFallbackStillDetectsMissedEvents() {
    var state = TwitchBroadcastState()
    let now = Date(timeIntervalSince1970: 100)
    let old = state.revision
    state.receive(type: "stream-down", serverTime: 100, at: now)
    XCTAssertFalse(state.acceptsStatusCheck(startedRevision: old, at: now.addingTimeInterval(60)))
    XCTAssertFalse(state.acceptsStatusCheck(startedRevision: state.revision, at: now.addingTimeInterval(9.99)))
    XCTAssertTrue(state.acceptsStatusCheck(startedRevision: state.revision, at: now.addingTimeInterval(10)))
    state.receive(type: "stream-up", serverTime: 101, at: now)
    XCTAssertTrue(state.acceptsStatusCheck(startedRevision: state.revision, at: now.addingTimeInterval(30)),
      "A missed stream-down must not leave stream-up authoritative forever")
  }

  func testTimestampIsOptionalForRecognizedEvents() {
    var state = TwitchBroadcastState()
    XCTAssertTrue(state.receive(type: "stream-down", serverTime: nil))
    XCTAssertEqual(state.status, .offline)
  }

  func testHealthyBufferAndRewoundPlaybackArePreserved() {
    for buffer in [0.0, 0.088, 0.15, 0.151, 3, 180] {
      XCTAssertFalse(present(buffer: buffer, stalled: false))
      XCTAssertFalse(present(buffer: buffer, atLiveEdge: false))
    }
    XCTAssertTrue(present(buffer: 0.088))
    XCTAssertTrue(present(buffer: 0.15))
    XCTAssertFalse(present(buffer: 0.151))
    XCTAssertFalse(present(buffer: nil))
    XCTAssertFalse(present(buffer: .nan))
    XCTAssertFalse(present(buffer: -1))
  }

  func testExplicitPauseOrLifecycleSuspensionWinsOverEveryEndSignal() {
    for hasItem in [true, false] {
      for terminal in [true, false] {
        for ended in [true, false] {
          XCTAssertFalse(BroadcastEndPolicy.shouldPresentOffline(
            playbackAllowed: false, hasItem: hasItem, terminalFailure: terminal,
            atLiveEdge: true, bufferAhead: 0, stalled: true, reachedEnd: ended))
        }
      }
    }
  }

  func testFailedAndMissingItemsCanShowOfflineWithoutAnotherRetry() {
    XCTAssertTrue(BroadcastEndPolicy.shouldPresentOffline(
      playbackAllowed: true, hasItem: false, terminalFailure: false,
      atLiveEdge: false, bufferAhead: nil, stalled: false, reachedEnd: false))
    XCTAssertTrue(BroadcastEndPolicy.shouldPresentOffline(
      playbackAllowed: true, hasItem: true, terminalFailure: true,
      atLiveEdge: false, bufferAhead: 2, stalled: false, reachedEnd: false))
    XCTAssertTrue(BroadcastEndPolicy.shouldPresentOffline(
      playbackAllowed: true, hasItem: true, terminalFailure: false,
      atLiveEdge: false, bufferAhead: 0, stalled: false, reachedEnd: true))
  }

  private func present(buffer: Double?, atLiveEdge: Bool = true, stalled: Bool = true) -> Bool {
    BroadcastEndPolicy.shouldPresentOffline(playbackAllowed: true, hasItem: true,
      terminalFailure: false, atLiveEdge: atLiveEdge, bufferAhead: buffer,
      stalled: stalled, reachedEnd: false)
  }
}
