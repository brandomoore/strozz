import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileChatPresentationTests: XCTestCase {
  func testTopFadeIsOnlyTwentyFourPointsAndAccessibilityCanDisableIt() throws {
    for enabled in [true, false] {
      for theme in AppTheme.allCases {
        let renderer = ImageRenderer(content: Rectangle()
          .fill(theme.palette(systemColorScheme: .light).chatSidePrimaryText)
          .frame(width: 40, height: 100)
          .mask { MobileChatTopFade(enabled: enabled) })
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 40 * 100 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
          let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 40, height: 100,
            bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 100))
        }
        func alpha(_ y: Int) -> Double { Double(pixels[(y * 40 + 20) * 4 + 3]) / 255 }
        if enabled {
          XCTAssertLessThan(alpha(0), 0.05)
          XCTAssertEqual(alpha(12), 0.52, accuracy: 0.05)
          XCTAssertGreaterThan(alpha(24), 0.98)
        } else {
          XCTAssertGreaterThan(alpha(0), 0.98)
        }
        XCTAssertGreaterThan(alpha(99), 0.98, "The newest messages must not fade")
      }
    }
  }

  func testPointsDoNotFabricateAnUnloadedBalance() {
    let tracker = TwitchWatchTracker()
    XCTAssertNil(MobileChatRewardsSummary.snapshot(of: tracker))
    XCTAssertEqual(MobileChatRewardsSummary.compactBalance(57990, locale: Locale(identifier: "en_US")), "57.9K")
    XCTAssertEqual(MobileChatRewardsSummary.compactBalance(0, locale: Locale(identifier: "en_US")), "0")
  }

  func testComposerWithPointsFitsNarrowWidthsAndLargeText() {
    let rewards = MobileChatRewardsSummary(balance: 57990, name: "Leaves",
      imageURL: nil, streak: 10, errorMessage: nil)
    for width in [280.0, 320, 390, 700] {
      for typeSize in [DynamicTypeSize.large, .accessibility3] {
        let host = UIHostingController(rootView: MobileChatComposerInput(
          text: .constant("Hello chat"), sending: false, onSend: {}, onSettings: {},
          reduceTransparency: true, rewards: rewards).environment(\.dynamicTypeSize, typeSize))
        let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(size.height, 52)
        XCTAssertLessThan(size.height, 300)
      }

      func testSharedComposerKeepsSendingAndErrorsAcrossLayoutChanges() async {
        let state = MobileChatComposerState()
        state.text = "Keep my message"
        let portrait = MobileChatComposer(channel: "fixture", onSettings: {}, composer: state)
        let landscape = MobileChatComposer(channel: "fixture", onSettings: {}, composer: state)
        var calls = 0
        await portrait.composer.send { message in
          calls += 1
          XCTAssertEqual(message, "Keep my message")
          XCTAssertTrue(landscape.composer.sending)
          await landscape.composer.send { _ in calls += 1 }
          throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(landscape.composer.text, "Keep my message")
        XCTAssertNotNil(landscape.composer.errorMessage)
        XCTAssertFalse(landscape.composer.sending)
        await landscape.composer.send { _ in calls += 1 }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(portrait.composer.text, "")
      }
    }
  }
}
