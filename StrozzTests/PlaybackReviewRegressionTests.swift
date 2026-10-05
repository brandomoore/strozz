import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class PlaybackReviewRegressionTests: XCTestCase {
  func testLegacyAutoChoicesKeepTheSelectedYouTubeItem() throws {
    let defaults = UserDefaults.standard
    let keys = [PersistenceKey.preferredQuality, PersistenceKey.livePlaybackProfile]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    for selection in [LivePlaybackProfile.higherQuality, .lowerLatency] {
      defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
      defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
      let model = PlayerModel()
      let youtube = URL(fileURLWithPath: "/nonexistent-youtube-review.m3u8")
      model.playback = StreamPlayback(master: URL(fileURLWithPath: "/nonexistent-twitch-review.m3u8"), qualities: [])
      model.isUsingAltSource = true
      model.currentSourceURL = youtube
      let item = AVPlayerItem(url: youtube)
      model.player.replaceCurrentItem(with: item)
      defer { model.player.pause(); model.player.replaceCurrentItem(with: nil) }
      let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
      view.selectQuality(at: try XCTUnwrap(view.qualityOptions.firstIndex(of: selection.pickerLabel)))
      XCTAssertTrue(model.isUsingAltSource)
      XCTAssertEqual(model.currentSourceURL, youtube)
      XCTAssertTrue(model.player.currentItem === item)
      XCTAssertEqual(view.livePlaybackProfile, selection)
    }
  }

  func testFallbackResumeUsesCurrentPauseAndItemIntent() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-review.m3u8"))
    model.player.replaceCurrentItem(with: item)
    defer { model.player.replaceCurrentItem(with: nil) }
    let generation = model.nativeGeneration
    XCTAssertTrue(view.canResumeFallback(item: item, generation: generation))
    model.isUserPaused = true
    XCTAssertFalse(view.canResumeFallback(item: item, generation: generation))
    model.isUserPaused = false
    model.isScrubbing = true
    XCTAssertFalse(view.canResumeFallback(item: item, generation: generation))
    model.isScrubbing = false
    model.backgroundedAt = Date()
    XCTAssertFalse(view.canResumeFallback(item: item, generation: generation))
    model.backgroundedAt = nil
    XCTAssertFalse(view.canResumeFallback(item: item, generation: UUID()))
    model.player.replaceCurrentItem(with: nil)
    XCTAssertFalse(view.canResumeFallback(item: item, generation: generation))
  }

  func testSuspensionInvalidatesOldEngineWithoutLatchingFallback() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let engine = NativeLowLatencyHLS(sourceURL: URL(string: "https://example.invalid/master.m3u8")!,
      headers: [:], history: 30) { _ in XCTFail("Suspension is not a playback failure") }
    model.nativeHLS = engine
    model.isUsingNativeHLS = true
    let generation = model.nativeGeneration
    view.suspendNativePlayback()
    XCTAssertTrue(model.nativeNeedsRefresh)
    XCTAssertNil(model.nativeHLS)
    XCTAssertNotEqual(model.nativeGeneration, generation)
    view.fallbackFromNativeHLS(.unavailable)
    XCTAssertNil(model.nativeFallbackReason)
    XCTAssertTrue(model.nativeNeedsRefresh)
  }

  func testResumeResolvesFreshMasterAndDoesNotReplayAnExpiredEngine() async throws {
    let defaults = UserDefaults.standard
    let keys = [PersistenceKey.preferredQuality, PersistenceKey.livePlaybackProfile]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let model = PlayerModel()
    model.activeChannel = "fixture"
    model.isUserPaused = true
    let oldURL = URL(string: "https://example.invalid/expired.m3u8")!
    let newURL = URL(string: "https://example.invalid/fresh.m3u8")!
    let engine = NativeLowLatencyHLS(sourceURL: oldURL, headers: [:], history: 30) { _ in }
    model.nativeHLS = engine
    model.currentSourceURL = oldURL
    model.isUsingNativeHLS = true
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    defer {
      model.nativeRefreshTask?.cancel()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
    }
    view.suspendNativePlayback()
    var resolutions = 0
    view.refreshNativeAfterSuspension {
      resolutions += 1
      return StreamPlayback(master: newURL, qualities: [])
    }
    await model.nativeRefreshTask?.value
    XCTAssertEqual(resolutions, 1)
    XCTAssertEqual(model.currentSourceURL, newURL)
    XCTAssertFalse(model.nativeHLS === engine)
    XCTAssertTrue(model.isUsingNativeHLS)
    XCTAssertFalse(model.nativeNeedsRefresh)
    XCTAssertNil(model.nativeFallbackReason)
    XCTAssertEqual(model.player.rate, 0, "A paused viewer must remain paused after refresh")
  }

  func testSupersededRestoreCannotSeekOrResumeAnotherItem() async {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-review.m3u8"))
    model.player.replaceCurrentItem(with: item)
    defer { model.player.replaceCurrentItem(with: nil) }
    let intent = model.nativePositionIntent
    model.nativePositionIntent = UUID()
    await view.restoreNativePosition(Date(), item: item, generation: model.nativeGeneration, intent: intent)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.player.rate, 0)
  }
}
