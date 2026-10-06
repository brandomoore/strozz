import AVFoundation
import XCTest
import os
@testable import Strozz

final class NativeLiveCatchUpTests: XCTestCase {
  private func sample(_ time: Double, gap: Double = 6, rendition: String? = "720p60",
                      playing: Bool = true, buffer: Double = 3, allowed: Bool = true,
                      clock: Double? = nil, fresh: Bool = true, rate: Float = 1,
                      normalOffset: Double = 0) -> NativeLiveCatchUp.Sample {
    let clock = clock ?? time
    return .init(uptime: time, clock: clock, playbackDate: Date(timeIntervalSince1970: 1000 + clock),
                 targetDate: Date(timeIntervalSince1970: 1000 + clock + gap), rendition: rendition,
                 isPlaying: playing, buffer: buffer, allowed: allowed,
                 hasFreshVideo: fresh, playbackRate: rate, normalOffset: normalOffset)
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

  func testCapturedXqcGapStartsOneSteadyRateAfterSettling() {
    var state = NativeLiveCatchUp()
    for second in 0..<4 {
      XCTAssertEqual(state.observe(sample(Double(second), gap: 3.110243, buffer: 2.639)), 1)
    }
    XCTAssertEqual(state.observe(sample(4, gap: 3.110243, buffer: 2.639)), 1.05, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(5, gap: 3.110243, buffer: 1.17, rate: 1.05)), 1.05, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(6, gap: 3.110243, buffer: 2.23, rate: 1.05)), 1.05, accuracy: 0.001)
  }

  func testLearnedLiveCushionIsNotMistakenForDelayToErase() {
    var state = NativeLiveCatchUp()
    for time in 0..<10 {
      XCTAssertEqual(state.observe(sample(Double(time), gap: 1.8, normalOffset: 1.747)), 1)
    }
    for time in 10..<14 {
      XCTAssertEqual(state.observe(sample(Double(time), gap: 5.23, normalOffset: 1.747)), 1)
    }
    XCTAssertEqual(state.observe(sample(14, gap: 5.23, normalOffset: 1.747)), 1.05)
    XCTAssertEqual(state.observe(sample(15, gap: 2.3, rate: 1.05, normalOffset: 1.747)), 1)
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
      sample(5, buffer: 0.74), sample(5, buffer: .nan), sample(5, playing: false),
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

  func testBufferHysteresisHoldsRateAcrossNormalSegmentOscillation() {
    var state = NativeLiveCatchUp()
    for time in 0..<4 { XCTAssertEqual(state.observe(sample(Double(time), buffer: 1.7)), 1) }
    XCTAssertEqual(state.observe(sample(4, buffer: 1.7)), 1)
    XCTAssertEqual(state.observe(sample(5, buffer: 2.2)), 1.05, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(6, buffer: 1.7, rate: 1.05)), 1.05, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(7, buffer: 1, rate: 1.05)), 1.05, accuracy: 0.001)
    XCTAssertEqual(state.observe(sample(8, buffer: 0.74, rate: 1.05)), 1)
    for second in 9..<23 { XCTAssertEqual(state.observe(sample(Double(second))), 1) }
    XCTAssertEqual(state.observe(sample(23)), 1.05, accuracy: 0.001)
  }

  func testCapturedSawtoothReachesLiveWithOnlyAnEnterAndExitCommand() {
    let buffers = [1.17, 2.23, 1.195, 2.184, 1.139, 2.132, 1.088, 2.042, 0.981, 2.885]
    var state = NativeLiveCatchUp()
    var clock = 0.0
    var rate: Float = 1
    var transitions: [Float] = []
    var gap = 5.2336
    for second in 0..<160 {
      let time = Double(second) * 1.07
      gap = 5.2336 + time - clock
      let next = state.observe(sample(time, gap: gap, buffer: buffers[second % buffers.count],
                                      clock: clock, rate: rate))
      if next != rate { transitions.append(next) }
      rate = next
      clock += Double(rate) * 1.07
    }
    XCTAssertEqual(transitions, [1.05, 1])
    XCTAssertLessThanOrEqual(gap, NativeLiveCatchUp.settledExcessSeconds)
  }

  func testAnUnacceptedRateDoesNotGetReissuedEverySample() {
    var state = NativeLiveCatchUp()
    for second in 0...4 { _ = state.observe(sample(Double(second))) }
    XCTAssertEqual(state.rate, 1.05)
    XCTAssertEqual(state.observe(sample(5, rate: 1)), 1)
    for second in 6..<20 { XCTAssertEqual(state.observe(sample(Double(second))), 1) }
    XCTAssertEqual(state.observe(sample(20)), 1.05)
  }

  func testHysteresisContinuesUntilNearLiveThenReturnsToNormalRate() {
    var state = NativeLiveCatchUp()
    for time in 0...4 { _ = state.observe(sample(Double(time))) }
    XCTAssertGreaterThan(state.observe(sample(5, gap: 2, rate: 1.05)), 1)
    XCTAssertEqual(state.observe(sample(6, gap: 0.75, rate: 1.05)), 1)
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
    model.nativeStartupComplete = true
    model.isLoading = false
    model.startupProgress.observe(clock: 0, isPlaying: true, now: 0)
    model.startupProgress.observe(clock: 1, isPlaying: true, now: 1)
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    view.didRequestPlayback = true
    return (model, view, player, item)
  }

  func testNativeStartupPositionsOnceBeforeRevealingPlayback() async {
    let (model, view, player, _) = playingModel()
    let item = StartupTrackingItem(url: URL(fileURLWithPath: "/nonexistent-startup.m3u8"))
    player.replaceCurrentItem(with: item)
    model.nativeStartupComplete = false
    model.isLoading = true
    XCTAssertFalse(model.revealPlaybackIfStarted())
    view.startNativePlaybackAtLiveEdge()
    await model.nativeStartupTask?.value
    XCTAssertTrue(model.nativeStartupComplete)
    XCTAssertEqual(item.seeks, 1)
    XCTAssertTrue(item.lastTarget.isPositiveInfinity)
    XCTAssertEqual(item.configuredTimeOffsetFromLive.seconds, 1.5)
    XCTAssertEqual(player.rate, 1)
    view.startNativePlaybackAtLiveEdge()
    XCTAssertEqual(item.seeks, 1)
    player.replaceCurrentItem(with: nil)
  }

  func testItemReplacementClearsThePreviousTimestampMapping() {
    let (_, view, player, _) = playingModel()
    view.lastPlaybackDateSample = Date()
    view.lastPlaybackTimeSampleSeconds = 2516.26
    view.wallClockLowConfidenceStreak = 5
    view.wallClockLatencySeconds = 1747
    view.replacePlaybackItem(with: nil)
    XCTAssertNil(view.lastPlaybackDateSample)
    XCTAssertNil(view.lastPlaybackTimeSampleSeconds)
    XCTAssertEqual(view.wallClockLowConfidenceStreak, 0)
    XCTAssertNil(view.wallClockLatencySeconds)
    XCTAssertNil(player.currentItem)
  }

  func testNativeStartupCannotOverrideAPauseOrNewItem() {
    let (model, view, player, item) = playingModel()
    model.nativeStartupComplete = false
    model.nativeStartupItem = item
    let generation = model.nativeGeneration
    let intent = model.nativePositionIntent
    XCTAssertTrue(view.nativeStartupIsCurrent(item, generation: generation, intent: intent))
    model.isUserPaused = true
    XCTAssertFalse(view.nativeStartupIsCurrent(item, generation: generation, intent: intent))
    model.isUserPaused = false
    player.replaceCurrentItem(with: nil)
    XCTAssertFalse(view.nativeStartupIsCurrent(item, generation: generation, intent: intent))
    view.cancelNativeStartup()
  }

  func testRateCorrectionNeverSeeksOrReplacesTheItem() {
    let (model, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.05, item: item)
    XCTAssertEqual(player.rate, 1.05, accuracy: 0.001)
    XCTAssertTrue(player.currentItem === item)
    XCTAssertTrue(model.nativeCatchUpItem === item)
    XCTAssertEqual(item.timeSeeks, 0)
    XCTAssertEqual(item.cancellations, 0)
  }

  func testRepeatedSamplesNeverReissueAnAlreadyCommandedRate() {
    let (_, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.05, item: item)
    let writes = player.rateWrites
    for _ in 0..<129 { view.applyNativeCatchUpRate(1.05, item: item) }
    XCTAssertEqual(player.rateWrites, writes)
    player.rate = 1
    let externallyResetWrites = player.rateWrites
    view.applyNativeCatchUpRate(1.05, item: item)
    XCTAssertEqual(player.rateWrites, externallyResetWrites, "Do not fight an AVPlayer rate reset")
    XCTAssertEqual(player.rate, 1)
  }

  func testManualPauseStopsOwnedRateWithoutASeekOrResume() {
    let (model, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.05, item: item)
    view.toggleRewindPlayPause()
    XCTAssertTrue(model.isUserPaused)
    XCTAssertFalse(model.nativeCatchUp.isActive)
    XCTAssertNil(model.nativeCatchUpItem)
    XCTAssertEqual(item.cancellations, 0)
    XCTAssertEqual(item.timeSeeks, 0)
    XCTAssertEqual(player.rate, 0)
    view.applyNativeCatchUpRate(1.05, item: item)
    XCTAssertEqual(player.rate, 0)
  }

  func testItemReplacementInvalidatesOwnedRateWithoutCancellingUserSeeks() {
    let (model, view, player, item) = playingModel()
    view.applyNativeCatchUpRate(1.05, item: item)
    view.replacePlaybackItem(with: nil)
    XCTAssertEqual(item.cancellations, 0)
    XCTAssertFalse(model.nativeCatchUp.isActive)
    XCTAssertNil(model.nativeCatchUpItem)
    XCTAssertEqual(player.rate, 1)
  }

  func testCancellationDoesNotResumeAnAlreadyPausedPlayer() {
    let (_, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    view.applyNativeCatchUpRate(1.05, item: item)
    player.pause()
    view.cancelNativeCatchUp(reason: "paused")
    XCTAssertEqual(player.rate, 0)
  }

  func testStaleItemOrBufferingWaitCannotReceiveANewPlaybackRate() {
    let (_, view, player, item) = playingModel()
    defer { player.replaceCurrentItem(with: nil) }
    let stale = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-stale.m3u8"))
    view.applyNativeCatchUpRate(1.05, item: stale)
    XCTAssertEqual(player.rate, 1)
    player.waitForBuffer()
    view.applyNativeCatchUpRate(1.05, item: item)
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
    initialState: (rate: Float(1), control: AVPlayer.TimeControlStatus.playing, writes: 0))
  var rateWrites: Int { state.withLock { $0.writes } }
  override var rate: Float {
    get { state.withLock { $0.rate } }
    set { state.withLock { $0.rate = newValue; $0.writes += 1 } }
  }
  override var timeControlStatus: AVPlayer.TimeControlStatus { state.withLock { $0.control } }
  override func pause() { state.withLock { $0.rate = 0; $0.control = .paused } }
  override func play() { state.withLock { $0.rate = 1; $0.control = .playing } }
  func waitForBuffer() { state.withLock { $0.rate = 0; $0.control = .waitingToPlayAtSpecifiedRate } }
}

private final class StartupTrackingItem: AVPlayerItem, @unchecked Sendable {
  private nonisolated let state = OSAllocatedUnfairLock(
    initialState: (count: 0, target: CMTime.zero, configuredOffset: CMTime.invalid))
  var seeks: Int { state.withLock { $0.count } }
  var lastTarget: CMTime { state.withLock { $0.target } }
  override var status: AVPlayerItem.Status { .readyToPlay }
  override var recommendedTimeOffsetFromLive: CMTime { CMTime(seconds: 1.5, preferredTimescale: 600) }
  override var configuredTimeOffsetFromLive: CMTime {
    get { state.withLock { $0.configuredOffset } }
    set { state.withLock { $0.configuredOffset = newValue } }
  }
  override var seekableTimeRanges: [NSValue] {
    [NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 30, preferredTimescale: 600)))]
  }
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: (@Sendable (Bool) -> Void)? = nil) {
    state.withLock { $0.count += 1; $0.target = time }
    completionHandler?(true)
  }
}
