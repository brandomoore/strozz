import AVKit
import Observation
import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileVODPlaybackTests: XCTestCase {
  func testOptInBroadcastRendersAndResumesAfterReopening() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_VOD_TESTS"] == "1",
      let login = ProcessInfo.processInfo.environment["STROZZ_MOBILE_VOD_CHANNEL"] else {
      throw XCTSkip("Set STROZZ_MOBILE_VOD_TESTS=1 and STROZZ_MOBILE_VOD_CHANNEL for live VOD verification.")
    }
    let content = await ChannelContentService.load(login: login)
    let video = try XCTUnwrap(content?.videos.first { $0.lengthSeconds > 300 })
    let selection = MobileVODSelection(video: video, channel: .init(login: login))
    let suite = "MobileVODPlayback.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let progress = MobileVODProgressStore(accountID: "fixture", defaults: defaults)
    progress.save(selection, seconds: 60, duration: Double(video.lengthSeconds))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let lifecycle = VODTestScene()
    let first = UIHostingController(rootView: VODTestHost(selection: selection, progress: progress, lifecycle: lifecycle))
    window.rootViewController = first
    let firstPlayer = try await waitForVideo(in: first)
    XCTAssertTrue(firstPlayer.isMuted)
    XCTAssertGreaterThanOrEqual(firstPlayer.currentTime().seconds, 59)
    XCTAssertLessThan(firstPlayer.currentTime().seconds, 90)
    let item = try XCTUnwrap(firstPlayer.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    var frames = 0
    for _ in 0..<10 {
      try await Task.sleep(for: .seconds(1))
      if output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil { frames += 1 }
    }
    XCTAssertGreaterThanOrEqual(frames, 9)
    lifecycle.phase = .background
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(firstPlayer.rate, 0, "Backgrounding must pause VOD playback")
    XCTAssertGreaterThan(progress.progress(for: video.id), 65)
    lifecycle.phase = .active
    _ = try await waitForVideo(in: first)
    window.rootViewController = previous
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(firstPlayer.rate, 0)
    let saved = progress.progress(for: video.id)
    XCTAssertGreaterThan(saved, 65)
    let second = UIHostingController(rootView: VODTestHost(selection: selection, progress: progress, lifecycle: lifecycle))
    window.rootViewController = second
    let secondPlayer = try await waitForVideo(in: second)
    XCTAssertGreaterThanOrEqual(secondPlayer.currentTime().seconds, saved - 1)
    XCTAssertLessThan(secondPlayer.currentTime().seconds, saved + 10)
  }

  @MainActor
  @Observable
  final class VODTestScene {
    var phase = ScenePhase.active
  }

  private struct VODTestHost: View {
    let selection: MobileVODSelection
    let progress: MobileVODProgressStore
    let lifecycle: VODTestScene

    var body: some View {
      MobileVODPlayerView(selection: selection).environment(progress).environment(\.scenePhase, lifecycle.phase)
    }
  }

  private func waitForVideo(in controller: UIViewController) async throws -> AVPlayer {
    for _ in 0..<450 {
      if let video = videoController(in: controller), video.isReadyForDisplay,
        let player = video.player, player.timeControlStatus == .playing { return player }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("The broadcast must render and resume, not just resolve a URL")
    if let controller = videoController(in: controller), let player = controller.player {
      let evidence = XCTAttachment(string: "ready=\(controller.isReadyForDisplay) status=\(player.timeControlStatus.rawValue) clock=\(player.currentTime().seconds) item=\(String(describing: player.currentItem?.status))")
      evidence.lifetime = .keepAlways
      add(evidence)
    }
    throw URLError(.timedOut)
  }

  private func videoController(in controller: UIViewController) -> AVPlayerViewController? {
    if let video = controller as? AVPlayerViewController { return video }
    return controller.children.lazy.compactMap { self.videoController(in: $0) }.first
  }
}
