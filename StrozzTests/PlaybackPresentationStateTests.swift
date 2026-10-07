import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class PlaybackPresentationStateTests: XCTestCase {
  func testLoadingAndWaitingForFirstVideoExcludeTransport() {
    XCTAssertEqual(PlaybackPresentationState(isLoading: true, isUnavailable: false), .loading)
    XCTAssertEqual(PlaybackPresentationState(isLoading: false, awaitingVideo: true, isUnavailable: false), .loading)
    XCTAssertEqual(PlaybackPresentationState(isLoading: false, isUnavailable: false), .ready)
  }

  func testErrorsReplaceLoadingRatherThanStackingOnIt() {
    for loading in [false, true] {
      for waiting in [false, true] {
        XCTAssertEqual(PlaybackPresentationState(
          isLoading: loading, awaitingVideo: waiting, isUnavailable: true), .unavailable)
      }
    }
  }

  func testNormalDeliveryLatencyIsNotExtraPlaybackDelay() {
    var baseline = LiveChatSyncBaseline()
    var position = LivePlaybackPosition()
    let now = Date(timeIntervalSince1970: 1000)
    let itemID = UUID()
    for second in 0..<7 {
      let time = Double(second)
      baseline.observe(context: "fixture", itemID: itemID,
        playbackDate: now.addingTimeInterval(time - 20.5), playbackTime: time,
        liveTarget: now.addingTimeInterval(time - 20), canCalibrate: true,
        now: now.addingTimeInterval(time), uptime: time)
      position.observe(extraDelay: baseline.extraDelay)
    }
    XCTAssertEqual(position.state, .live, "Twenty seconds of source delivery delay is not twenty seconds of extra lag")
  }

  func testLiveEdgeHysteresisAvoidsOfferingUnnecessaryJumps() {
    var position = LivePlaybackPosition()
    XCTAssertEqual(position.state, .checking)
    for delay in [0.0, 0.8, 1.6, 2.9] {
      position.observe(extraDelay: delay)
      XCTAssertEqual(position.state, .live)
    }
    position.observe(extraDelay: 5)
    XCTAssertEqual(position.state, .behind(seconds: 5))
    position.observe(extraDelay: 2)
    XCTAssertEqual(position.state, .behind(seconds: 2))
    position.observe(extraDelay: 1.5)
    XCTAssertEqual(position.state, .live)
    position.observe(extraDelay: 2.1)
    XCTAssertEqual(position.state, .live)
  }

  func testUnknownOrInvalidPositionIsNotClaimedToBeLive() {
    var position = LivePlaybackPosition()
    for delay in [Double?.none, .some(.nan), .some(.infinity)] {
      position.observe(extraDelay: delay)
      XCTAssertEqual(position.state, .checking)
    }
  }
}
