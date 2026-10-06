import AVFoundation
import os
import XCTest
@testable import Strozz

@MainActor
final class StandardPlaybackStabilityTests: XCTestCase {
  private func withPreferences(_ body: () async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let keys = [PersistenceKey.preferredQuality, PersistenceKey.livePlaybackProfile,
                PersistenceKey.lowLatencyProxyEnabled, PersistenceKey.streamRewindEnabled]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    defaults.set(false, forKey: PersistenceKey.lowLatencyProxyEnabled)
    defaults.set(true, forKey: PersistenceKey.streamRewindEnabled)
    try await body()
  }

  func testNativeFallbackHonorsDisabledLegacyPrefetchAndKeepsDVR() async throws {
    await withPreferences {
      let model = PlayerModel()
      model.nativeFallbackReason = NativeHLSError.unavailable.rawValue
      let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
      _ = view.makeItem(url: URL(string: "https://example.invalid/master.m3u8")!)
      await flush(model.lowLatencyProxy)
      XCTAssertFalse(model.isUsingNativeHLS)
      XCTAssertFalse(model.lowLatencyProxy.telemetrySnapshot.promotesPrefetch)
      XCTAssertTrue(model.lowLatencyProxy.telemetrySnapshot.retainsHistory)
      XCTAssertEqual(view.selectedQualityOption, LivePlaybackProfile.lowerLatency.pickerLabel)
    }
  }

  func testStabilityNeverReplaysTwentySecondsWhenSeekableEdgeLagsPlayhead() async throws {
    await withPreferences {
      let model = PlayerModel()
      let item = StabilityTrackingItem(url: URL(fileURLWithPath: "/nonexistent-stability.m3u8"))
      model.player.replaceCurrentItem(with: item)
      defer { model.player.pause(); model.player.replaceCurrentItem(with: nil) }
      let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
      view.enterStreamStabilityMode()
      await flush(model.lowLatencyProxy)
      XCTAssertTrue(view.isStreamUnstable)
      XCTAssertTrue(model.player.currentItem === item)
      XCTAssertEqual(item.seeks, 0)
      XCTAssertEqual(item.currentTime().seconds, 23.468, accuracy: 0.001)
      XCTAssertEqual(item.preferredForwardBufferDuration, LivePlaybackPolicy.stabilityFallback.preferredForwardBufferDuration)
      XCTAssertFalse(model.lowLatencyProxy.telemetrySnapshot.promotesPrefetch)
    }
  }

  func testEnabledLegacyProxyStopsPromotionWithoutReloadingTheItem() async throws {
    await withPreferences {
      UserDefaults.standard.set(true, forKey: PersistenceKey.lowLatencyProxyEnabled)
      let model = PlayerModel()
      let item = StabilityTrackingItem(url: URL(fileURLWithPath: "/nonexistent-stability.m3u8"))
      model.player.replaceCurrentItem(with: item)
      defer { model.player.pause(); model.player.replaceCurrentItem(with: nil) }
      model.lowLatencyProxy.configure(promotePrefetch: true, retainHistory: true, windowSeconds: 300)
      let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
      view.enterStreamStabilityMode()
      await flush(model.lowLatencyProxy)
      await Task.yield()
      XCTAssertTrue(model.player.currentItem === item)
      XCTAssertEqual(item.seeks, 0)
      XCTAssertFalse(model.lowLatencyProxy.telemetrySnapshot.promotesPrefetch)
      XCTAssertTrue(model.lowLatencyProxy.telemetrySnapshot.retainsHistory)
    }
  }

  func testStabilityIgnoresPausedScrubbingBackgroundAndNativePlayback() async throws {
    await withPreferences {
      for state in 0..<5 {
        let model = PlayerModel()
        switch state {
        case 0: model.isUserPaused = true
        case 1: model.isScrubbing = true
        case 2: model.backgroundedAt = Date()
        case 3: model.isUsingNativeHLS = true
        default: model.isUsingAltSource = true
        }
        let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
        view.enterStreamStabilityMode()
        XCTAssertFalse(view.isStreamUnstable)
        XCTAssertEqual(model.player.rate, 0)
      }
    }
  }

  private func flush(_ proxy: LowLatencyHLSProxy) async {
    await withCheckedContinuation { continuation in
      proxy.callbackQueue.async { continuation.resume() }
    }
  }
}

private final class StabilityTrackingItem: AVPlayerItem, @unchecked Sendable {
  private nonisolated let count = OSAllocatedUnfairLock(initialState: 0)
  var seeks: Int { count.withLock { $0 } }
  override func currentTime() -> CMTime { CMTime(seconds: 23.468, preferredTimescale: 1000) }
  override var seekableTimeRanges: [NSValue] {
    [NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 22.061, preferredTimescale: 1000)))]
  }
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                     completionHandler: (@Sendable (Bool) -> Void)? = nil) {
    count.withLock { $0 += 1 }
    completionHandler?(true)
  }
}
