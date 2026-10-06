import AVFoundation
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileHomePreviewTests: XCTestCase {
  private let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)

  func testNearestMostlyVisibleCardWinsAndOffscreenCardsCannotPlay() {
    let frames = [
      "first": CGRect(x: 0, y: 30, width: 400, height: 225),
      "middle": CGRect(x: 0, y: 300, width: 400, height: 225),
      "partial": CGRect(x: 0, y: 700, width: 400, height: 225),
      "gone": CGRect(x: 0, y: -400, width: 400, height: 225)
    ]
    XCTAssertEqual(MobilePreviewSelection.channel(frames: frames, viewport: viewport), "middle")
    XCTAssertNil(MobilePreviewSelection.channel(frames: ["partial": frames["partial"]!], viewport: viewport))
    XCTAssertNil(MobilePreviewSelection.channel(frames: frames, viewport: .zero))
  }

  func testIPadRowUsesExactlyOneStableCard() {
    let frames = [
      "left": CGRect(x: 10, y: 300, width: 300, height: 170),
      "right": CGRect(x: 330, y: 300, width: 300, height: 170)
    ]
    XCTAssertEqual(MobilePreviewSelection.channel(
      frames: frames, viewport: CGRect(x: 0, y: 0, width: 700, height: 800)), "left")
  }

  func testStopInvalidatesPendingResolveAndNeverStartsOffscreenPlayback() async throws {
    var continuation: CheckedContinuation<URL, Never>?
    let model = MobileHomePreview { _ in await withCheckedContinuation { continuation = $0 } }
    model.updateViewport(viewport)
    model.updateFrame(CGRect(x: 0, y: 300, width: 400, height: 225), for: "first")
    XCTAssertNil(model.channel)
    model.setEnabled(true)
    for _ in 0..<100 {
      if continuation != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(continuation)
    model.stop()
    continuation?.resume(returning: URL(string: "https://example.com/video.m3u8")!)
    await Task.yield()
    XCTAssertNil(model.channel)
    XCTAssertNil(model.player.currentItem)
    XCTAssertEqual(model.player.rate, 0)
    XCTAssertTrue(model.player.isMuted)
  }

  func testScrollingCancelsFirstResolutionAndOnlyNewestCanOwnItem() async throws {
    var pending: [String: CheckedContinuation<URL, Never>] = [:]
    let model = MobileHomePreview { channel in
      await withCheckedContinuation { pending[channel] = $0 }
    }
    defer { model.stop() }
    model.updateViewport(viewport)
    model.updateFrame(CGRect(x: 0, y: 300, width: 400, height: 225), for: "first")
    model.setEnabled(true)
    try await Task.sleep(for: .milliseconds(450))
    model.updateFrame(nil, for: "first")
    model.updateFrame(CGRect(x: 0, y: 300, width: 400, height: 225), for: "second")
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(model.channel, "second")
    XCTAssertNotNil(pending["first"])
    XCTAssertNotNil(pending["second"])
    pending["first"]?.resume(returning: URL(string: "https://example.com/first.m3u8")!)
    await Task.yield()
    XCTAssertNil(model.player.currentItem)
    model.stop()
    pending["second"]?.resume(returning: URL(string: "https://example.com/second.m3u8")!)
    await Task.yield()
    XCTAssertNil(model.player.currentItem)
    XCTAssertTrue(model.player.isMuted)
  }

  func testMuteControlUsesModelStateAndAirPlayLeavesNativeMode() {
    let model = MobilePlaybackModel(muted: true)
    XCTAssertTrue(model.isMuted)
    model.toggleMute()
    XCTAssertFalse(model.isMuted)
    model.toggleMute()
    XCTAssertTrue(model.player.isMuted)
    model.prepareForAirPlay()
    XCTAssertEqual(model.selection, .automatic)
    XCTAssertEqual(model.recoveryNotice, "AirPlay uses standard playback.")
  }
}
