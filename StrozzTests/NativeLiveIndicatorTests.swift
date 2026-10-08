import XCTest
@testable import Strozz

@MainActor
final class NativeLiveIndicatorTests: XCTestCase {
  func testNumericLatencyIncludesLiveCushionButNotSourceClockOffset() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.isUsingNativeHLS = true
    view.isPlaybackActive = true
    view.wallClockLatencySeconds = 54
    view.smoothedLatencySeconds = 54
    let date = Date(timeIntervalSince1970: 1000)
    let itemID = UUID()
    for delay in [1.7, 4.2, 2.6, 0] {
      model.chatSyncBaseline.observe(context: "fixture", itemID: itemID,
        playbackDate: date, playbackTime: 0, liveTarget: date.addingTimeInterval(delay - 1.5),
        liveEdge: date.addingTimeInterval(delay), canCalibrate: false,
        now: date.addingTimeInterval(54), uptime: 0)
      XCTAssertEqual(view.latencyLabel, view.formatLatencySeconds(delay))
      XCTAssertNotEqual(view.latencyLabel, "Live", "A numeric reading must not disappear near live")
    }
    XCTAssertEqual(view.formatLatencySeconds(3.18), "3.18s")
    XCTAssertEqual(view.rawLatencySeconds, 54, "Keep the source-clock evidence in diagnostics")
  }

  func testUnverifiedRelativeTimingDoesNotClaimLiveFromAnOldSourceTimestamp() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.isUsingNativeHLS = true
    view.isPlaybackActive = true
    view.wallClockLatencySeconds = 54
    XCTAssertEqual(view.latencyLabel, "Checking live")
    model.nativeLivePosition.observe(extraDelay: .nan)
    XCTAssertEqual(view.latencyLabel, "Checking live")
  }

  func testInvalidDateMappingAndItemReplacementClearNumericLatency() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.isUsingNativeHLS = true
    view.isPlaybackActive = true
    let date = Date(timeIntervalSince1970: 1000)
    let itemID = UUID()
    model.chatSyncBaseline.observe(context: "fixture", itemID: itemID,
      playbackDate: date, playbackTime: 0, liveTarget: date,
      liveEdge: date.addingTimeInterval(3.18), canCalibrate: false, now: date, uptime: 0)
    XCTAssertEqual(view.latencyLabel, "3.18s")
    model.chatSyncBaseline.observe(context: "fixture", itemID: itemID,
      playbackDate: date.addingTimeInterval(30), playbackTime: 1, liveTarget: date,
      liveEdge: date.addingTimeInterval(31), canCalibrate: false, now: date, uptime: 1)
    XCTAssertEqual(view.latencyLabel, "Checking live")
    model.chatSyncBaseline.itemChanged()
    XCTAssertNil(model.chatSyncBaseline.liveEdgeDelay)
  }

  func testLiveEdgeIsPublishedMediaEndNotThePlaybackTarget() async throws {
    let url = URL(string: "https://example.test/live.m3u8")!
    let date = Date(timeIntervalSince1970: 1000)
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let origin = NativeHLSOrigin(root: url, headers: [:], history: 30) { _ in }
    let segment = NativeHLSOrigin.Segment(sequence: 1, url: url, date: date,
      discontinuity: 0, tags: [], parts: Array(repeating: part, count: 5), complete: true)
    _ = try await origin.renderForTesting([segment], readyToServe: true)
    let edge = await origin.liveEdgeDate()
    let target = await origin.liveTargetDate()
    XCTAssertEqual(try XCTUnwrap(edge).timeIntervalSince(date), 1.6, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(edge).timeIntervalSince(XCTUnwrap(target)), 1.5, accuracy: 0.0001)
    await origin.stop()
  }
}
