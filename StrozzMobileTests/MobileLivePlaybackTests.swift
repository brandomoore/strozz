import AVFoundation
import AVKit
import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileLivePlaybackTests: XCTestCase {
  func testOptInNativeFramesQualityAndForeground() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_LIVE_TESTS=1 for bounded live playback.")
    }
    guard let login = ProcessInfo.processInfo.environment["STROZZ_MOBILE_LIVE_CHANNEL"] else {
      throw XCTSkip("Select a live channel with STROZZ_MOBILE_LIVE_CHANNEL for native playback assertions.")
    }
    let search = SearchService()
    await search.search(login)
    let channel = try XCTUnwrap(search.channelResults.first { $0.login == login && $0.isLive })
    let model = MobilePlaybackModel(muted: true)
    model.select(.automatic)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previousController = window.rootViewController
    window.rootViewController = UIHostingController(rootView:
      MobilePlayerView(channel: channel, model: model)
        .environment(TwitchAuthSession()).environment(ThemeManager()).environment(TwitchWatchRewardsSession()))
    defer {
      window.rootViewController = previousController
      model.stop()
    }
    try await waitForPlayback(model)
    for _ in 0..<100 {
      if model.isReadyForDisplay { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(model.isReadyForDisplay, "Standard HLS must render in AVKit")
    model.select(.native)
    try await waitForPlayback(model)
    for _ in 0..<100 {
      if model.isReadyForDisplay { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    if !model.isReadyForDisplay {
      let description = describe(window.rootViewController, model: model)
      let diagnostics = XCTAttachment(string: description)
      diagnostics.name = "Video surface diagnostics"
      diagnostics.lifetime = .keepAlways
      add(diagnostics)
      XCTFail("The on-screen AVKit surface must display video, not merely decode frames")
      throw NSError(domain: "MobileLivePlaybackTests", code: 3)
    }
    XCTAssertTrue(model.isReadyForDisplay, "The on-screen AVKit surface must display video, not merely decode frames")
    // Source-quality decode recovery is still native playback. Verify the
    // actual engine, not the Auto/fixed label in the quality menu.
    XCTAssertTrue(model.requestsNativePlayback)
    XCTAssertNil(model.nativeFailure)
    XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url.scheme, NativeLowLatencyHLS.scheme)
    if model.selection != .native {
      let source = try XCTUnwrap(model.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate })
      XCTAssertEqual(model.selection, .fixed(source.id))
      XCTAssertNotNil(model.recoveryNotice, "A decode-quality change must be disclosed")
    }
    let originalPlayer = model.player
    let originalSurface = try XCTUnwrap(videoController(in: window.rootViewController))
    model.player.volume = 0.35
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification, object: nil)
    XCTAssertEqual(model.player.rate, 0)
    try AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default)
    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    try await waitForPlayback(model)
    for _ in 0..<100 {
      if model.isReadyForDisplay { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(model.isReadyForDisplay)
    XCTAssertFalse(model.player === originalPlayer)
    XCTAssertNil(originalPlayer.currentItem)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
    XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    XCTAssertEqual(AVAudioSession.sharedInstance().mode, .moviePlayback)
    XCTAssertFalse(try XCTUnwrap(videoController(in: window.rootViewController)) === originalSurface)
    let item = try XCTUnwrap(model.player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    var advancing = 0
    var frames = 0
    var previous = model.player.currentTime().seconds
    for second in 0..<60 {
      try await Task.sleep(for: .seconds(1))
      if second == 15 { item.preferredPeakBitRate = 1_500_000 }
      if second == 30 { item.preferredPeakBitRate = 0 }
      let clock = model.player.currentTime()
      if clock.seconds > previous + 0.1 { advancing += 1 }
      if output.copyPixelBuffer(forItemTime: clock, itemTimeForDisplay: nil) != nil { frames += 1 }
      previous = clock.seconds
    }
    XCTAssertNil(model.errorMessage)
    XCTAssertNil(model.nativeFailure)
    XCTAssertGreaterThanOrEqual(advancing, 55)
    XCTAssertGreaterThanOrEqual(frames, 55, "Clock movement is not proof of decoded video")
    XCTAssertEqual(model.liveStatus, .live, "Normal delivery delay must not offer a jump to live")
    let fixed = try XCTUnwrap(model.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate })
    model.select(.fixed(fixed.id))
    try await waitForPlayback(model)
    XCTAssertTrue(model.requestsNativePlayback)
    XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url.scheme, NativeLowLatencyHLS.scheme)
    let fixedItem = try XCTUnwrap(model.player.currentItem)
    let fixedOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    fixedItem.add(fixedOutput)
    var fixedFrames = 0
    for _ in 0..<20 {
      try await Task.sleep(for: .seconds(1))
      if fixedOutput.copyPixelBuffer(forItemTime: fixedItem.currentTime(), itemTimeForDisplay: nil) != nil {
        fixedFrames += 1
      }
    }
    XCTAssertGreaterThanOrEqual(fixedFrames, 18)
    XCTAssertNil(model.nativeFailure)
    model.player.pause()
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(model.liveStatus, .paused)
    let pausedPlayer = model.player
    let pausedDate = try XCTUnwrap(model.player.currentItem?.currentDate())
    model.suspend()
    XCTAssertNil(model.player.currentItem)
    model.handleAudioInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
      AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
    ]))
    model.resume()
    try await waitForPlayback(model, shouldPlay: false)
    XCTAssertFalse(model.player === pausedPlayer)
    XCTAssertTrue(model.player.isMuted)
    XCTAssertEqual(model.player.volume, 0.35, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(model.player.currentItem?.currentDate()).timeIntervalSince(pausedDate), 0, accuracy: 1)
    XCTAssertEqual(model.player.timeControlStatus, .paused)
    XCTAssertEqual(model.selection, .fixed(fixed.id))
    XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url.scheme, NativeLowLatencyHLS.scheme)
    let resumedPausedPlayer = model.player
    model.handleMediaServicesReset()
    try await waitForPlayback(model, shouldPlay: false)
    XCTAssertFalse(model.player === resumedPausedPlayer)
    XCTAssertEqual(model.player.rate, 0)
    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(try XCTUnwrap(model.player.currentItem?.currentDate()).timeIntervalSince(pausedDate), 0, accuracy: 1)
    model.goLive()
    try await waitForPlayback(model)
    model.select(.automatic)
    try await waitForPlayback(model)
    XCTAssertEqual(model.selection, .automatic)
    let evidence = XCTAttachment(string: "channel=\(channel.login) advancing=\(advancing)/60 frames=\(frames)/60")
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func describe(_ controller: UIViewController?, model: MobilePlaybackModel) -> String {
    guard let controller else { return "No controller" }
    var text = "\(type(of: controller)) bounds=\(controller.view.bounds) window=\(controller.view.window != nil)\n"
    if let video = controller as? AVPlayerViewController {
      text += "samePlayer=\(video.player === model.player) ready=\(video.isReadyForDisplay) rate=\(video.player?.rate ?? -1) clock=\(video.player?.currentTime().seconds ?? -1) item=\(String(describing: video.player?.currentItem?.status)) presentation=\(String(describing: video.player?.currentItem?.presentationSize)) bitrate=\(video.player?.currentItem?.accessLog()?.events.last?.indicatedBitrate ?? -1)\n"
    }

    return text + controller.children.map { describe($0, model: model) }.joined()
  }

  private func videoController(in controller: UIViewController?) -> AVPlayerViewController? {
    guard let controller else { return nil }
    if let video = controller as? AVPlayerViewController { return video }
    return controller.children.lazy.compactMap { self.videoController(in: $0) }.first
  }

  private func waitForPlayback(_ model: MobilePlaybackModel, shouldPlay: Bool = true) async throws {
    for _ in 0..<450 {
      if let error = model.errorMessage {
        XCTFail(error)
        throw NSError(domain: "MobileLivePlaybackTests", code: 1)
      }
      if !model.isLoading, model.player.currentItem?.status == .readyToPlay,
         !shouldPlay || model.player.timeControlStatus == .playing { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Playback did not reach the requested state")
    throw NSError(domain: "MobileLivePlaybackTests", code: 2)
  }
}
