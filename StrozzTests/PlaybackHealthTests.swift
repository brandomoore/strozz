import XCTest

@testable import Strozz

final class PlaybackHealthTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000)

  func testReturningAfterSuspensionDoesNotCountBackgroundTimeAsFrozen() {
    let monitor = PlaybackMonitorBox()
    XCTAssertEqual(monitor.observeLiveEdge(306, at: start), 0)
    XCTAssertEqual(monitor.observeLiveEdge(306, at: start.addingTimeInterval(2)), 0)
    XCTAssertEqual(monitor.observeLiveEdge(306, at: start.addingTimeInterval(4)), 2)

    monitor.resetPlaybackHealth()
    let resumed = start.addingTimeInterval(282)
    XCTAssertEqual(monitor.observeLiveEdge(306, at: resumed), 0)
    XCTAssertEqual(monitor.observeLiveEdge(306, at: resumed.addingTimeInterval(2)), 0)
    XCTAssertEqual(monitor.observeLiveEdge(306, at: resumed.addingTimeInterval(4)), 2)
  }

  func testResumedTimelineCanRebaseBelowPreviousLiveEdge() {
    let monitor = PlaybackMonitorBox()
    _ = monitor.observeLiveEdge(306, at: start)
    _ = monitor.observeLiveEdge(306, at: start.addingTimeInterval(2))

    XCTAssertEqual(monitor.observeLiveEdge(10, at: start.addingTimeInterval(284)), 0)
    XCTAssertEqual(monitor.lastLiveEdgeSeconds, 10)
    XCTAssertNil(monitor.liveEdgeFrozenSince)
    XCTAssertEqual(monitor.observeLiveEdge(12, at: start.addingTimeInterval(286)), 0)
  }

  func testSustainedFreezeStillReachesRecoveryThreshold() {
    let monitor = PlaybackMonitorBox()
    _ = monitor.observeLiveEdge(20, at: start)
    _ = monitor.observeLiveEdge(20, at: start.addingTimeInterval(2))
    XCTAssertEqual(monitor.observeLiveEdge(20, at: start.addingTimeInterval(9)), 7)
    XCTAssertEqual(monitor.observeLiveEdge(20, at: start.addingTimeInterval(10)), 8)
    XCTAssertEqual(monitor.observeLiveEdge(22, at: start.addingTimeInterval(12)), 0)
    XCTAssertNil(monitor.liveEdgeFrozenSince)
  }

  func testMissingOrInvalidEdgeDoesNotReuseOldFreeze() {
    for edge: Double? in [nil, .nan, .infinity, 0, -1] {
      let monitor = PlaybackMonitorBox()
      _ = monitor.observeLiveEdge(20, at: start)
      _ = monitor.observeLiveEdge(20, at: start.addingTimeInterval(2))
      XCTAssertEqual(monitor.observeLiveEdge(edge, at: start.addingTimeInterval(20)), 0)
      XCTAssertNil(monitor.lastLiveEdgeSeconds)
      XCTAssertNil(monitor.liveEdgeFrozenSince)
    }
  }

  func testResetClearsTransientHealthButPreservesStabilityModeAndPlaybackIntent() {
    let monitor = PlaybackMonitorBox()
    monitor.lastObservedPlaybackTimeSeconds = 312
    monitor.stalledPlaybackSamples = 5
    monitor.isRecoveringPlayback = true
    monitor.lastRecoveryAttemptAt = start
    monitor.lastLiveResyncAt = start
    monitor.liveResyncAttempts = 2
    monitor.liveStallWaitingSince = start
    monitor.lastLiveEdgeSeconds = 306
    monitor.liveEdgeFrozenSince = start
    monitor.softStallSince = start
    monitor.lastSoftStallNudgeAt = start
    monitor.lastFrozenPlayheadNudgeAt = start
    monitor.didRequestPlayback = true
    monitor.streamUnstableSince = start
    monitor.recentInstabilityEvents = [start]

    let generation = monitor.healthGeneration
    monitor.resetPlaybackHealth()

    XCTAssertNotEqual(monitor.healthGeneration, generation)
    XCTAssertNil(monitor.lastObservedPlaybackTimeSeconds)
    XCTAssertEqual(monitor.stalledPlaybackSamples, 0)
    XCTAssertFalse(monitor.isRecoveringPlayback)
    XCTAssertEqual(monitor.lastRecoveryAttemptAt, .distantPast)
    XCTAssertEqual(monitor.lastLiveResyncAt, .distantPast)
    XCTAssertEqual(monitor.liveResyncAttempts, 0)
    XCTAssertNil(monitor.liveStallWaitingSince)
    XCTAssertNil(monitor.lastLiveEdgeSeconds)
    XCTAssertNil(monitor.liveEdgeFrozenSince)
    XCTAssertNil(monitor.softStallSince)
    XCTAssertEqual(monitor.lastSoftStallNudgeAt, .distantPast)
    XCTAssertEqual(monitor.lastFrozenPlayheadNudgeAt, .distantPast)
    XCTAssertTrue(monitor.didRequestPlayback)
    XCTAssertEqual(monitor.streamUnstableSince, start)
    XCTAssertEqual(monitor.recentInstabilityEvents, [start])
  }

  func testStaleOfflineResponseCannotCompleteNewProbeAfterReset() throws {
    let monitor = PlaybackMonitorBox()
    let oldProbe = try XCTUnwrap(monitor.beginOfflineProbe(at: start, cooldown: 8))
    monitor.resetPlaybackHealth()
    XCTAssertFalse(monitor.offlineProbeInFlight)
    XCTAssertEqual(monitor.lastOfflineProbeAt, .distantPast)

    let newProbe = try XCTUnwrap(monitor.beginOfflineProbe(at: start, cooldown: 8))
    XCTAssertNotEqual(oldProbe, newProbe)
    XCTAssertFalse(monitor.finishOfflineProbe(generation: oldProbe))
    XCTAssertTrue(monitor.offlineProbeInFlight)
    XCTAssertTrue(monitor.finishOfflineProbe(generation: newProbe))
    XCTAssertFalse(monitor.offlineProbeInFlight)
  }

  func testOfflineProbesRemainSingleFlightAndRateLimited() throws {
    let monitor = PlaybackMonitorBox()
    let probe = try XCTUnwrap(monitor.beginOfflineProbe(at: start, cooldown: 8))
    XCTAssertNil(monitor.beginOfflineProbe(at: start.addingTimeInterval(20), cooldown: 8))
    XCTAssertTrue(monitor.finishOfflineProbe(generation: probe))
    XCTAssertNil(monitor.beginOfflineProbe(at: start.addingTimeInterval(7.9), cooldown: 8))
    XCTAssertNotNil(monitor.beginOfflineProbe(at: start.addingTimeInterval(8), cooldown: 8))
  }
}
