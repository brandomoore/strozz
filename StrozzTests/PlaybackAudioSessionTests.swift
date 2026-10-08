import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class PlaybackAudioSessionTests: XCTestCase {
  func testOnlyTheMediaServicesResetErrorBypassesSourceRetryPolicy() {
    XCTAssertTrue(PlaybackAudioSession.isMediaServicesReset(
      NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)))
    XCTAssertFalse(PlaybackAudioSession.isMediaServicesReset(
      NSError(domain: NSURLErrorDomain, code: AVError.mediaServicesWereReset.rawValue)))
    XCTAssertFalse(PlaybackAudioSession.isMediaServicesReset(URLError(.timedOut)))
    XCTAssertFalse(PlaybackAudioSession.isMediaServicesReset(nil))
  }

  func testPlaybackSessionUsesMoviePlaybackRatherThanAmbientAudio() throws {
    let session = AVAudioSession.sharedInstance()
    let category = session.category
    let mode = session.mode
    let options = session.categoryOptions
    defer {
      do {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(category, mode: mode, options: options)
      } catch { XCTFail("Audio session cleanup failed: \(error)") }
    }
    try session.setCategory(.soloAmbient, mode: .default)
    try PlaybackAudioSession.activate()
    XCTAssertEqual(session.category, .playback)
    XCTAssertEqual(session.mode, .moviePlayback)
    XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
    try session.setCategory(.soloAmbient, mode: .default)
    try PlaybackAudioSession.activate()
    XCTAssertEqual(session.category, .playback, "Reactivation must restore settings lost in a reset")
    XCTAssertEqual(session.mode, .moviePlayback)
  }

  func testStartAndResumeActivateAudioWithoutChangingMuteOrVolume() {
    let model = PlayerModel()
    model.player.isMuted = true
    model.player.volume = 0.35
    var activations = 0
    model.activateAudioSession = { activations += 1 }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    defer { model.player.pause() }
    view.startPlayback()
    XCTAssertEqual(activations, 1)
    view.resumePlayback()
    XCTAssertEqual(activations, 2)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
  }

  func testAudioActivationFailureStopsPlaybackAndSurfacesAnError() {
    let model = PlayerModel()
    model.player.isMuted = true
    model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    view.startPlayback()
    XCTAssertTrue(model.audioSessionActivationFailed)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.isLoading)
    XCTAssertEqual(model.player.rate, 0)
    XCTAssertFalse(view.shouldPlayAltSource)
    model.activateAudioSession = {}
    view.resumePlayback()
    XCTAssertFalse(model.audioSessionActivationFailed)
    XCTAssertNil(model.errorMessage)
    model.player.pause()
  }

  func testBackgroundAndIntentionalPauseCannotActivateAudio() {
    let model = PlayerModel()
    model.activateAudioSession = { XCTFail("Inactive playback must not take the audio session") }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.backgroundedAt = Date()
    view.startPlayback()
    view.resumePlayback()
    model.backgroundedAt = nil
    model.isUserPaused = true
    view.startPlayback()
    view.resumePlayback()
    XCTAssertEqual(model.player.rate, 0)
  }

  func testNativeStartupAudioFailureCanBeExplicitlyRetried() {
    let model = PlayerModel()
    model.isUsingNativeHLS = true
    model.player.isMuted = true
    model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    view.startPlayback()
    XCTAssertTrue(model.audioSessionActivationFailed)
    XCTAssertNotNil(model.errorMessage)
    model.activateAudioSession = {}
    view.resumePlayback()
    XCTAssertFalse(model.audioSessionActivationFailed)
    XCTAssertNil(model.errorMessage)
  }

  func testInterruptionBlocksRecoveryAndHonorsResumePermission() {
    let model = PlayerModel()
    model.player.isMuted = true
    var activations = 0
    model.activateAudioSession = { activations += 1 }
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    defer {
      model.player.pause()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
    }
    view.handleAudioInterruption(interruption(.began))
    XCTAssertFalse(view.shouldPlayAltSource)
    view.startPlayback()
    view.resumePlayback()
    XCTAssertEqual(activations, 0)
    view.handleAudioInterruption(interruption(.ended))
    XCTAssertTrue(model.isUserPaused, "Without shouldResume only the viewer can resume")
    XCTAssertEqual(activations, 0)

    model.isUserPaused = false
    view.handleAudioInterruption(interruption(.began))
    view.handleAudioInterruption(interruption(.ended, options: .shouldResume))
    XCTAssertFalse(model.audioInterrupted)
    XCTAssertFalse(model.isUserPaused)
    XCTAssertEqual(activations, 1)

    model.isUserPaused = true
    view.handleAudioInterruption(interruption(.began))
    view.handleAudioInterruption(interruption(.ended, options: .shouldResume))
    XCTAssertEqual(activations, 1, "An interruption must not undo a deliberate pause")
  }

  func testForegroundRechecksUnendedInterruptionWithoutUndoingUserPause() {
    for paused in [false, true] {
      let model = PlayerModel()
      model.player.isMuted = true
      model.isUserPaused = paused
      model.backgroundedAt = Date().addingTimeInterval(-600)
      model.audioInterrupted = true
      var activations = 0
      model.activateAudioSession = { activations += 1 }
      let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
      defer {
        model.channelMetadataTask?.cancel()
        view.stopLatencyMonitor()
        view.stopPlaybackWatchdog()
        model.player.pause()
      }
      view.handleReturnToForeground()
      XCTAssertFalse(model.audioInterrupted)
      XCTAssertNil(model.backgroundedAt)
      XCTAssertEqual(model.isUserPaused, paused)
      XCTAssertEqual(activations, paused ? 0 : 1)
    }
  }

  func testForegroundActivationFailureIsVisibleAndActiveInterruptionIsNotIgnored() {
    let model = PlayerModel()
    model.player.isMuted = true
    model.audioInterrupted = true
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    defer {
      model.channelMetadataTask?.cancel()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.player.pause()
    }
    view.handleReturnToForeground()
    XCTAssertTrue(model.audioInterrupted, "An active interruption still requires normal ended/user handling")
    model.backgroundedAt = Date().addingTimeInterval(-60)
    model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
    view.handleReturnToForeground()
    XCTAssertFalse(model.audioInterrupted)
    XCTAssertTrue(model.audioSessionActivationFailed)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.player.rate, 0)
  }

  func testMediaServiceLossDefersRecoveryUntilResetAndCoalescesDuplicates() async throws {
    try await withNative { model, view in
      let oldPlayer = model.player
      view.handleMediaServicesLost()
      XCTAssertTrue(model.mediaServicesUnavailable)
      XCTAssertTrue(model.mediaServicesResetPending)
      XCTAssertTrue(model.nativeNeedsRefresh)
      XCTAssertEqual(model.nativeRestartSerial, 1, "Startup must follow the replacement item, not retry the old one")
      XCTAssertNil(model.nativeRefreshTask)
      XCTAssertEqual(oldPlayer.rate, 0)
      var continuation: CheckedContinuation<StreamPlayback, Never>?
      view.handleMediaServicesReset {
        await withCheckedContinuation { continuation = $0 }
      }
      for _ in 0..<100 {
        if continuation != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertNotNil(continuation)
      view.handleMediaServicesReset {
        XCTFail("One reset must not start competing source loads")
        throw URLError(.cancelled)
      }
      continuation?.resume(returning: StreamPlayback(
        master: URL(string: "https://example.invalid/fresh.m3u8")!, qualities: []))
      await model.nativeRefreshTask?.value
      XCTAssertFalse(model.player === oldPlayer)
      XCTAssertNil(oldPlayer.currentItem)
      XCTAssertFalse(model.mediaServicesResetPending)
      XCTAssertTrue(model.isUsingNativeHLS)
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty, "A system reset is not a bad Twitch source")
      XCTAssertTrue(model.isUserPaused)
      XCTAssertEqual(model.player.rate, 0)
      XCTAssertTrue(model.player.isMuted)
      XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
    }
  }

  func testBackgroundResetWaitsForReturnAndDismissalCancelsIt() async {
    await withNative { model, view in
      let oldPlayer = model.player
      model.backgroundedAt = Date()
      view.suspendNativePlayback()
      view.handleMediaServicesReset {
        XCTFail("Do not resolve or acquire audio in the background")
        throw URLError(.cancelled)
      }
      XCTAssertTrue(model.player === oldPlayer)
      XCTAssertTrue(model.mediaServicesResetPending)
      XCTAssertNil(model.nativeRefreshTask)
      model.backgroundedAt = nil
      view.recoverMediaServicesIfNeeded {
        StreamPlayback(master: URL(string: "https://example.invalid/resumed.m3u8")!, qualities: [])
      }
      await model.nativeRefreshTask?.value
      XCTAssertFalse(model.player === oldPlayer)
      XCTAssertEqual(model.player.rate, 0)
      view.handleMediaServicesLost()
      view.replacePlaybackItem(with: nil)
      view.handleMediaServicesReset {
        XCTFail("A dismissed stream must not restart")
        throw URLError(.cancelled)
      }
      XCTAssertFalse(model.mediaServicesResetPending)
      XCTAssertNil(model.player.currentItem)
    }
  }

  func testResetDuringSourceRetryRecreatesPlayerWithoutAnotherRetry() async throws {
    try await withNative { model, view in
      let oldPlayer = model.player
      var continuation: CheckedContinuation<StreamPlayback, Never>?
      view.recoverNativeHLS(.unavailable) {
        await withCheckedContinuation { continuation = $0 }
      }
      for _ in 0..<100 {
        if continuation != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      view.handleMediaServicesReset {
        XCTFail("Use the pending fresh source")
        throw URLError(.cancelled)
      }
      continuation?.resume(returning: StreamPlayback(
        master: URL(string: "https://example.invalid/retry.m3u8")!, qualities: []))
      await model.nativeRefreshTask?.value
      XCTAssertFalse(model.player === oldPlayer)
      XCTAssertEqual(model.nativeRecovery.attempts.count, 1)
      XCTAssertNil(model.nativeFallbackReason)
      XCTAssertEqual(model.player.rate, 0)
    }
  }

  func testResetErrorRebuildsWithoutSpendingTheNativeSourceRetryBudget() async {
    await withNative { model, view in
      let failed = ResetFailedPlayer()
      failed.isMuted = true
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      model.player = failed
      failed.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-reset.m3u8")))
      view.recoverNativeHLS(.unavailable) {
        StreamPlayback(master: URL(string: "https://example.invalid/reset.m3u8")!, qualities: [])
      }
      await model.nativeRefreshTask?.value
      XCTAssertFalse(model.player === failed)
      XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)
      XCTAssertNil(model.nativeFallbackReason)
      XCTAssertTrue(model.player.isMuted)
    }
  }

  func testVODResetRecreatesTheSelectedSourceWithoutUnpausing() async {
    let model = PlayerModel()
    model.player.isMuted = true
    model.isUserPaused = true
    model.activateAudioSession = { XCTFail("A paused VOD must remain paused") }
    let url = URL(fileURLWithPath: "/nonexistent-vod-reset.m3u8")
    model.currentSourceURL = url
    model.player.replaceCurrentItem(with: AVPlayerItem(url: url))
    let oldPlayer = model.player
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(),
      vod: .init(id: "fixture", title: "Fixture"), model: model)
    defer {
      model.fallbackRestoreTask?.cancel()
      view.removeVODTimeObserver()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
    }
    view.handleMediaServicesReset()
    await model.fallbackRestoreTask?.value
    XCTAssertFalse(model.player === oldPlayer)
    XCTAssertNil(oldPlayer.currentItem)
    XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, url)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertTrue(model.isUserPaused)
    XCTAssertFalse(model.isUsingNativeHLS)
    XCTAssertFalse(model.isLoading)
    XCTAssertFalse(model.mediaServicesResetPending)
    XCTAssertEqual(model.player.rate, 0)
  }

  private func interruption(
    _ type: AVAudioSession.InterruptionType,
    options: AVAudioSession.InterruptionOptions = []
  ) -> Notification {
    Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: type.rawValue,
      AVAudioSessionInterruptionOptionKey: options.rawValue,
    ])
  }

  private final class ResetFailedPlayer: AVPlayer, @unchecked Sendable {
    override var status: AVPlayer.Status { .failed }
    override var error: Error? {
      NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue)
    }
  }

  private func withNative(_ body: (PlayerModel, PlayerView) async throws -> Void) async rethrows {
    let defaults = UserDefaults.standard
    let keys = [PersistenceKey.preferredQuality, PersistenceKey.livePlaybackProfile]
    let saved = keys.map { defaults.object(forKey: $0) }
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let model = PlayerModel()
    model.activeChannel = "fixture"
    model.isUserPaused = true
    model.player.isMuted = true
    model.player.volume = 0.35
    model.activateAudioSession = {}
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    let url = URL(string: "https://example.invalid/original.m3u8")!
    view.replacePlaybackItem(with: view.makeItem(url: url))
    defer {
      view.cancelNativeStartup()
      model.nativeRefreshTask?.cancel()
      model.fallbackRestoreTask?.cancel()
      model.nativeHLS?.stop()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    try await body(model, view)
  }
}
