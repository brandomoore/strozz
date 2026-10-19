import SDWebImage
import SDWebImageWebPCoder
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
private final class AnimationCountingView: SDAnimatedImageView {
  var starts = 0
  var stops = 0
  var purges = 0
  private var playing = false

  override var isAnimating: Bool { playing }
  override func startAnimating() { starts += 1; playing = true }
  override func stopAnimating() {
    stops += 1
    if clearBufferWhenStopped { purges += 1 }
    playing = false
  }
}

private final class DecodeCountingImage: SDAnimatedImage, @unchecked Sendable {
  private let countLock = NSLock()
  private var count = 0
  var decodedFrames: Int { countLock.withLock { count } }

  override func animatedImageFrame(at index: UInt) -> UIImage? {
    countLock.withLock { count += 1 }
    return super.animatedImageFrame(at: index)
  }
}

@MainActor
final class ChatBadgeRenderingTests: XCTestCase {
  func testIdleEmoteUpdatesAndTeardownDoNotRepeatedlyPurgeTheSharedPool() {
    let view = AnimationCountingView()
    let coordinator = ChatEmoteImage.Coordinator()
    for _ in 0..<100 {
      ChatEmoteImage.updateAnimation(view, coordinator: coordinator, shouldAnimate: false)
    }
    XCTAssertEqual(view.stops, 0)
    for _ in 0..<100 {
      ChatEmoteImage.updateAnimation(view, coordinator: coordinator, shouldAnimate: true)
    }
    XCTAssertEqual(view.starts, 1)
    for _ in 0..<100 {
      ChatEmoteImage.updateAnimation(view, coordinator: coordinator, shouldAnimate: false)
    }
    XCTAssertEqual(view.stops, 1)
    XCTAssertEqual(view.purges, 1, "Leaving the viewport must still release this consumer's buffers once")
    ChatEmoteImage.dismantleUIView(view, coordinator: coordinator)
    XCTAssertEqual(view.stops, 1, "Removing an already-inactive row must not flush another visible copy's frames")
    XCTAssertFalse(view.clearBufferWhenStopped, "UIKit cleanup must not repeat the shared-pool purge")
  }

  func testOptInSharedAnimatedEmoteCacheAvoidsRepeatedIdleDecodeWork() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_EMOTE_CACHE_PERFORMANCE"] == "1" else {
      throw XCTSkip("Opt in on an isolated simulator to compare native shared-frame decode work.")
    }
    let frames = (0..<8).map { index in
      SDImageFrame(image: UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image {
        UIColor(hue: CGFloat(index) / 8, saturation: 1, brightness: 1, alpha: 1).setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
      }, duration: 0.06)
    }
    let source = try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames))
    let data = try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: source, format: .webP, options: nil))
    let image = try XCTUnwrap(DecodeCountingImage(data: data))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let controller = UIViewController()
    let visible = SDAnimatedImageView(frame: CGRect(x: 0, y: 0, width: 128, height: 128))
    let inactive = SDAnimatedImageView(frame: CGRect(x: 140, y: 0, width: 128, height: 128))
    visible.autoPlayAnimatedImage = true
    inactive.autoPlayAnimatedImage = false
    controller.view.addSubview(visible)
    controller.view.addSubview(inactive)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    visible.image = image
    inactive.image = image
    defer {
      visible.stopAnimating()
      inactive.stopAnimating()
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    try await waitUntil { visible.isAnimating }
    var before = image.decodedFrames
    for _ in 0..<60 {
      inactive.clearBufferWhenStopped = true
      inactive.stopAnimating()
      try await Task.sleep(for: .milliseconds(20))
    }
    let legacy = image.decodedFrames - before
    let coordinator = ChatEmoteImage.Coordinator()
    before = image.decodedFrames
    var visibleFrameIndices = Set<UInt>()
    for _ in 0..<60 {
      ChatEmoteImage.updateAnimation(inactive, coordinator: coordinator, shouldAnimate: false)
      try await Task.sleep(for: .milliseconds(20))
      if let index = visible.player?.currentFrameIndex { visibleFrameIndices.insert(index) }
    }
    let optimized = image.decodedFrames - before
    print("EMOTE_CACHE legacy_idle_stop_decodes=\(legacy) optimized_idle_updates_decodes=\(optimized)")
    XCTAssertTrue(visible.isAnimating, "Keep the visible copy animated")
    XCTAssertFalse(inactive.isAnimating)
    XCTAssertEqual(image.cgImage?.width, frames[0].image.cgImage?.width, "Preserve source pixel width")
    XCTAssertEqual(image.cgImage?.height, frames[0].image.cgImage?.height, "Preserve source pixel height")
    XCTAssertGreaterThan(visibleFrameIndices.count, 1, "Visible frames must continue advancing")
    XCTAssertLessThan(optimized, legacy, "Inactive row updates must preserve the shared native frame cache")
  }

  func testOptInBurnEmotesRenderFromTheCompleteCatalog() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_EMOTE_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Opt in to verify current provider assets.")
    }
    let catalog = await EmoteCatalogService().snapshot(for: "burn", refreshChannelEmotes: true)
    let names = ["CAUGHT", "xdd"]
    let urls = try names.map { try XCTUnwrap(catalog.urls[$0], "Missing \($0) from the assembled catalog") }
    let segments = ChatLineTokenizer.segments(text: names.joined(separator: " "),
      twitchEmoteURLs: [:], youtubeEmoteURLs: [:], globalEmoteURLs: catalog.urls,
      cheermotes: [], shouldRenderCheers: false)
    XCTAssertEqual(segments.filter {
      if case .emote = $0 { return true }
      return false
    }.count, names.count)
    let details = XCTAttachment(string: zip(names, urls).map { "\($0): \($1)" }.joined(separator: "\n"))
    details.name = "Resolved Burn emote URLs"
    details.lifetime = .keepAlways
    add(details)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    var loaded: [URL: CGSize] = [:]
    let host = UIHostingController(rootView: VStack {
      ForEach(urls, id: \.self) { url in
        ChatEmoteImage(url: url, animated: true, active: true, isGIF: false) { size in
          if let size { loaded[url] = size }
        }
        .frame(width: 122, height: 64)
      }
    })
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    for _ in 0..<200 {
      if loaded.count == urls.count { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    for (name, url) in zip(names, urls) {
      XCTAssertNotNil(loaded[url], "\(name) was in the catalog but did not render")
    }
  }

  func testStaticWebPRendersWithColdAndWarmAnimationPreferences() async throws {
    try await checkWebPRendering(animated: false)
  }

  func testAnimatedWebPRemainsAnimatedAfterFirstFrameCacheHits() async throws {
    try await checkWebPRendering(animated: true)
  }

  private func checkWebPRendering(animated: Bool) async throws {
    let frames = [UIColor.systemOrange, .systemBlue].map { color in
      SDImageFrame(image: UIGraphicsImageRenderer(size: CGSize(width: 160, height: 40)).image {
        color.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 160, height: 40))
      }, duration: 0.1)
    }
    let source = animated ? try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames)) : frames[0].image
    let data = try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: source, format: .webP, options: nil))
    for initiallyAnimated in [true, false] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("emote-\(UUID()).webp")
      try data.write(to: url)
      defer {
        do { try FileManager.default.removeItem(at: url) }
        catch { XCTFail("Could not remove owned emote fixture: \(error)") }
      }
      // A badge or preview may already have cached a nonanimated image for this URL.
      await SDImageCache.shared.store(frames[0].image, forKey: url.absoluteString, toDisk: false)
      defer { SDImageCache.shared.removeImage(forKey: url.absoluteString, fromDisk: false) }
      let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let previous = scene.keyWindow
      let state = BadgeRenderingState(url: url)
      state.animated = initiallyAnimated
      let host = UIHostingController(rootView: EmoteRenderingHarness(state: state))
      let window = UIWindow(windowScene: scene)
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
      }
      for preference in [initiallyAnimated, !initiallyAnimated, initiallyAnimated, !initiallyAnimated] {
        state.animated = preference
        try await Task.sleep(for: .milliseconds(80))
        host.view.layoutIfNeeded()
        try await waitUntil {
          guard let view = self.imageView(in: host.view) else { return false }
          return view.image != nil && view.isAnimating == (animated && preference)
        }
        let view = try XCTUnwrap(imageView(in: host.view))
        XCTAssertNotNil(view.window)
        XCTAssertEqual(view.bounds.width, 104, accuracy: 1)
        XCTAssertEqual(view.bounds.height, 26, accuracy: 1)
        if animated && preference {
          XCTAssertTrue(view.image is SDAnimatedImage, "Keep lazy, bounded frame decoding")
        }
      }
    }
  }

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
