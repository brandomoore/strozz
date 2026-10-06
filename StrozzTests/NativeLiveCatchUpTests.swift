import AVFoundation
import XCTest
import os
@testable import Strozz

final class NativeLiveCatchUpTests: XCTestCase {
  private func sample(_ time: Double, gap: Double = 6, rendition: String? = "720p60",
                      playing: Bool = true, buffer: Double = 2, allowed: Bool = true,
                      clock: Double? = nil) -> NativeLiveCatchUp.Sample {
    .init(uptime: time, clock: clock ?? time, playbackDate: Date(timeIntervalSince1970: 1000 + time),
          targetDate: Date(timeIntervalSince1970: 1000 + time + gap), rendition: rendition,
          isPlaying: playing, buffer: buffer, allowed: allowed)
  }

  private func start(_ state: inout NativeLiveCatchUp, from time: Double = 0) throws -> NativeLiveCatchUp.Request {
    for step in 0..<4 { XCTAssertNil(state.observe(sample(time + Double(step)))) }
    return try XCTUnwrap(state.observe(sample(time + 4)))
  }

  func testNativeStartupNearLiveDoesNotSeek() {
    for gap in [-5.0, 0, 1, 2.99] {
      var state = NativeLiveCatchUp()
      for time in 0..<60 { XCTAssertNil(state.observe(sample(Double(time), gap: gap))) }
      XCTAssertNil(state.inFlight)
    }
  }

  func testPersistentDelaySeeksOnlyAfterFourSecondsOfSteadyPlayback() throws {
    var state = NativeLiveCatchUp()
    let request = try start(&state)
    XCTAssertEqual(request.target, Date(timeIntervalSince1970: 1010))
    XCTAssertEqual(request.startedAt, 4)
  }

  func testAnthonyZStartupQualityChurnDoesNotLaunchOverlappingSeeks() throws {
    var state = NativeLiveCatchUp()
    for second in 0..<12 {
      let rendition = ["1080p60", "480p", "160p", "360p"][second / 3]
      XCTAssertNil(state.observe(sample(Double(second), rendition: rendition)))
    }
    for second in 12..<16 { XCTAssertNil(state.observe(sample(Double(second), rendition: "720p60"))) }
    let request = try XCTUnwrap(state.observe(sample(16, rendition: "720p60")))
    for second in 17..<24 {
      XCTAssertNil(state.observe(sample(Double(second), rendition: "1080p60")))
      XCTAssertEqual(state.inFlight?.id, request.id)
    }
  }

  func testBufferingAndShallowBufferDoNotTriggerCatchUp() {
    for (playing, buffer) in [(false, 5.0), (true, 0.9), (true, Double.nan)] {
      var state = NativeLiveCatchUp()
      for time in 0..<30 {
        XCTAssertNil(state.observe(sample(Double(time), playing: playing, buffer: buffer)))
      }
    }
  }

  func testStalledOrJumpingClockMustSettleAgain() throws {
    var state = NativeLiveCatchUp()
    for time in 0..<20 { XCTAssertNil(state.observe(sample(Double(time), clock: 0))) }
    for time in 20..<24 { XCTAssertNil(state.observe(sample(Double(time)))) }
    XCTAssertNotNil(state.observe(sample(24)))
  }

  func testTransientGapCannotTriggerASeek() {
    var state = NativeLiveCatchUp()
    for second in 0..<40 {
      XCTAssertNil(state.observe(sample(Double(second), gap: second.isMultiple(of: 3) ? 5 : 1)))
    }
  }

  func testCompletionEnforcesCooldownBeforeAnotherCatchUp() throws {
    var state = NativeLiveCatchUp()
    let request = try start(&state)
    XCTAssertTrue(state.finish(request.id, at: 5))
    for second in 6..<20 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNotNil(state.observe(sample(20)))
  }

  func testTimeoutIsBoundedWithoutLaunchingASecondSeek() throws {
    var state = NativeLiveCatchUp()
    let request = try start(&state)
    XCTAssertFalse(state.timedOut(at: 8.99))
    XCTAssertTrue(state.timedOut(at: 9))
    state.interrupt(at: 9)
    XCTAssertNil(state.inFlight)
    XCTAssertFalse(state.finish(request.id, at: 10))
    for second in 10..<24 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNotNil(state.observe(sample(24)))
  }

  func testStaleCompletionCannotClearANewerRequest() throws {
    var state = NativeLiveCatchUp()
    let previous = try start(&state)
    state.interrupt(at: 5)
    let current = try start(&state, from: 20)
    XCTAssertFalse(state.finish(previous.id, at: 25))
    XCTAssertEqual(state.inFlight?.id, current.id)
    XCTAssertTrue(state.finish(current.id, at: 26))
  }

  func testManualIntentAndLongSamplingGapResetSettling() {
    var state = NativeLiveCatchUp()
    for second in 0..<4 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNil(state.observe(sample(4, allowed: false)))
    for second in 5..<9 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNotNil(state.observe(sample(9)))
    state.interrupt(at: 10)
    for second in 30..<34 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNil(state.observe(sample(60)))
    for second in 61..<64 { XCTAssertNil(state.observe(sample(Double(second)))) }
    XCTAssertNotNil(state.observe(sample(64)))
  }

  func testMissingOrStaleDatesCannotCauseASeek() {
    var state = NativeLiveCatchUp()
    for second in 0..<30 {
      let time = Double(second)
      XCTAssertNil(state.observe(.init(
        uptime: time, clock: time, playbackDate: Date(timeIntervalSince1970: 1000),
        targetDate: Date(timeIntervalSince1970: 1010 + time), rendition: "720p60",
        isPlaying: true, buffer: 3, allowed: true)))
    }
    XCTAssertNil(state.observe(.init(uptime: 31, clock: 31, playbackDate: nil, targetDate: nil,
      rendition: "720p60", isPlaying: true, buffer: 3, allowed: true)))
  }
}

@MainActor
final class NativeLiveCatchUpIntegrationTests: XCTestCase {
  private func arm(_ model: PlayerModel) throws -> NativeLiveCatchUp.Request {
    var request: NativeLiveCatchUp.Request?
    for second in 0...4 {
      request = model.nativeCatchUp.observe(.init(
        uptime: Double(second), clock: Double(second),
        playbackDate: Date(timeIntervalSince1970: Double(second)),
        targetDate: Date(timeIntervalSince1970: Double(second + 6)),
        rendition: "720p60", isPlaying: true, buffer: 3, allowed: true))
    }
    return try XCTUnwrap(request)
  }

  func testManualPauseCancelsTheOwnedSeekAndCannotBeUndoneByItsCompletion() throws {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-catch-up.m3u8"))
    model.player.replaceCurrentItem(with: item)
    let request = try arm(model)
    model.nativeCatchUpItem = item
    view.toggleRewindPlayPause()
    XCTAssertNil(model.nativeCatchUp.inFlight)
    XCTAssertEqual(item.cancellations, 1)
    XCTAssertTrue(model.isUserPaused)
    XCTAssertFalse(model.nativeCatchUp.finish(request.id, at: 10))
    XCTAssertEqual(model.player.rate, 0)
    model.player.replaceCurrentItem(with: nil)
  }

  func testItemReplacementInvalidatesPendingCatchUp() throws {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = TrackingPlayerItem(url: URL(fileURLWithPath: "/nonexistent-old.m3u8"))
    model.player.replaceCurrentItem(with: item)
    let request = try arm(model)
    model.nativeCatchUpItem = item
    view.replacePlaybackItem(with: nil)
    XCTAssertEqual(item.cancellations, 1)
    XCTAssertNil(model.nativeCatchUp.inFlight)
    XCTAssertNil(model.nativeCatchUpItem)
    XCTAssertFalse(model.nativeCatchUp.finish(request.id, at: 20))
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
