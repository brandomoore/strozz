import SDWebImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

@MainActor
final class ChatBadgeRenderingTests: XCTestCase {
  func testWideEmoteKeepsItsAspectRatioWhenAnimationIsToggled() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("wide-emote-\(UUID()).gif")
    let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
    CGImageDestinationSetProperties(output,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for color in [UIColor.systemBlue, .systemGreen] {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 40)).image {
        color.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 160, height: 40))
      }
      CGImageDestinationAddImage(output, try XCTUnwrap(image.cgImage),
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(output))
    defer {
      do { try FileManager.default.removeItem(at: url) }
      catch { XCTFail("Could not remove owned emote fixture: \(error)") }
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let state = BadgeRenderingState(url: url)
    let host = UIHostingController(rootView: EmoteRenderingHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    try await waitUntil { self.imageView(in: host.view)?.isAnimating == true }
    let image = try XCTUnwrap(imageView(in: host.view) as? SDAnimatedImageView)
    for animated in [false, true] {
      state.animated = animated
      try await waitUntil { image.isAnimating == animated && image.image != nil }
      host.view.layoutIfNeeded()
      XCTAssertEqual(image.bounds.width, 104, accuracy: 1)
      XCTAssertEqual(image.bounds.height, 26, accuracy: 1)
    }
  }

  func testBadgeKeepsItsNativeViewThroughResizingAndUpdatesChangedURLs() async throws {
    let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("badge-first-\(UUID()).png")
    let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("badge-second-\(UUID()).png")
    for (url, color) in [(firstURL, UIColor.systemBlue), (secondURL, UIColor.systemGreen)] {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image {
        color.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
      }
      try XCTUnwrap(image.pngData()).write(to: url)
    }
    defer {
      for url in [firstURL, secondURL] {
        do { try FileManager.default.removeItem(at: url) }
        catch { XCTFail("Could not remove owned badge fixture: \(error)") }
      }
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let state = BadgeRenderingState(url: firstURL)
    let host = UIHostingController(rootView: BadgeRenderingHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    try await waitUntil { self.imageView(in: host.view)?.image != nil }
    let badge = try XCTUnwrap(imageView(in: host.view))
    let originalImage = try XCTUnwrap(badge.image)
    XCTAssertEqual(badge.sd_imageURL, firstURL)
    XCTAssertFalse(badge.isAccessibilityElement)
    XCTAssertEqual(badge.contentMode, .scaleAspectFit)
    for size in [26.0, 16, 36, 16] {
      state.size = size
      try await Task.sleep(for: .milliseconds(80))
      host.view.layoutIfNeeded()
      XCTAssertTrue(imageView(in: host.view) === badge)
      XCTAssertTrue(badge.image === originalImage)
      XCTAssertEqual(badge.bounds.size, CGSize(width: size, height: size))
    }
    state.url = secondURL
    try await waitUntil { badge.sd_imageURL == secondURL && badge.image != nil && badge.image !== originalImage }
    XCTAssertTrue(imageView(in: host.view) === badge)
    state.url = firstURL.deletingLastPathComponent().appendingPathComponent("missing-badge-\(UUID()).png")
    try await waitUntil { badge.sd_imageURL == state.url && badge.image == nil }
    XCTAssertEqual(badge.bounds.size, CGSize(width: 16, height: 16),
      "Missing badges keep the same transparent layout slot")
  }

  private func imageView(in view: UIView) -> UIImageView? {
    if let image = view as? UIImageView { return image }
    return view.subviews.lazy.compactMap { self.imageView(in: $0) }.first
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Badge image did not settle")
  }
}

@MainActor
@Observable
private final class BadgeRenderingState {
  var url: URL
  var size: CGFloat = 16
  var animated = true
  init(url: URL) { self.url = url }
}

private struct BadgeRenderingHarness: View {
  let state: BadgeRenderingState
  var body: some View {
    ChatBadgeImage(url: state.url).frame(width: state.size, height: state.size)
  }
}

private struct EmoteRenderingHarness: View {
  let state: BadgeRenderingState
  var body: some View {
    RichChatLineView(message: ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
      text: "Wide", twitchEmoteURLs: ["Wide": state.url]), nameColor: .primary,
      globalEmoteURLs: [:], badgeURLs: [:], textSize: 16, emoteSize: 26,
      animatedEmotes: state.animated)
      .frame(width: 300, height: 100)
  }
}
