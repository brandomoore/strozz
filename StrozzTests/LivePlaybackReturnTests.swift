import XCTest

@testable import Strozz

@MainActor
final class LivePlaybackReturnTests: XCTestCase {
  private let departure = Date(timeIntervalSince1970: 1_000)

  func testLeavingLiveRestoresLiveForEitherDestination() {
    for absence in [LivePlaybackReturnState.Absence.background, .channelPage] {
      let model = PlayerModel()
      model.beginPlaybackAbsence(absence, isVOD: false, now: departure)
      XCTAssertTrue(model.endPlaybackAbsence(
        absence, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(22)))
      XCTAssertTrue(model.pinnedToLive)
      XCTAssertFalse(model.isUserPaused)
      XCTAssertFalse(model.livePlaybackReturn.isAway)
    }
  }

  func testSuspendedPlaylistCanLookLiveButStillNeedsRefreshing() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: true, now: departure.addingTimeInterval(22)))
  }

  func testBriefTripAtLiveAvoidsReloadWithoutDroppingLiveIntent() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: true, now: departure.addingTimeInterval(4.99)))
    XCTAssertTrue(model.pinnedToLive)
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: true, now: departure.addingTimeInterval(5)))
  }

  func testBriefTripThatFellBehindStillRestoresLive() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(2)))
  }

  func testDepartureSnapshotPreservesDeliberateViewingState() {
    for configure in nonLiveStates {
      let model = PlayerModel()
      configure(model)
      model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
      clearNonLiveState(model)
      XCTAssertFalse(model.endPlaybackAbsence(
        .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(60)))
    }
  }

  func testNewPauseRewindScrubSleepOrOfflineStatePreventsLiveReturn() {
    for configure in nonLiveStates {
      let model = PlayerModel()
      model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
      configure(model)
      XCTAssertFalse(model.endPlaybackAbsence(
        .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(60)))
      XCTAssertFalse(model.livePlaybackReturn.isAway)
      clearNonLiveState(model)
      XCTAssertFalse(model.endPlaybackAbsence(
        .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(90)))
    }
  }

  func testPausedAndRewoundStateRemainsUnchangedOnReturn() {
    let model = PlayerModel()
    model.pinnedToLive = false
    model.isUserPaused = true
    model.scrubTargetSeconds = 123
    model.beginPlaybackAbsence(.channelPage, isVOD: false, now: departure)
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(60)))
    XCTAssertFalse(model.pinnedToLive)
    XCTAssertTrue(model.isUserPaused)
    XCTAssertEqual(model.scrubTargetSeconds, 123)
  }

  func testVODAtDepartureOrReturnNeverJumpsToLive() {
    for (leftInVOD, returnedInVOD) in [(true, true), (true, false), (false, true)] {
      let model = PlayerModel()
      model.beginPlaybackAbsence(.channelPage, isVOD: leftInVOD, now: departure)
      XCTAssertFalse(model.endPlaybackAbsence(
        .channelPage, isVOD: returnedInVOD, isAtLiveEdge: false,
        now: departure.addingTimeInterval(60)))
    }
  }

  func testBackgroundReturnWhileChannelPageIsOpenDefersLiveRefresh() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.channelPage, isVOD: false, now: departure)
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure.addingTimeInterval(10))
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(30)))
    XCTAssertTrue(model.livePlaybackReturn.isAway)
    XCTAssertTrue(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: true, now: departure.addingTimeInterval(32)))
    XCTAssertFalse(model.livePlaybackReturn.isAway)
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(33)))
  }

  func testChannelPageDismissalInBackgroundDefersUntilForeground() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.channelPage, isVOD: false, now: departure)
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure.addingTimeInterval(10))
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(11)))
    XCTAssertTrue(model.livePlaybackReturn.isAway)
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(30)))
    XCTAssertFalse(model.livePlaybackReturn.isAway)
  }

  func testNestedTripCannotTurnAnOriginalRewindIntoLiveIntent() {
    let model = PlayerModel()
    model.pinnedToLive = false
    model.beginPlaybackAbsence(.channelPage, isVOD: false, now: departure)
    model.pinnedToLive = true
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure.addingTimeInterval(10))
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(30)))
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(31)))
  }

  func testDuplicateDeparturePreservesOriginalTimeAndIntent() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    model.isUserPaused = true
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure.addingTimeInterval(20))
    model.isUserPaused = false
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: true, now: departure.addingTimeInterval(21)))
  }

  func testUnmatchedOrDuplicateReturnDoesNotReload() {
    let model = PlayerModel()
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure))
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(10)))
    XCTAssertTrue(model.livePlaybackReturn.isAway)
    XCTAssertTrue(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(11)))
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(12)))
  }

  func testResetDropsOldSessionIntentAndNextTripTakesANewSnapshot() {
    let model = PlayerModel()
    model.beginPlaybackAbsence(.background, isVOD: false, now: departure)
    model.livePlaybackReturn = LivePlaybackReturnState()
    XCTAssertFalse(model.endPlaybackAbsence(
      .background, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(60)))
    model.pinnedToLive = false
    model.beginPlaybackAbsence(.channelPage, isVOD: false, now: departure.addingTimeInterval(61))
    XCTAssertFalse(model.endPlaybackAbsence(
      .channelPage, isVOD: false, isAtLiveEdge: false, now: departure.addingTimeInterval(90)))
  }

  private var nonLiveStates: [(PlayerModel) -> Void] {
    [
      { $0.pinnedToLive = false },
      { $0.isUserPaused = true },
      { $0.isScrubbing = true },
      { $0.scrubTargetSeconds = 123 },
      { $0.vodHandoffTransitionInFlight = true },
      { $0.isSleeping = true },
      { $0.isOffline = true },
    ]
  }

  private func clearNonLiveState(_ model: PlayerModel) {
    model.pinnedToLive = true
    model.isUserPaused = false
    model.isScrubbing = false
    model.scrubTargetSeconds = nil
    model.vodHandoffTransitionInFlight = false
    model.isSleeping = false
    model.isOffline = false
  }
}
