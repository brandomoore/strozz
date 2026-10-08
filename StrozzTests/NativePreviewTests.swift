import AVKit
import SwiftUI
import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class NativePreviewTests: XCTestCase {
  func testPreviewStartsMutedAndStopClearsItsState() {
    let preview = NativeLivePreview()
    XCTAssertTrue(preview.player.isMuted)
    XCTAssertFalse(preview.player.allowsExternalPlayback)
    preview.stop()
    XCTAssertNil(preview.player.currentItem)
    XCTAssertFalse(preview.isReady)
    XCTAssertFalse(preview.isNative)
  }

  func testStopBeforeScheduledStartCannotResurrectPreview() async {
    let preview = NativeLivePreview()
    preview.start(url: URL(string: "https://example.invalid/preview.m3u8")!) { _ in
      XCTFail("A cancelled preview must not refresh")
      throw CancellationError()
    }
    preview.stop()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertNil(preview.player.currentItem)
    XCTAssertFalse(preview.isReady)
    XCTAssertFalse(preview.isNative)
    XCTAssertTrue(preview.player.isMuted)
  }

  func testOptInMutedPreviewUsesNativeLiveParts() async throws {
    #if targetEnvironment(simulator)
    let environment = ProcessInfo.processInfo.environment
    guard environment["STROZZ_PREVIEW_LIVE_TESTS"] == "1",
      let login = environment["STROZZ_PREVIEW_CHANNEL"] else {
      throw XCTSkip("Enable STROZZ_PREVIEW_LIVE_TESTS and select a live preview channel.")
    }
    let url = try await PlaybackService.previewHLSURL(for: login)
    let preview = NativeLivePreview()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIViewController()
    let layer = AVPlayerLayer(player: preview.player)
    layer.frame = window.bounds
    host.view.layer.addSublayer(layer)
    window.rootViewController = host
    defer {
      preview.stop()
      layer.player = nil
      window.rootViewController = previous
    }
    preview.start(url: url) { original in
      try await PlaybackService.pinnedHLSURL(for: login,
        targetBitrate: original ? 0 : 1_500_000, forceRefresh: true)
    }
    for _ in 0..<240 {
      if preview.isReady { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(preview.isReady)
    XCTAssertTrue(preview.isNative)
    XCTAssertNil(preview.fallbackReason)
    XCTAssertNil(preview.errorMessage)
    XCTAssertTrue(preview.player.isMuted)
    XCTAssertEqual((preview.player.currentItem?.asset as? AVURLAsset)?.url.scheme, NativeLowLatencyHLS.scheme)
    let start = preview.player.currentTime().seconds
    try await Task.sleep(for: .seconds(10))
    XCTAssertGreaterThan(preview.player.currentTime().seconds, start + 8)
    XCTAssertTrue(layer.isReadyForDisplay)
    XCTAssertTrue(preview.isReady)
    #else
    throw XCTSkip("Run preview verification on an owned simulator.")
    #endif
  }
}
