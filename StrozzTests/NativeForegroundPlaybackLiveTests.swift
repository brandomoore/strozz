import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class NativeForegroundPlaybackLiveTests: XCTestCase {
  func testOptInForegroundRecreatesAudioOwnerAndPreservesPausedPosition() async throws {
    #if targetEnvironment(simulator)
    guard ProcessInfo.processInfo.environment["STROZZ_NATIVE_FOREGROUND_PROBE"] == "1",
      let channel = ProcessInfo.processInfo.environment["STROZZ_CATCH_UP_LIVE_CHANNEL"] else {
      throw XCTSkip("Set STROZZ_NATIVE_FOREGROUND_PROBE=1 and a live channel for foreground verification.")
    }
    let environment = AppEnvironment()
    let model = PlayerModel()
    model.player.isMuted = true
    let suite = "NativeForeground.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    defer { defaults.removePersistentDomain(forName: suite) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let view = PlayerView(channel: channel, auth: environment.auth, model: model)
    let host = UIHostingController(rootView: view.environment(environment).defaultAppStorage(defaults))
    window.rootViewController = host
    defer {
      window.rootViewController = previous
      model.nativeRefreshTask?.cancel()
      view.cancelNativeStartup()
      view.stopLatencyMonitor()
      view.stopPlaybackWatchdog()
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
    }
    try await waitForPlayback(model)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    XCTAssertEqual(AVAudioSession.sharedInstance().mode, .moviePlayback)
    let firstPlayer = model.player
    let firstSurface = try XCTUnwrap(videoController(in: host))
    view.suspendNativePlayback(reason: "foreground_probe")
    view.refreshNativeAfterSuspension()
    await model.nativeRefreshTask?.value
    try await waitForPlayback(model)
    XCTAssertFalse(model.player === firstPlayer)
    XCTAssertNil(firstPlayer.currentItem)
    XCTAssertEqual(firstPlayer.rate, 0)
    XCTAssertTrue(model.player.isMuted, "A player replacement must not unmute the simulator")
    let secondSurface = try XCTUnwrap(videoController(in: host))
    XCTAssertFalse(firstSurface === secondSurface, "The AVKit rendering owner must also be recreated")
    XCTAssertTrue(secondSurface.player === model.player)
    let item = try XCTUnwrap(model.player.currentItem)
    XCTAssertGreaterThan(item.tracks.filter { $0.assetTrack?.mediaType == .audio && $0.isEnabled }.count, 0)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    var frames = 0
    for _ in 0..<5 {
      try await Task.sleep(for: .seconds(1))
      if output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil { frames += 1 }
    }
    XCTAssertGreaterThanOrEqual(frames, 4)

    let preResetPlayer = model.player
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
    for _ in 0..<50 {
      if model.mediaServicesUnavailable { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(model.mediaServicesUnavailable)
    XCTAssertEqual(model.player.rate, 0)
    // Simulate the session defaults being lost, without resetting the host's media service.
    try AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default)
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    try await waitForPlayback(model)
    XCTAssertFalse(model.player === preResetPlayer)
    XCTAssertNil(preResetPlayer.currentItem)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    XCTAssertEqual(AVAudioSession.sharedInstance().mode, .moviePlayback)
    XCTAssertTrue(model.player.isMuted)
    let resetSurface = try XCTUnwrap(videoController(in: host))
    XCTAssertFalse(resetSurface === secondSurface)
    XCTAssertTrue(resetSurface.player === model.player)
    XCTAssertGreaterThan(try XCTUnwrap(model.player.currentItem).tracks
      .filter { $0.assetTrack?.mediaType == .audio && $0.isEnabled }.count, 0)
    XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)

    view.toggleRewindPlayPause()
    let pausedDate = try XCTUnwrap(model.player.currentItem?.currentDate())
    let secondPlayer = model.player
    view.suspendNativePlayback(reason: "paused_foreground_probe")
    XCTAssertEqual(try XCTUnwrap(model.nativeResumePosition).timeIntervalSince(pausedDate), 0, accuracy: 0.1)
    view.refreshNativeAfterSuspension()
    await model.nativeRefreshTask?.value
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.player === secondPlayer)
    XCTAssertNil(secondPlayer.currentItem)
    XCTAssertTrue(model.isUserPaused)
    XCTAssertEqual(model.player.rate, 0)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertTrue(model.isUsingNativeHLS)
    let restoredDate = try XCTUnwrap(model.player.currentItem?.currentDate())
    XCTAssertEqual(restoredDate.timeIntervalSince(pausedDate), 0, accuracy: 1)
    XCTAssertTrue(model.nativeRecovery.attempts.isEmpty)
    let pausedPlayer = model.player
    view.handleMediaServicesReset()
    await model.nativeRefreshTask?.value
    XCTAssertFalse(model.player === pausedPlayer)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertTrue(model.isUserPaused)
    XCTAssertEqual(model.player.rate, 0)
    XCTAssertEqual(try XCTUnwrap(model.player.currentItem?.currentDate()).timeIntervalSince(restoredDate),
      0, accuracy: 1)
    XCTAssertNil(model.errorMessage)
    #else
    throw XCTSkip("Only run this foreground probe on an owned simulator.")
    #endif
  }

  private func waitForPlayback(_ model: PlayerModel) async throws {
    for _ in 0..<250 {
      if let error = model.errorMessage { XCTFail(error); throw URLError(.cannotDecodeContentData) }
      if model.nativeStartupComplete, model.player.timeControlStatus == .playing,
        model.playbackTelemetry.videoFrameAge.map({ $0 < 3 }) == true { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Native playback did not resume with fresh video")
    throw URLError(.timedOut)
  }

  private func videoController(in controller: UIViewController) -> AVPlayerViewController? {
    if let video = controller as? AVPlayerViewController { return video }
    for child in controller.children {
      if let video = videoController(in: child) { return video }
    }
    return nil
  }
}
