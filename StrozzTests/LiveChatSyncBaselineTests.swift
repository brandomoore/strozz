import XCTest
@testable import Strozz

final class LiveChatSyncBaselineTests: XCTestCase {
  private let item = UUID()
  private let epoch = Date(timeIntervalSince1970: 1000)

  private func observe(_ state: inout LiveChatSyncBaseline, time: Double, delay: Double,
                       nativeAge: Double? = nil, healthy: Bool = true, context: String = "channel/twitch",
                       itemID: UUID? = nil) {
    state.observe(context: context, itemID: itemID ?? item,
      playbackDate: epoch.addingTimeInterval(time - delay), playbackTime: time - delay,
      liveTarget: nativeAge.map { epoch.addingTimeInterval(time - $0) }, canCalibrate: healthy,
      now: epoch.addingTimeInterval(time), uptime: time)
  }

  private func calibrate(_ state: inout LiveChatSyncBaseline, delay: Double = 3,
                         nativeAge: Double? = nil) {
    for t in 0...6 { observe(&state, time: Double(t), delay: delay, nativeAge: nativeAge) }
  }

  func testNormalThreeSecondPlaybackDoesNotDelayChat() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    XCTAssertEqual(state.normalDelay, 3)
    XCTAssertEqual(state.extraDelay, 0)
    XCTAssertEqual(state.reference, .calibratedLive)
  }

  func testOnlyExcessDelayIsHeldAndCatchUpClearsIt() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    observe(&state, time: 11, delay: 8, healthy: false)
    XCTAssertEqual(state.extraDelay, 5)
    observe(&state, time: 26, delay: 23, healthy: false)
    XCTAssertEqual(state.extraDelay, 20)
    observe(&state, time: 27, delay: 3, healthy: false)
    XCTAssertEqual(state.extraDelay, 0)
    XCTAssertEqual(state.normalDelay, 3)
  }

  func testStableButSlowerRecoveryDoesNotRaiseBaseline() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    for t in 30...50 { observe(&state, time: Double(t), delay: 25) }
    XCTAssertEqual(state.normalDelay, 3)
    XCTAssertEqual(state.extraDelay, 22)
  }

  func testUnknownNormalStaysUnknownDuringStallsRewindAndDeepBuffering() {
    var state = LiveChatSyncBaseline()
    for t in 0...60 { observe(&state, time: Double(t), delay: 25, healthy: false) }
    XCTAssertNil(state.normalDelay)
    XCTAssertNil(state.extraDelay)
    XCTAssertEqual(state.reference, .unavailable)
  }

  func testNativeUsesSourceTimelineWithoutNeedingAUniversalBaseline() {
    var state = LiveChatSyncBaseline()
    observe(&state, time: 0, delay: 3, nativeAge: 3)
    XCTAssertEqual(state.extraDelay, 0)
    observe(&state, time: 5, delay: 8, nativeAge: 3, healthy: false)
    XCTAssertEqual(state.extraDelay, 5)
    XCTAssertEqual(state.reference, .nativeLiveTarget)
  }

  func testNativeLearnsSmallStablePlaybackCushionThenFreezesIt() {
    var state = LiveChatSyncBaseline()
    calibrate(&state, delay: 3, nativeAge: 2)
    XCTAssertEqual(state.nativeCushion, 1)
    XCTAssertEqual(state.extraDelay, 0)
    observe(&state, time: 11, delay: 8, nativeAge: 2, healthy: false)
    XCTAssertEqual(state.extraDelay, 5)
    for t in 30...50 { observe(&state, time: Double(t), delay: 25, nativeAge: 2) }
    XCTAssertEqual(state.nativeCushion, 1)
    XCTAssertEqual(state.extraDelay, 22)
  }

  func testClockSkewCancelsInNativeComparison() {
    var state = LiveChatSyncBaseline()
    observe(&state, time: 0, delay: -17, nativeAge: -17)
    XCTAssertEqual(state.extraDelay, 0)
    observe(&state, time: 5, delay: -12, nativeAge: -17, healthy: false)
    XCTAssertEqual(state.extraDelay, 5)
  }

  func testSubThresholdJitterDoesNotHoldChat() {
    var state = LiveChatSyncBaseline()
    observe(&state, time: 0, delay: 3.4, nativeAge: 3, healthy: false)
    XCTAssertEqual(state.extraDelay, 0)
    observe(&state, time: 1, delay: 2.8, nativeAge: 3, healthy: false)
    XCTAssertEqual(state.extraDelay, 0)
  }

  func testStableNativeCushionWithSegmentJitterLearnsWithoutAHardcodedNormalDelay() {
    var state = LiveChatSyncBaseline()
    let sourceAges = [8.5, 8.7, 8.6, 8.8, 8.5, 8.7, 8.6, 8.5, 8.8, 8.6]
    for (time, sourceAge) in sourceAges.enumerated() {
      observe(&state, time: Double(time), delay: 9.75, nativeAge: sourceAge)
    }
    XCTAssertEqual(state.normalDelay, 9.75)
    XCTAssertEqual(state.extraDelay, 0)
    XCTAssertNotNil(state.nativeCushion)
    let cushion = state.nativeCushion!
    observe(&state, time: 20, delay: 17.75, nativeAge: 8.6, healthy: false)
    XCTAssertEqual(state.extraDelay!, 17.75 - 8.6 - cushion, accuracy: 0.00001)
    XCTAssertEqual(state.normalDelay, 9.75)
  }

  func testPausedNativePictureTracksAdvancingLiveReferenceWithoutRelearning() {
    var state = LiveChatSyncBaseline()
    calibrate(&state, delay: 3, nativeAge: 2)
    for t in 7...26 {
      observe(&state, time: Double(t), delay: Double(t) - 3, nativeAge: 2, healthy: false)
    }
    XCTAssertEqual(state.extraDelay, 20)
    XCTAssertEqual(state.normalDelay, 3)
    XCTAssertEqual(state.nativeCushion, 1)
  }

  func testReloadKeepsBaselineButCannotUseStaleItemDate() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    state.itemChanged()
    XCTAssertNil(state.extraDelay)
    XCTAssertEqual(state.normalDelay, 3)
    observe(&state, time: 30, delay: 23, healthy: false, itemID: UUID())
    XCTAssertEqual(state.extraDelay, 20)
  }

  func testSourceAndChannelChangesCannotInheritNormalDelay() {
    for context in ["other/twitch", "channel/youtube"] {
      var state = LiveChatSyncBaseline()
      calibrate(&state)
      observe(&state, time: 30, delay: 20, healthy: false, context: context)
      XCTAssertNil(state.normalDelay)
      XCTAssertNil(state.extraDelay)
    }
  }

  func testStaleProgramDateCannotManufactureGrowingDelay() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    state.observe(context: "channel/twitch", itemID: item,
      playbackDate: epoch.addingTimeInterval(3), playbackTime: 4,
      liveTarget: nil, canCalibrate: true, now: epoch.addingTimeInterval(7), uptime: 7)
    XCTAssertNil(state.extraDelay)
    XCTAssertEqual(state.reference, .unavailable)
    XCTAssertEqual(state.normalDelay, 3)
  }

  func testMissingOrInvalidTimestampIsNotTreatedAsZeroLatency() {
    var state = LiveChatSyncBaseline()
    calibrate(&state)
    state.observe(context: "channel/twitch", itemID: item, playbackDate: nil,
      playbackTime: .nan, liveTarget: nil, canCalibrate: false, now: epoch, uptime: 8)
    XCTAssertNil(state.extraDelay)
    XCTAssertEqual(state.normalDelay, 3)
  }

  func testCalibrationRequiresStableAdvancingSamples() {
    var state = LiveChatSyncBaseline()
    for t in 0...20 {
      observe(&state, time: Double(t), delay: t.isMultiple(of: 2) ? 3 : 5)
    }
    XCTAssertNil(state.normalDelay)
    for t in 30...36 { observe(&state, time: Double(t), delay: 3) }
    XCTAssertEqual(state.normalDelay, 3)
  }

  func testImprovedHealthyPlaybackCanLowerTheBaseline() {
    var state = LiveChatSyncBaseline()
    calibrate(&state, delay: 5)
    for t in 10...17 { observe(&state, time: Double(t), delay: 3) }
    XCTAssertEqual(state.normalDelay, 3)
  }
}
