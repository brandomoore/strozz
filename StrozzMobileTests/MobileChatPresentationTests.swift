import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileChatPresentationTests: XCTestCase {
  func testHorizontalReadoutsHaveOnlyLiveRedDotAndNoDarkBackplates() throws {
    let states: [LivePlaybackPosition.State] = [.live, .checking, .paused, .behind(seconds: 15)]
    for state in states {
      for theme in AppTheme.allCases {
        let renderer = ImageRenderer(content: MobileStreamReadouts(state: state,
          startedAt: Date().addingTimeInterval(-4 * 3600 - 37 * 60), viewerCount: 1900,
          showDuration: true, onGoLive: {})
          .environment(\.themePalette, theme.palette(systemColorScheme: .light)))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertLessThanOrEqual(image.height, 44, "No vertically stacked readouts")
        if state == .live { XCTAssertLessThanOrEqual(image.width, 180) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
          let context = try XCTUnwrap(CGContext(data: buffer.baseAddress,
            width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var redPixels = 0
        var darkPlatePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 128 {
          if pixels[offset] > 150 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80 { redPixels += 1 }
          if pixels[offset] < 30 && pixels[offset + 1] < 30 && pixels[offset + 2] < 30 { darkPlatePixels += 1 }
        }
        XCTAssertEqual(darkPlatePixels, 0, "Readouts use the same clear surface as the other video icons")
        if state == .live { XCTAssertGreaterThan(redPixels, 10) }
        else { XCTAssertEqual(redPixels, 0, "Never imply live playback while checking, paused, or behind") }
      }
    }
  }

  func testTopFadeBlendsAcrossFortyEightPointsAndAccessibilityCanDisableIt() throws {
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
          XCTAssertLessThan(alpha(5), 0.01)
          XCTAssertEqual(alpha(24), 0.35, accuracy: 0.05)
          XCTAssertGreaterThan(alpha(48), 0.98)
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

    }
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
