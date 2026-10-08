import XCTest
@testable import Strozz

@MainActor
final class NativeLiveIndicatorTests: XCTestCase {
  func testSourceClockOffsetDoesNotBecomeFiftySecondsOfPlayerLag() {
    let model = PlayerModel()
    let view = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: model)
    model.isUsingNativeHLS = true
    view.isPlaybackActive = true
    view.wallClockLatencySeconds = 54
    view.smoothedLatencySeconds = 54
    model.nativeLivePosition.observe(extraDelay: 0.2)
    XCTAssertEqual(view.latencyLabel, "Live")
    XCTAssertEqual(view.rawLatencySeconds, 54, "Keep the source-clock evidence in diagnostics")
    model.nativeLivePosition.observe(extraDelay: 4)
    XCTAssertEqual(view.latencyLabel, "~4.0s behind available live")
    model.nativeLivePosition.observe(extraDelay: 2.6)
    XCTAssertEqual(view.latencyLabel, "~3.0s behind available live")
    model.nativeLivePosition.observe(extraDelay: 1)
    XCTAssertEqual(view.latencyLabel, "Live")
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
}
