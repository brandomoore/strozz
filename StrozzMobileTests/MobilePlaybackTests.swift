import AVFoundation
import XCTest
@testable import StrozzMobile

@MainActor
final class MobilePlaybackTests: XCTestCase {
  func testResponsiveLayouts() {
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 390, height: 780), isPhone: true, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 780, height: 390), isPhone: true, hideChat: false, phoneLandscape: true), .videoOnly)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 390, height: 300), isPhone: true, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 834, height: 1194), isPhone: false, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 1024, height: 740), isPhone: false, hideChat: false), .sideBySide)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 400, height: 1000), isPhone: false, hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: CGSize(width: 1024, height: 740), isPhone: false, hideChat: true), .videoOnly)
  }

  func testQualitySelectionDoesNotSilentlyReplaceMissingQualityWithAuto() {
    let master = URL(string: "https://example.com/master.m3u8")!
    let video = URL(string: "https://example.com/video.m3u8")!
    let playback = StreamPlayback(master: master, qualities: [
      StreamQuality(id: "source", name: "Source", url: video, isAudioOnly: false, bitrate: 1000)
    ])
    XCTAssertEqual(MobileQuality.native.source(in: playback), master)
    XCTAssertEqual(MobileQuality.automatic.source(in: playback), master)
    XCTAssertEqual(MobileQuality.fixed("source").source(in: playback), video)
    XCTAssertNil(MobileQuality.fixed("missing").source(in: playback))
  }

  func testDecodeRecoveryChoosesVideoAndNeverLoopsOnSource() {
    let url = URL(string: "https://example.com/video.m3u8")!
    let source = StreamQuality(id: "source", name: "Source", url: url, isAudioOnly: false, bitrate: 5000)
    let lower = StreamQuality(id: "lower", name: "Low", url: url, isAudioOnly: false, bitrate: 1000)
    let audio = StreamQuality(id: "audio", name: "Audio", url: url, isAudioOnly: true, bitrate: 9999)
    XCTAssertEqual(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, audio, source], selection: .native), source)
    XCTAssertEqual(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, source], selection: .automatic), source)
    XCTAssertNil(MobilePlaybackModel.decodeRecoveryQuality(in: [lower, source], selection: .fixed(source.id)))
    XCTAssertNil(MobilePlaybackModel.decodeRecoveryQuality(in: [audio], selection: .native))
  }

  func testStoppedLoadCannotResurrectPlayer() async {
    let gate = ResolutionGate()
    let model = MobilePlaybackModel { _ in await gate.wait() }
    model.start(channel: "test")
    await gate.waitUntilRequested()
    model.stop()
    gate.finish()
    await Task.yield()
    XCTAssertFalse(model.isActive)
    XCTAssertNil(model.player.currentItem)
    XCTAssertFalse(model.isLoading)
  }

  func testBackgroundInvalidatesResolveAndForegroundResolvesAgain() async {
    let gate = ResolutionGate()
    var calls = 0
    let model = MobilePlaybackModel { _ in
      calls += 1
      return await gate.wait()
    }
    model.start(channel: "test")
    await gate.waitUntilRequested()
    model.suspend()
    gate.finish()
    await Task.yield()
    XCTAssertNil(model.player.currentItem)
    model.resume()
    await gate.waitUntilRequested()
    XCTAssertEqual(calls, 2)
    model.stop()
    gate.finish()
  }
}

@MainActor
private final class ResolutionGate {
  private var pending: CheckedContinuation<StreamPlayback, Never>?

  func wait() async -> StreamPlayback {
    await withCheckedContinuation { pending = $0 }
  }

  func waitUntilRequested() async {
    while pending == nil { await Task.yield() }
  }

  func finish() {
    pending?.resume(returning: StreamPlayback(
      master: URL(string: "https://example.com/live.m3u8")!, qualities: []))
    pending = nil
  }
}
