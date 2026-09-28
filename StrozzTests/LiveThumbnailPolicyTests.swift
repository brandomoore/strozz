import XCTest

@testable import Strozz

final class LiveThumbnailPolicyTests: XCTestCase {
  private let twitchPreview = URL(
    string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg"
  )!

  func testLivePosterUsesFreshURLAndFullPlayerResolution() {
    let first = LiveThumbnailPolicy.freshURL(
      from: twitchPreview, renderedWidth: 1440, scale: 1, token: "first",
      maxPixelWidth: 1920
    )
    let second = LiveThumbnailPolicy.freshURL(
      from: twitchPreview, renderedWidth: 1440, scale: 1, token: "second",
      maxPixelWidth: 1920
    )

    XCTAssertEqual(
      first?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-1920x1080.jpg?cb=first"
    )
    XCTAssertEqual(
      second?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-1920x1080.jpg?cb=second"
    )
    XCTAssertNotEqual(first, second)
  }

  func testStreamCardRequestsStayAtCardSize() {
    let card = LiveThumbnailPolicy.freshURL(
      from: twitchPreview, renderedWidth: 250, scale: 1, token: "card"
    )
    let capped = LiveThumbnailPolicy.freshURL(
      from: twitchPreview, renderedWidth: 1440, scale: 1, token: "large-card"
    )

    XCTAssertEqual(
      card?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-320x180.jpg?cb=card"
    )
    XCTAssertEqual(
      capped?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg?cb=large-card"
    )
  }

  func testOnlyTwitchLivePreviewGetsRefetched() {
    XCTAssertTrue(LiveThumbnailPolicy.isLivePreview(twitchPreview))
    XCTAssertFalse(LiveThumbnailPolicy.isLivePreview(URL(
      string: "https://i.ytimg.com/vi/example/hqdefault.jpg"
    )!))
    XCTAssertFalse(LiveThumbnailPolicy.isLivePreview(URL(
      string: "https://static-cdn.jtvnw.net/ttv-boxart/example-640x360.jpg"
    )!))
  }
}
