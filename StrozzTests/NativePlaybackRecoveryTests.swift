import AVFoundation
import XCTest
@testable import Strozz

final class NativePlaybackRecoveryTests: XCTestCase {
  func testTransientFailuresRetryWithinOneSharedRollingBudget() {
    var policy = NativePlaybackRecovery()
    let start = Date(timeIntervalSince1970: 100)
    XCTAssertTrue(policy.takeRetry(for: .unavailable, at: start))
    XCTAssertTrue(policy.takeRetry(for: .timeout, at: start.addingTimeInterval(5)))
    XCTAssertFalse(policy.takeRetry(for: .transition, at: start.addingTimeInterval(10)))
    XCTAssertTrue(policy.takeRetry(for: .unavailable, at: start.addingTimeInterval(61)))
    XCTAssertFalse(policy.takeRetry(for: .invalidMedia, at: start.addingTimeInterval(62)))
  }

  func testUnsupportedFormatsDoNotWasteRetryBudget() {
    var policy = NativePlaybackRecovery()
    for error in [NativeHLSError.unsupported, .transportCodec, .transportTable, .partDuration] {
      XCTAssertFalse(policy.takeRetry(for: error))
      XCTAssertTrue(policy.attempts.isEmpty)
    }
  }

  func testInterruptedTimelineAndIndexerFailuresCanUseFreshNativeEngine() {
    for error in [NativeHLSError.transition, .invalidMedia, .indexerOverrun, .transportKeyframe] {
      var policy = NativePlaybackRecovery()
      XCTAssertTrue(policy.takeRetry(for: error))
    }
  }
}

@MainActor
final class NativeRecoveryIntegrationTests: XCTestCase {
  private func withModel(_ body: (PlayerModel, PlayerView) async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let keys = [PersistenceKey.preferredQuality, PersistenceKey.livePlaybackProfile]
    let saved = keys.map { defaults.object(forKey: $0) }
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let model = PlayerModel()
    model.activeChannel = "fixture"
    model.isUsingNativeHLS = true
    model.isUserPaused = true
    model.player.isMuted = true
    model.currentSourceURL = URL(string: "https://example.invalid/old-master.m3u8")!
    model.nativeHLS = NativeLowLatencyHLS(sourceURL: model.currentSourceURL!, headers: [:], history: 30) { _ in }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    defer {
      model.nativeRefreshTask?.cancel()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    try await body(model, view)
  }

  func testOriginFailureResolvesFreshNativeSourceWithoutLegacyFallback() async throws {
    try await withModel { model, view in
      let old = model.nativeHLS
      let fresh = URL(string: "https://example.invalid/new-master.m3u8")!
      view.recoverNativeHLS(.unavailable) { StreamPlayback(master: fresh, qualities: []) }
      await model.nativeRefreshTask?.value
      XCTAssertFalse(model.nativeHLS === old)
      XCTAssertEqual(model.nativeHLS?.sourceURL, fresh)
      XCTAssertTrue(model.isUsingNativeHLS)
      XCTAssertNil(model.nativeFallbackReason)
      XCTAssertEqual(model.nativeRecovery.attempts.count, 1)
      XCTAssertEqual(view.selectedQualityOption, LivePlaybackProfile.nativeLowLatency.pickerLabel)
      XCTAssertEqual(model.player.rate, 0, "Retry must preserve a paused viewer")
      XCTAssertEqual((try XCTUnwrap(model.player.currentItem).asset as? AVURLAsset)?.url.scheme, NativeLowLatencyHLS.scheme)
    }
  }

  func testPinnedVideoKeepsNativeEngineAcrossCreationAndFreshSourceRetry() async throws {
    try await withModel { model, view in
      let master = URL(string: "https://example.invalid/master.m3u8")!
      let video = StreamQuality(
        id: "720p60", name: "720p60",
        url: URL(string: "https://example.invalid/720.m3u8")!, isAudioOnly: false,
        bitrate: 3_400_000)
      view.playback = StreamPlayback(master: master, qualities: [video])
      view.preferredQuality = video.name
      view.replacePlaybackItem(with: view.makeItem(url: video.url))
      XCTAssertTrue(model.isUsingNativeHLS)
      XCTAssertEqual(model.nativeHLS?.sourceURL, video.url)
      XCTAssertEqual(model.player.currentItem?.preferredForwardBufferDuration, 3)
      XCTAssertEqual(view.qualityEngineStatus, "Preparing Native LL-HLS")
      let fresh = StreamQuality(
        id: video.id, name: video.name,
        url: URL(string: "https://example.invalid/fresh-720.m3u8")!, isAudioOnly: false,
        bitrate: video.bitrate)
      view.recoverNativeHLS(.timeout) { StreamPlayback(master: master, qualities: [fresh]) }
      await model.nativeRefreshTask?.value
      XCTAssertTrue(model.isUsingNativeHLS)
      XCTAssertNil(model.nativeFallbackReason)
      XCTAssertEqual(model.nativeHLS?.sourceURL, fresh.url)
      XCTAssertEqual(view.preferredQuality, video.name)
      XCTAssertEqual(model.player.rate, 0)
    }
  }

  func testAudioOnlyDoesNotEnterVideoPartIndexer() async {
    await withModel { model, view in
      let url = URL(string: "https://example.invalid/audio.m3u8")!
      let audio = StreamQuality(
        id: "audio_only", name: "Audio Only", url: url,
        isAudioOnly: true, bitrate: 160_000)
      view.playback = StreamPlayback(master: url, qualities: [audio])
      view.preferredQuality = audio.name
      view.replacePlaybackItem(with: view.makeItem(url: url))
      XCTAssertFalse(model.isUsingNativeHLS)
      XCTAssertNil(model.nativeHLS)
    }
  }

  func testMasterFallbackForAnUnavailableSavedQualityStillUsesNative() async {
    await withModel { model, view in
      let master = URL(string: "https://example.invalid/master.m3u8")!
      view.playback = StreamPlayback(master: master, qualities: [])
      view.preferredQuality = "Unavailable previous quality"
      view.replacePlaybackItem(with: view.makeItem(url: master))
      XCTAssertTrue(model.isUsingNativeHLS)
      XCTAssertEqual(model.nativeHLS?.sourceURL, master)
    }
  }

  func testDuplicateFailuresCoalesceAndLatestPauseIsPreserved() async throws {
    try await withModel { model, view in
      model.isUserPaused = false
      var continuation: CheckedContinuation<StreamPlayback, Never>?
      view.recoverNativeHLS(.unavailable) {
        await withCheckedContinuation { continuation = $0 }
      }
      for _ in 0..<100 {
        if continuation != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertNotNil(continuation)
      view.recoverNativeHLS(.timeout) { XCTFail("A duplicate must not start another resolver"); throw URLError(.cancelled) }
      XCTAssertEqual(model.nativeRecovery.attempts.count, 1)
      model.isUserPaused = true
      model.nativePositionIntent = UUID()
      continuation?.resume(returning: StreamPlayback(master: URL(string: "https://example.invalid/new.m3u8")!, qualities: []))
      await model.nativeRefreshTask?.value
      XCTAssertNil(model.nativeFallbackReason)
      XCTAssertTrue(model.isUserPaused)
      XCTAssertEqual(model.player.rate, 0)
    }
  }

  func testCancelledRetryCannotResurrectDismissedPlayback() async throws {
    try await withModel { model, view in
      var continuation: CheckedContinuation<StreamPlayback, Never>?
      view.recoverNativeHLS(.timeout) {
        await withCheckedContinuation { continuation = $0 }
      }
      for _ in 0..<100 {
        if continuation != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertNotNil(continuation)
      view.replacePlaybackItem(with: nil)
      continuation?.resume(returning: StreamPlayback(master: URL(string: "https://example.invalid/stale.m3u8")!, qualities: []))
      await model.nativeRefreshTask?.value
      XCTAssertNil(model.player.currentItem)
      XCTAssertNil(model.nativeHLS)
      XCTAssertFalse(model.isUsingNativeHLS)
    }
  }

  func testStartupWaitAcceptsPausedNativeReplacementWithoutRetryingOrPlaying() async {
    await withModel { model, view in
      let item = PausedReadyNativeItem(url: URL(fileURLWithPath: "/nonexistent-paused-native.m3u8"))
      model.nativeNeedsRefresh = true
      model.nativeRefreshTask = Task { @MainActor in
        model.player.replaceCurrentItem(with: item)
        model.nativeNeedsRefresh = false
      }
      let started = await view.waitForPlaybackStart()
      XCTAssertTrue(started)
      XCTAssertTrue(model.player.currentItem === item)
      XCTAssertEqual(model.player.rate, 0)
      XCTAssertNil(model.nativeFallbackReason)
    }
  }

  func testUnsupportedAndRepeatedFailuresStillPermitExplicitFallback() async {
    await withModel { model, view in
      XCTAssertTrue(model.nativeRecovery.takeRetry(for: .unavailable))
      XCTAssertTrue(model.nativeRecovery.takeRetry(for: .timeout))
      view.recoverNativeHLS(.unavailable) { XCTFail("Budget exhausted"); throw URLError(.cancelled) }
      XCTAssertFalse(model.isUsingNativeHLS)
      XCTAssertEqual(model.nativeFallbackReason, NativeHLSError.unavailable.rawValue)
    }

    await withModel { model, view in
      view.recoverNativeHLS(.transportCodec) { XCTFail("Unsupported codec"); throw URLError(.cancelled) }
      XCTAssertFalse(model.isUsingNativeHLS)
      XCTAssertEqual(model.nativeFallbackReason, NativeHLSError.transportCodec.rawValue)
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)
    }
  }
}

private final class PausedReadyNativeItem: AVPlayerItem, @unchecked Sendable {
  override var status: AVPlayerItem.Status { .readyToPlay }
}
