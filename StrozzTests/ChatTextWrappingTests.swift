import SwiftUI
import SDWebImage
import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

@MainActor
final class ChatTextWrappingTests: XCTestCase {
  func testLongLinksUseFullWrappedHeightWithoutAnOptIn() {
    let url = "https://example.com/" + String(repeating: "long-path", count: 40)
      + "?token=" + String(repeating: "abcdef0123456789", count: 20)
    for width in [180.0, 296, 420, 760] {
      for fontSize in [16.0, 28, 44, 64] {
        let line = chat(text: url, fontSize: fontSize)
        let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        let actual = UIHostingController(rootView: line).sizeThatFits(in: proposal)
        let reference = UIHostingController(rootView:
          Text(url).font(line.fontStyle.font(size: fontSize, scalesCustomFont: false))
            .tracking(line.letterSpacing)
            .fixedSize(horizontal: false, vertical: true)).sizeThatFits(in: proposal)
        XCTAssertTrue(line.wrapsOversizedTokens)
        XCTAssertEqual(actual.width, width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(actual.height, reference.height,
          "The entire URL must wrap, not clip or truncate: width=\(width), font=\(fontSize)")
        XCTAssertLessThanOrEqual(actual.height, reference.height + fontSize * 3)
      }
    }
  }

  func testLongUsernamesWrapAndOrdinaryMessagesKeepTheirLayout() {
    for width in [180.0, 420] {
      let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
      let username = String(repeating: "WideUsername", count: 20)
      let long = chat(text: "hello", username: username, fontSize: 28)
      let actual = UIHostingController(rootView: long).sizeThatFits(in: proposal)
      let name = UIHostingController(rootView:
        Text("\(username): ").font(long.fontStyle.font(size: 28, weight: .bold, scalesCustomFont: false))
          .tracking(long.letterSpacing)
          .fixedSize(horizontal: false, vertical: true)).sizeThatFits(in: proposal)
      XCTAssertGreaterThanOrEqual(actual.height, name.height)
      XCTAssertEqual(actual.width, width, accuracy: 1)

      let ordinary = chat(text: "Hello this is an ordinary chat message.", fontSize: 28)
      var previous = ordinary
      previous.wrapsOversizedTokens = false
      XCTAssertEqual(UIHostingController(rootView: ordinary).sizeThatFits(in: proposal),
        UIHostingController(rootView: previous).sizeThatFits(in: proposal))
    }
  }

  func testWrappingDoesNotChangeOriginalMessageOrTokenContent() {
    let url = "https://example.com/" + String(repeating: "A", count: 300) + "?q=hello%20world#section"
    let text = "Before \(url) after"
    let line = chat(text: text, fontSize: 28)
    let segments = ChatLineTokenizer.segments(text: text, twitchEmoteURLs: [:],
      youtubeEmoteURLs: [:], globalEmoteURLs: [:], cheermotes: [], shouldRenderCheers: false)
    XCTAssertEqual(line.message.text, text)
    XCTAssertEqual(segments.compactMap { segment in
      if case .text(let value) = segment { return value }
      return nil
    }.joined(), text, "Wrapping must not insert hidden separators into URLs")
    XCTAssertFalse(ChatFlowLayout().wrapsOversizedTokens,
      "Settings controls still use atomic flow items; only chat opts into text wrapping by default")
  }

  func testNativeRenderedURLInkFitsAndRetainsEveryLineAtNarrowAndLargestSizes() async throws {
    let url = "https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      + "?token=abcdefghijklmnopqrstuvwxyz0123456789&end=COMPLETE"
    for (width, size) in [(180.0, 16.0), (180, 64), (296, 28), (420, 44), (760, 64)] {
      let line = renderingChat(text: url, fontSize: size)
      let actual = try await render(line, width: width,
        name: "default-url-width-\(Int(width))-font-\(Int(size))")
      let reference = try await render(
        Text(url).font(line.fontStyle.font(size: size, scalesCustomFont: false))
          .tracking(line.letterSpacing).foregroundStyle(Color.white)
          .fixedSize(horizontal: false, vertical: true),
        width: width, name: "reference-url-width-\(Int(width))-font-\(Int(size))")
      assertContained(actual, width: width)
      XCTAssertEqual(actual.body.rows, reference.body.rows,
        "All URL glyph rows must render, not merely a correctly sized containing frame")
      XCTAssertEqual(actual.body.count, reference.body.count,
        "Wrapped URL ink must match a complete native Text reference")
      XCTAssertEqual(line.message.text, url)
    }
  }

  func testNativeOldDefaultControlVisiblyOverflowsButProductionDefaultDoesNot() async throws {
    let url = "https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      + "?token=abcdefghijklmnopqrstuvwxyz0123456789&end=COMPLETE"
    var before = renderingChat(text: url, fontSize: 28)
    before.wrapsOversizedTokens = false
    let old = try await render(before, width: 296, name: "before-explicit-false")
    let current = try await render(renderingChat(text: url, fontSize: 28),
      width: 296, name: "after-production-default")
    XCTAssertGreaterThan(old.body.maxX, Int(24 + 296 + 10),
      "The contrasting outside-pane guard must expose the original rendered overflow")
    assertContained(current, width: 296)
    XCTAssertGreaterThan(current.body.rows, old.body.rows)
    XCTAssertGreaterThan(current.body.count, old.body.count,
      "The fixed screenshot must include more than the clipped prefix of the old URL")
  }

  func testNativeLongUsernameAndNeighboringEmotesRemainComplete() async throws {
    let username = String(repeating: "WideUsername", count: 6)
    let nameLine = renderingChat(text: "hello", username: username, fontSize: 64)
    let actualName = try await render(nameLine, width: 180, name: "long-username-largest")
    let referenceName = try await render(
      Text("\(username): ")
        .font(nameLine.fontStyle.font(size: 64, weight: .bold, scalesCustomFont: false))
        .tracking(nameLine.letterSpacing).foregroundStyle(Color.cyan)
        .fixedSize(horizontal: false, vertical: true),
      width: 180, name: "reference-long-username")
    assertContained(actualName, width: 180)
    XCTAssertEqual(actualName.username.rows, referenceName.username.rows)
    XCTAssertEqual(actualName.username.count, referenceName.username.count)

    let emoteURL = try XCTUnwrap(URL(string: "https://example.invalid/chat-wrap-fixture.png"))
    let key = "chat-emote:static:\(emoteURL.absoluteString)"
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image {
      UIColor.orange.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    }
    SDImageCache.shared.storeImage(toMemory: image, forKey: key)
    defer { SDImageCache.shared.removeImageFromMemory(forKey: key) }
    for text in [
      "Hello Wide ordinary words Wide done.",
      "Wide https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789?token=abcdefghijklmnopqrstuvwxyz&end=COMPLETE Wide"
    ] {
      let message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
        text: text, twitchEmoteURLs: ["Wide": emoteURL])
      let line = RichChatLineView(message: message, nameColor: .cyan,
        globalEmoteURLs: [:], badgeURLs: [:], textSize: 28, emoteSize: 26,
        animatedEmotes: false, bodyColorOverride: .white, scalesCustomFont: false)
      let actual = try await render(line, width: 296,
        name: text.hasPrefix("Hello") ? "ordinary-neighboring-emotes" : "url-neighboring-emotes",
        expectedEmotes: 2)
      assertContained(actual, width: 296)
      XCTAssertEqual(actual.emoteFrames.count, 2)
      for frame in actual.emoteFrames {
        XCTAssertEqual(frame.width, 52, accuracy: 1)
        XCTAssertEqual(frame.height, 26, accuracy: 1)
        XCTAssertGreaterThanOrEqual(frame.minX, 24 - 1)
        XCTAssertLessThanOrEqual(frame.maxX, 24 + 296 + 1)
      }
      if text.hasPrefix("Hello") {
        var old = line
        old.wrapsOversizedTokens = false
        let previous = try await render(old, width: 296, name: "ordinary-emotes-explicit-false",
          expectedEmotes: 2)
        XCTAssertEqual(actual.height, previous.height)
        XCTAssertEqual(actual.body.count, previous.body.count)
        XCTAssertEqual(actual.body.rows, previous.body.rows)
        XCTAssertEqual(actual.emoteFrames, previous.emoteFrames)
      }
      XCTAssertEqual(line.message.text, text)
    }
  }

  func testNativeProductionTimelineRendersTheCompleteURL() async throws {
    let url = "https://example.com/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      + "?token=abcdefghijklmnopqrstuvwxyz0123456789&end=COMPLETE"
    let message = ChatMessage(username: "Viewer", colorHex: "#00FFFF", badgeKeys: [],
      text: url, twitchEmoteURLs: [:])
    let paneWidth = 420.0
    #if os(iOS)
    let suite = "ChatTextWrappingTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(16.0, forKey: PersistenceKey.chatTextSizeValue)
    defaults.set(0.0, forKey: PersistenceKey.chatLineHeightValue)
    for (dynamicType, category) in [
      (DynamicTypeSize.large, UIContentSizeCategory.large),
      (.accessibility5, .accessibilityExtraExtraExtraLarge)
    ] {
      let actual = try await render(
        MobileChatTimeline(messages: [message])
          .defaultAppStorage(defaults)
          .environment(\.themePalette, .oled)
          .environment(\.dynamicTypeSize, dynamicType)
          .frame(height: 1600),
        width: paneWidth, name: "production-timeline-\(category.rawValue)", increasedContrast: true)
      let reference = try await render(
        ScaledChatTextReference(text: url).environment(\.dynamicTypeSize, dynamicType),
        width: paneWidth - 24, name: "timeline-reference-\(category.rawValue)")
      assertContained(actual, width: paneWidth)
      XCTAssertEqual(actual.body.rows, reference.body.rows)
      XCTAssertEqual(actual.body.count, reference.body.count)
    }
    #else
    for size in [28.0, 64.0] {
      let actual = try await render(
        ChatView(channel: "example", messages: [message], textSize: size,
          lineHeight: 0, letterSpacing: 0, animatedEmotes: false, fontStyle: .standard,
          isConnected: true)
          .environment(\.themePalette, .oled)
          .frame(height: 1600),
        width: paneWidth, name: "production-tv-chat-font-\(Int(size))")
      let reference = try await render(
        Text(url).font(ChatFontStyle.standard.font(size: size, scalesCustomFont: false))
          .foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true),
        width: paneWidth - 2 * ChatAppearance.horizontalPadding(forTextSize: size),
        name: "tv-chat-reference-font-\(Int(size))")
      assertContained(actual, width: paneWidth)
      XCTAssertEqual(actual.body.rows, reference.body.rows)
      XCTAssertEqual(actual.body.count, reference.body.count)
    }
    #endif
  }

  private struct Ink {
    var count = 0
    var minX = Int.max
    var maxX = -1
    var rows = 0
  }

  private struct Rendering {
    let height: CGFloat
    let body: Ink
    let username: Ink
    let emoteFrames: [CGRect]
  }

  private func renderingChat(text: String, username: String = "Viewer", fontSize: CGFloat) -> RichChatLineView {
    RichChatLineView(message: ChatMessage(username: username, colorHex: nil, badgeKeys: [],
      text: text, twitchEmoteURLs: [:]), nameColor: .cyan, globalEmoteURLs: [:], badgeURLs: [:],
      textSize: fontSize, animatedEmotes: false, bodyColorOverride: .white, scalesCustomFont: false)
  }

  private func assertContained(_ rendering: Rendering, width: CGFloat,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(rendering.body.count, 0, file: file, line: line)
    for ink in [rendering.body, rendering.username] where ink.count > 0 {
      XCTAssertGreaterThanOrEqual(ink.minX, 24 - 1, file: file, line: line)
      XCTAssertLessThanOrEqual(ink.maxX, Int(24 + width + 1),
        "Actual glyph pixels must stay inside the pane; the host does not clip them",
        file: file, line: line)
    }
  }

  #if os(iOS)
  private struct ScaledChatTextReference: View {
    let text: String
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
      Text(text).font(ChatFontStyle.standard.font(size: 16 * typeScale, scalesCustomFont: false))
        .foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
    }
  }
  #endif

  private func render<Content: View>(_ content: Content, width: CGFloat, name: String,
    expectedEmotes: Int = 0, increasedContrast: Bool = false) async throws -> Rendering {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let sized = content.environment(\.dynamicTypeSize, .accessibility5)
    let measurement = UIHostingController(rootView: sized)
    let size = measurement.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
    let canvas = CGSize(width: width + 400, height: ceil(size.height) + 48)
    let host = UIHostingController(rootView:
      sized.frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black)
        .padding(24)
        .frame(width: canvas.width, alignment: .topLeading)
        .frame(minHeight: canvas.height, alignment: .topLeading)
        .background(Color(red: 0.5, green: 0, blue: 0.5))
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea())
    host.safeAreaRegions = []
    host.view.backgroundColor = UIColor(red: 0.5, green: 0, blue: 0.5, alpha: 1)
    if increasedContrast { host.traitOverrides.accessibilityContrast = .high }
    let container = UIViewController()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = container
    window.makeKeyAndVisible()
    container.addChild(host)
    container.view.addSubview(host.view)
    host.didMove(toParent: container)
    host.view.frame = CGRect(origin: .zero, size: canvas)
    defer {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await Task.sleep(for: .milliseconds(150))
    host.view.layoutIfNeeded()
    if expectedEmotes > 0 {
      // Image loading publishes the aspect ratio separately from the native image.
      // Capture the settled SwiftUI layout, not its initial square placeholder.
      for _ in 0..<100 {
        let images = imageViews(in: host.view)
        if images.count == expectedEmotes && images.allSatisfy({
          $0.image != nil && abs($0.bounds.width - 52) < 1 && abs($0.bounds.height - 26) < 1
        }) { break }
        try await Task.sleep(for: .milliseconds(20))
        host.view.layoutIfNeeded()
      }
      let images = imageViews(in: host.view)
      XCTAssertEqual(images.count, expectedEmotes)
      XCTAssertTrue(images.allSatisfy {
        $0.image != nil && abs($0.bounds.width - 52) < 1 && abs($0.bounds.height - 26) < 1
      }, "Neighboring emotes must finish loading at their original aspect ratio")
    }
    let renderedSize = host.sizeThatFits(in:
      CGSize(width: canvas.width, height: UIView.layoutFittingExpandedSize.height))
    host.view.frame.size = renderedSize
    host.view.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    // Downsampling Retina text to 1x changes occupied rows at fractional origins.
    format.scale = scene.screen.scale
    format.opaque = true
    let screenshot = UIGraphicsImageRenderer(size: renderedSize, format: format).image { _ in
      XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
    }
    let attachment = XCTAttachment(image: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let cgImage = try XCTUnwrap(screenshot.cgImage)
    var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
      bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    var body = Ink()
    var username = Ink()
    for y in 0..<cgImage.height {
      var bodyInRow = false
      var nameInRow = false
      for x in 0..<cgImage.width {
        let offset = (y * cgImage.width + x) * 4
        let r = pixels[offset]
        let g = pixels[offset + 1]
        let b = pixels[offset + 2]
        if r > 180 && g > 180 && b > 180 {
          body.count += 1
          body.minX = min(body.minX, x)
          body.maxX = max(body.maxX, x)
          bodyInRow = true
        } else if r < 100 && g > 150 && b > 150 {
          username.count += 1
          username.minX = min(username.minX, x)
          username.maxX = max(username.maxX, x)
          nameInRow = true
        }
      }
      if bodyInRow { body.rows += 1 }
      if nameInRow { username.rows += 1 }
    }
    if body.count > 0 {
      body.minX = Int(floor(CGFloat(body.minX) / format.scale))
      body.maxX = Int(ceil(CGFloat(body.maxX) / format.scale))
    }
    if username.count > 0 {
      username.minX = Int(floor(CGFloat(username.minX) / format.scale))
      username.maxX = Int(ceil(CGFloat(username.maxX) / format.scale))
    }
    let images = imageViews(in: host.view)
    XCTAssertTrue(images.allSatisfy { $0.image != nil }, "All neighboring emote images must load")
    let frames = images.map { $0.convert($0.bounds, to: host.view) }
    let details = "paneWidth=\(width) fullHeight=\(renderedSize.height - 48) canvas=\(renderedSize) "
      + "bodyPixels=\(body.count) bodyX=\(body.minX)...\(body.maxX) bodyInkRows=\(body.rows) "
      + "namePixels=\(username.count) nameX=\(username.minX)...\(username.maxX) nameInkRows=\(username.rows) "
      + "emoteFrames=\(frames)"
    print("CHAT_WRAP_RENDER \(name) \(details)")
    let geometry = XCTAttachment(string: details)
    geometry.name = "\(name)-geometry"
    geometry.lifetime = .keepAlways
    add(geometry)
    return Rendering(height: renderedSize.height - 48, body: body, username: username, emoteFrames: frames)
  }

  private func imageViews(in view: UIView) -> [UIImageView] {
    if let image = view as? UIImageView { return [image] }
    return view.subviews.flatMap { imageViews(in: $0) }
  }

  private func chat(text: String, username: String = "Viewer", fontSize: CGFloat) -> RichChatLineView {
    RichChatLineView(message: ChatMessage(username: username, colorHex: nil, badgeKeys: [],
      text: text, twitchEmoteURLs: [:]), nameColor: .primary, globalEmoteURLs: [:], badgeURLs: [:],
      textSize: fontSize, animatedEmotes: false, bodyColorOverride: .primary, scalesCustomFont: false)
  }
}
