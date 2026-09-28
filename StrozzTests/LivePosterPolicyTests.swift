import XCTest

@testable import Strozz

final class LivePosterPolicyTests: XCTestCase {
  func testLivePosterGetsDistinctURLForEachLoad() {
    let source = URL(
      string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg"
    )!
    let first = LiveThumbnailPolicy.loadingPosterURL(from: source, token: "first")
    let reopened = LiveThumbnailPolicy.loadingPosterURL(from: source, token: "reopened")

    XCTAssertEqual(
      first?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg?cb=first"
    )
    XCTAssertEqual(
      reopened?.absoluteString,
      "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg?cb=reopened"
    )
    XCTAssertNotEqual(first, reopened)
  }

  func testStaticPostersKeepTheirCachedURL() {
    let vod = URL(string: "https://static-cdn.jtvnw.net/ttv-boxart/example-640x360.jpg")!
    let youtube = URL(string: "https://i.ytimg.com/vi/example/hqdefault.jpg")!

    XCTAssertEqual(LiveThumbnailPolicy.loadingPosterURL(from: vod, token: "new"), vod)
    XCTAssertEqual(LiveThumbnailPolicy.loadingPosterURL(from: youtube, token: "new"), youtube)
    XCTAssertNil(LiveThumbnailPolicy.loadingPosterURL(from: nil, token: "new"))
  }
}
