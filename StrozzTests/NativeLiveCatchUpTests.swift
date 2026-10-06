import AVFoundation
import XCTest
import os
@testable import Strozz

final class NativeLiveCatchUpTests: XCTestCase {
  private func sample(_ time: Double, gap: Double = 6, rendition: String? = "720p60",
                      playing: Bool = true, buffer: Double = 3, allowed: Bool = true,
                      clock: Double? = nil, fresh: Bool = true, rate: Float = 1) -> NativeLiveCatchUp.Sample {
    let clock = clock ?? time
    return .init(uptime: time, clock: clock, playbackDate: Date(timeIntervalSince1970: 1000 + clock),
                 targetDate: Date(timeIntervalSince1970: 1000 + clock + gap), rendition: rendition,
                 isPlaying: playing, buffer: buffer, allowed: allowed,
                 hasFreshVideo: fresh, playbackRate: rate)
  }

  func testNormalLivePlaybackAndTransientGapsStayAtNormalRate() {
    for gap in [-5.0, 0, 1, 2.99] {
      var state = NativeLiveCatchUp()
      for time in 0..<60 { XCTAssertEqual(state.observe(sample(Double(time), gap: gap)), 1) }
      XCTAssertFalse(state.isActive)
    }
    var state = NativeLiveCatchUp()
    for time in 0..<40 {
      XCTAssertEqual(state.observe(sample(Double(time), gap: time.isMultiple(of: 3) ? 5 : 1)), 1)
    }
  }

  func testCapturedXqcGapRampsRateAfterSteadyPlayback() {
    var state = NativeLiveCatchUp()
    for second in 0..<4 {
      XCTAssertEqual(state.observe(sample(Double(second), gap: 3.110243, buffer: 2.639)), 1)
    }
    XCTAssertEqual(state.observe(sample(4, gap: 3.110243, buffer: 2.639)), 1.02, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(5, gap: 3.110243, buffer: 2.639)), 1.04, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(6, gap: 3.110243, buffer: 2.639)), 1.06, accuracy: 0.001)
  }

  func testQualityChurnWaitsForSteadyPlaybackAndInterruptsAcceleration() {
    var state = NativeLiveCatchUp()
    for second in 0..<12 {
      XCTAssertEqual(state.observe(sample(Double(second),
        rendition: ["1080p60", "480p", "160p", "360p"][second / 3])), 1)
    }
    for second in 12..<16 { XCTAssertEqual(state.observe(sample(Double(second))), 1) }
    XCTAssertGreaterThan(state.observe(sample(16)), 1)
    XCTAssertEqual(state.observe(sample(17, rendition: "1080p60")), 1)
  }

  func testLowBufferWaitingMissingFramesAndManualIntentStopAcceleration() {
    for invalid in [
      sample(5, buffer: 0.99), sample(5, buffer: .nan), sample(5, playing: false),
      sample(5, allowed: false), sample(5, fresh: false), sample(5, rate: 0)
    ] {
      var state = NativeLiveCatchUp()
      for time in 0...4 { _ = state.observe(sample(Double(time))) }
      XCTAssertTrue(state.isActive)
      XCTAssertEqual(state.observe(invalid), 1)
      XCTAssertFalse(state.isActive)
    }
  }

  func testDeepDelayIsRateLimitedAndConvergesWithoutSkippingVideo() {
    var state = NativeLiveCatchUp()
    var clock = 0.0
    var rate: Float = 1
    var gap = 6.0
    for second in 0..<180 {
      gap = 6 + Double(second) - clock
      rate = state.observe(sample(Double(second), gap: gap, clock: clock, rate: rate))
      XCTAssertGreaterThanOrEqual(rate, 1)
      XCTAssertLessThanOrEqual(rate, NativeLiveCatchUp.maximumRate)
      clock += Double(rate)
    }

    XCTAssertLessThanOrEqual(gap, NativeLiveCatchUp.settledExcessSeconds)
    XCTAssertEqual(rate, 1)
    XCTAssertGreaterThan(clock, 180)
  }

  func testBufferHeadroomLimitsSpeedWithoutPreventingSteadyOneSecondBufferSampling() {
    var state = NativeLiveCatchUp()
    for time in 0..<4 { XCTAssertEqual(state.observe(sample(Double(time), buffer: 1.7)), 1) }
    XCTAssertEqual(state.observe(sample(4, buffer: 1.7)), 1.02, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(5, buffer: 1.7)), 1.04, accuracy: 0.001)
    XCTAssertLessThanOrEqual(state.observe(sample(6, buffer: 1.7)), 1.05)
    XCTAssertEqual(state.observe(sample(7, buffer: 1)), 1)
    XCTAssertEqual(state.observe(sample(8, buffer: 0.9)), 1)
  }

  func testHysteresisContinuesUntilNearLiveThenReturnsToNormalRate() {
    var state = NativeLiveCatchUp()
    for time in 0...4 { _ = state.observe(sample(Double(time))) }
    XCTAssertGreaterThan(state.observe(sample(5, gap: 2)), 1)
    XCTAssertEqual(state.observe(sample(6, gap: 0.75)), 1)
    XCTAssertEqual(state.observe(sample(7, gap: 2)), 1)
  }

  func testMissingStaleOrJumpingTimelineAndLongSamplingGapCannotAccelerate() {
    var state = NativeLiveCatchUp()
    for second in 0..<30 {
      let time = Double(second)
      XCTAssertEqual(state.observe(.init(
        uptime: time, clock: time, playbackDate: Date(timeIntervalSince1970: 1000),
        targetDate: Date(timeIntervalSince1970: 1010 + time), rendition: "720p60",
        isPlaying: true, buffer: 3, allowed: true)), 1)
    }
    XCTAssertEqual(state.observe(.init(uptime: 31, clock: 31, playbackDate: nil, targetDate: nil,
      rendition: "720p60", isPlaying: true, buffer: 3, allowed: true)), 1)
    for second in 32..<36 { XCTAssertEqual(state.observe(sample(Double(second))), 1) }
    XCTAssertGreaterThan(state.observe(sample(36)), 1)
    XCTAssertEqual(state.observe(sample(37, clock: 100)), 1)
    XCTAssertEqual(state.observe(sample(60, clock: 123)), 1)
  }

  func testLiveTargetUsesActiveRenditionRatherThanFasterInactiveOne() {
    let url = URL(string: "https://example.invalid/video.m3u8")!
    func source(_ date: TimeInterval, live: Bool = true) -> NativeHLSOrigin.Rendition {
      var result = NativeHLSOrigin.Rendition(url: url, segments: [
        .init(sequence: 1, url: url, date: Date(timeIntervalSince1970: date),
              discontinuity: 0, tags: [], complete: true, declaredDuration: 2)
      ])
      result.reachedLiveEdge = live
      return result
    }
    let sources = [0: source(100), 1: source(110), 2: source(120, live: false)]
    XCTAssertEqual(NativeHLSOrigin.liveTargetDate(in: sources, active: 0), Date(timeIntervalSince1970: 100.5))
    XCTAssertEqual(NativeHLSOrigin.liveTargetDate(in: sources, active: 1), Date(timeIntervalSince1970: 110.5))
    XCTAssertNil(NativeHLSOrigin.liveTargetDate(in: sources, active: 2))
    XCTAssertNil(NativeHLSOrigin.liveTargetDate(in: sources, active: 3))
  }
}

@MainActor
final class NativeLiveCatchUpIntegrationTests: XCTestCase {
  private func playingModel() -> (PlayerModel, PlayerView, RateTrackingPlayer, TrackingPlayerItem) {
    let model = PlayerModel()
    let player = RateTrackingPlayer()
    model.player = player
    let item = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-catch-up.m3u8"))
    player.replaceCurrentItem(with: item)
    model.isUsingNativeHLS = true
    model.isLoading = false
    model.startupProgress.observe(clock: 0, isPlaying: true, now: 0)
    model.startupProgress.observe(clock: 1, isPlaying: true, now: 1)
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    view.didRequestPlayback = true
    return (model, view, player, item)
  }

  func testRateCorrectionNeverSeeksOrReplacesTheItem() {
    let (model, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.06, item: item)
    XCTAssertEqual(player.rate, 1.06, accuracy: 0.001)
    XCTAssertTrue(player.currentItem === item)
    XCTAssertTrue(model.nativeCatchUpItem === item)
    XCTAssertEqual(item.timeSeeks, 0)
    XCTAssertEqual(item.cancellations, 0)
  }

  func testManualPauseStopsOwnedRateWithoutASeekOrResume() {
    let (model, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.06, item: item)
    view.toggleRewindPlayPause()
    XCTAssertTrue(model.isUserPaused)
    XCTAssertFalse(model.nativeCatchUp.isActive)
    XCTAssertNil(model.nativeCatchUpItem)
    XCTAssertEqual(item.cancellations, 0)
    XCTAssertEqual(item.timeSeeks, 0)
    XCTAssertEqual(player.rate, 0)
    view.applyNativeCatchUpRate(1.08, item: item)
    XCTAssertEqual(player.rate, 0)
  }

  func testItemReplacementInvalidatesOwnedRateWithoutCancellingUserSeeks() {
    let (model, view, player, item) = playingModel()
    view.applyNativeCatchUpRate(1.06, item: item)
    view.replacePlaybackItem(with: nil)
    XCTAssertEqual(item.cancellations, 0)
    XCTAssertFalse(model.nativeCatchUp.isActive)
    XCTAssertNil(model.nativeCatchUpItem)
    XCTAssertEqual(player.rate, 1)
  }

  func testCancellationDoesNotResumeAnAlreadyPausedPlayer() {
    let (_, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.06, item: item)
    player.pause()
    view.cancelNativeCatchUp(reason: "paused")
    XCTAssertEqual(player.rate, 0)
  }

  func testStaleItemOrBufferingWaitCannotReceiveANewPlaybackRate() {
    let (_, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    let stale = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-stale.m3u8"))
    view.applyNativeCatchUpRate(1.08, item: stale)
    XCTAssertEqual(player.rate, 1)
    player.waitForBuffer()
    view.applyNativeCatchUpRate(1.08, item: item)
    XCTAssertEqual(player.rate, 0)
  }

  func testNativePlaybackDisablesAVPlayersSeekOnRebufferAfterStartup() {
    let (model, view, player, _) = playingModel()
    defer { model.nativeHLS?.stop(); player.replaceCurrentItem(with: nil) }
    let item = view.makeItem(url: URL(string: "https://example.invalid/live.m3u8")!)
    player.replaceCurrentItem(with: item)
    view.updateLatencyMetrics()
    XCTAssertFalse(item.automaticallyPreservesTimeOffsetFromLive)
  }

  func testLegacyResyncCannotSeekDuringNativePlayback() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.isUsingNativeHLS = true
    let item = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-resync.m3u8"))
    view.triggerLiveEdgeResyncIfAllowed(item: item, edge: 90)
    XCTAssertEqual(model.mon.liveResyncAttempts, 0)
    XCTAssertEqual(item.timeSeeks, 0)
  }

  func testFailedPlayerIsReplacedRatherThanLeavingARejectedItemBlack() {
    let model = PlayerModel()
    let failed = FailedPlayer()
    failed.volume = 0.3
    failed.isMuted = true
    model.player = failed
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-recovery.m3u8"))
    view.replacePlaybackItem(with: item)
    XCTAssertFalse(model.player === failed)
    XCTAssertTrue(model.player.currentItem === item)
    XCTAssertEqual(model.player.volume, 0.3, accuracy: 0.001)
    XCTAssertTrue(model.player.isMuted)
    model.player.replaceCurrentItem(with: nil)
  }

  func testHealthyPlayerIsNotRebuiltForEveryItem() {
    let model = PlayerModel()
    let existing = model.player
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-normal.m3u8"))
    view.replacePlaybackItem(with: item)
    XCTAssertTrue(model.player === existing)
    XCTAssertTrue(model.player.currentItem === item)
    model.player.replaceCurrentItem(with: nil)
  }

  func testRejectedItemCannotLeaveThePlayerPermanentlyEmpty() {
    let model = PlayerModel()
    let rejecting = RejectingPlayer()
    model.player = rejecting
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-rejected.m3u8"))
    view.replacePlaybackItem(with: item)
    XCTAssertFalse(model.player === rejecting)
    XCTAssertTrue(model.player.currentItem === item)
    XCTAssertNil(model.errorMessage)
    model.player.replaceCurrentItem(with: nil)
  }
}

private final class FailedPlayer: AVPlayer, @unchecked Sendable {
  override var status: AVPlayer.Status { .failed }
}

private final class RejectingPlayer: AVPlayer, @unchecked Sendable {
  override func replaceCurrentItem(with item: AVPlayerItem?) {}
}

private final class TrackingPlayerItem: AVPlayerItem, @unchecked Sendable {
  private nonisolated let counters = OSAllocatedUnfairLock(initialState: (cancellations: 0, timeSeeks: 0))
  var cancellations: Int { counters.withLock { $0.cancellations } }
  var timeSeeks: Int { counters.withLock { $0.timeSeeks } }

  override func cancelPendingSeeks() {
    counters.withLock { $0.cancellations += 1 }
    super.cancelPendingSeeks()
  }

  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: (@Sendable (Bool) -> Void)? = nil) {
    counters.withLock { $0.timeSeeks += 1 }
    completionHandler?(true)
  }
}

private final class RateTrackingPlayer: AVPlayer, @unchecked Sendable {
  private nonisolated let state = OSAllocatedUnfairLock(
    initialState: (rate: Float(1), control: AVPlayer.TimeControlStatus.playing))
  override var rate: Float {
    get { state.withLock { $0.rate } }
    set { state.withLock { $0.rate = newValue } }
  }
  override var timeControlStatus: AVPlayer.TimeControlStatus { state.withLock { $0.control } }
  override func pause() { state.withLock { $0.rate = 0; $0.control = .paused } }
  func waitForBuffer() { state.withLock { $0.rate = 0; $0.control = .waitingToPlayAtSpecifiedRate } }
}
