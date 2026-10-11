import SwiftUI
import XCTest
@testable import StrozzMobile

final class MobileVideoZoomTests: XCTestCase {
  @MainActor
  func testRequestedPlayerGlyphsAreBundled() {
    for glyph in [Glyph.arrowsDiagonal2, .arrowsDiagonalMinimize, .messages, .messagesOff] {
      XCTAssertNotNil(UIImage(named: "tb-\(glyph.rawValue)"))
    }
  }

  func testZoomKeepsThePointUnderThePinchAndTracksItsMidpoint() {
    let size = CGSize(width: 400, height: 300)
    let anchor = CGPoint(x: 100, y: 75)
    let zoom = MobileVideoZoom().magnified(2, from: anchor, to: anchor, viewport: size, videoSize: size)
    XCTAssertEqual(zoom.scale, 2)
    XCTAssertEqual(zoom.offset, CGSize(width: 100, height: 75))
    XCTAssertEqual(200 + zoom.offset.width + (anchor.x - 200) * zoom.scale, anchor.x)
    XCTAssertEqual(150 + zoom.offset.height + (anchor.y - 150) * zoom.scale, anchor.y)
    let moved = zoom.magnified(1.5, from: anchor, to: CGPoint(x: 125, y: 90), viewport: size, videoSize: size)
    XCTAssertEqual(moved.scale, 3)
    XCTAssertEqual(moved.offset, CGSize(width: 225, height: 165))
  }

  func testZoomIsBoundedAndPinchingOutRestoresTheOriginalFrame() {
    let size = CGSize(width: 400, height: 300)
    let point = CGPoint(x: 200, y: 150)
    let maximum = MobileVideoZoom().magnified(100, from: point, to: point, viewport: size, videoSize: size)
    XCTAssertEqual(maximum.scale, MobileVideoZoom.maximumScale)
    let reset = maximum.magnified(0.01, from: point, to: CGPoint(x: 20, y: 20), viewport: size, videoSize: size)
    XCTAssertEqual(reset, MobileVideoZoom())
    XCTAssertEqual(MobileVideoZoom().panned(CGSize(width: 200, height: 300), viewport: size, videoSize: size),
                   MobileVideoZoom())
  }

  func testPanningCannotRevealSpaceBeyondTheVideoEdges() {
    let size = CGSize(width: 400, height: 300)
    let zoom = MobileVideoZoom(scale: 2)
    XCTAssertEqual(zoom.panned(CGSize(width: 1000, height: -1000), viewport: size, videoSize: size).offset,
                   CGSize(width: 200, height: -150))
    XCTAssertEqual(zoom.panned(CGSize(width: -1000, height: 1000), viewport: size, videoSize: size).offset,
                   CGSize(width: -200, height: 150))
  }

  func testLetterboxedAxesStayCenteredUntilTheVideoCoversTheViewport() {
    let landscape = CGSize(width: 600, height: 300)
    let video = CGSize(width: 1920, height: 1080)
    let zoom = MobileVideoZoom(scale: 1.1, offset: CGSize(width: 100, height: 100))
      .clamped(viewport: landscape, videoSize: video)
    XCTAssertEqual(zoom.offset.width, 0)
    XCTAssertEqual(zoom.offset.height, 15, accuracy: 0.001)
    let portrait = MobileVideoZoom(scale: 2, offset: CGSize(width: 1000, height: 1000))
      .clamped(viewport: CGSize(width: 300, height: 600), videoSize: video)
    XCTAssertEqual(portrait.offset, CGSize(width: 150, height: 0))
  }
}
