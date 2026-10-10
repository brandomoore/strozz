import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class CategoryScrollRenderingTests: XCTestCase {
  func testBrowseArtworkRemainsVisibleAboveTheInsetScrollViewport() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("browse-art-\(UUID()).png")
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let artwork = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40), format: format).image { context in
      UIColor.magenta.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
    }
    try XCTUnwrap(artwork.pngData()).write(to: url)
    defer {
      do { try FileManager.default.removeItem(at: url) }
      catch { XCTFail("Could not remove test artwork: \(error)") }
    }
    let edges = (0..<40).map { index in
      ["node": ["id": "category-\(index)", "name": "Category \(index)",
        "boxArtURL": index < 7 ? url.absoluteString : "", "viewersCount": 100]] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: ["data": ["games": ["edges": edges]]])
    let service = BrowseService { request in
      (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    await service.loadCategories()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let host = UIHostingController(rootView: BrowseScrollHarness(service: service)
      .environment(\.themePalette, .dark).environment(\.glassDisabled, true).preferredColorScheme(.dark))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .seconds(1))
    let scroll = try XCTUnwrap(scrollViews(in: host.view).max(by: { $0.bounds.width < $1.bounds.width }))
    let viewport = scroll.convert(scroll.bounds, to: window)
    XCTAssertEqual(viewport.minY, window.bounds.minY, accuracy: 1)
    XCTAssertEqual(viewport.maxY, window.bounds.maxY, accuracy: 1)
    print("BROWSE_VIEWPORT frame=\(viewport) inset=\(scroll.adjustedContentInset)")
    let initial = snapshot(window)
    let initialOffset = scroll.contentOffset.y
    let original = try magentaRows(initial, x: Int(window.bounds.width * 0.2))
    XCTAssertGreaterThan(original.count, 100, "Fixture art must actually render before testing culling")
    let firstStart = try XCTUnwrap(original.first)
    var firstEnd = firstStart
    while original.contains(firstEnd + 1) { firstEnd += 1 }
    let geometry = XCTAttachment(string: "viewport=\(viewport) initialOffset=\(initialOffset) art=\(firstStart)...\(firstEnd)")
    geometry.name = "Browse initial geometry"
    geometry.lifetime = .keepAlways
    add(geometry)
    for visibleBottom in [100, 80, 60, 40, 20, 40, 60, 80, 100] {
      let offset = initialOffset + CGFloat(firstEnd - visibleBottom)
      scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
      let image = snapshot(window)
      let rows = try magentaRows(image, x: Int(window.bounds.width * 0.2))
      let expectedY = visibleBottom - 10
      let attachment = XCTAttachment(image: image)
      attachment.name = "Browse card bottom at \(visibleBottom)"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertTrue(rows.contains(expectedY),
        "Artwork still on screen at y=\(expectedY) must not disappear at the inset viewport \(viewport.minY)")
    }
  }

  private func snapshot(_ window: UIWindow) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
  }

  private func magentaRows(_ image: UIImage, x: Int) throws -> Set<Int> {
    let cgImage = try XCTUnwrap(image.cgImage)
    let column = try XCTUnwrap(cgImage.cropping(to: CGRect(x: x, y: 0, width: 1, height: cgImage.height)))
    var bytes = [UInt8](repeating: 0, count: cgImage.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: cgImage.height,
        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(column, in: CGRect(x: 0, y: 0, width: 1, height: cgImage.height))
    }
    return Set((0..<cgImage.height).filter {
      bytes[$0 * 4] > 120 && bytes[$0 * 4 + 1] < 70 && bytes[$0 * 4 + 2] > 120
    })
  }

  func testCategoryGridDoesNotClipAtInsetViewportWhenScrolled() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let avatarURL = FileManager.default.temporaryDirectory.appendingPathComponent("category-avatar-\(UUID()).png")
    let avatar = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
      UIColor.magenta.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
    try XCTUnwrap(avatar.pngData()).write(to: avatarURL)
    let suite = "CategoryScrollRendering.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(StreamCardSize.large.rawValue, forKey: StreamCardSize.storageKey)
    defaults.set(CardPresentation.poster.rawValue, forKey: CardPresentation.storageKey)
    defer {
      defaults.removePersistentDomain(forName: suite)
      do { try FileManager.default.removeItem(at: avatarURL) }
      catch { XCTFail("Could not remove category avatar fixture: \(error)") }
    }
    let category = TwitchCategory(id: "fixture", name: "Category streams", boxArtURL: nil,
      viewerCount: 10_000, isMature: false)
    let edges = (0..<30).map { index -> [String: Any] in
      ["node": [
        "id": "stream-\(index)", "title": "Stream \(index)", "viewersCount": 100 - index,
        "broadcaster": ["login": "strozz-layout-fixture-\(index)", "displayName": "Channel \(index)",
          "profileImageURL": index < 3 ? avatarURL.absoluteString : ""],
      ]]
    }
    let data = try JSONSerialization.data(withJSONObject: ["data": ["game": ["streams": ["edges": edges]]]])
    let service = BrowseService { request in
      (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let root = CategoryScrollHarness(category: category, service: service)
      .environment(PlaybackReturnRefreshCoordinator())
      .environment(\.themePalette, .dark)
      .preferredColorScheme(.dark)
      .defaultAppStorage(defaults)
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .black
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    for _ in 0..<50 {
      host.view.layoutIfNeeded()
      if service.categoryStreams.count == 30,
        scrollViews(in: host.view).contains(where: { $0.contentSize.height > $0.bounds.height * 2 }) {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let scroll = try XCTUnwrap(scrollViews(in: host.view)
      .filter { $0.contentSize.height > $0.bounds.height * 2 }.max(by: { $0.bounds.width < $1.bounds.width }))
    try await Task.sleep(for: .seconds(1))
    scroll.setContentOffset(CGPoint(x: 0, y: 350), animated: false)
    host.view.layoutIfNeeded()
    XCTAssertEqual(scroll.contentOffset.y, 350, accuracy: 1)
    let frame = scroll.convert(scroll.bounds, to: window)
    print("CATEGORY_VIEWPORT frame=\(frame) inset=\(scroll.adjustedContentInset) clips=\(scroll.clipsToBounds)")
    XCTAssertEqual(frame.minY, window.bounds.minY, accuracy: 1,
      "Lazy grid visibility must include the entire visible screen, not only the inset scroll region")
    XCTAssertEqual(frame.maxY, window.bounds.maxY, accuracy: 1)
    XCTAssertFalse(scroll.clipsToBounds,
      "The inset tvOS scroll viewport must not cut thumbnails off below the empty top safe area")
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Category scrolled viewport"
    attachment.lifetime = .keepAlways
    add(attachment)
    let x = Int(window.bounds.width * 0.38)
    let original = try magentaRows(snapshot(window), x: x)
    let originalOffset = scroll.contentOffset.y
    let lastAvatarPixel = try XCTUnwrap(original.max())
    for visibleBottom in [140, 100, 60, 20, 60, 100, 140] {
      let offset = originalOffset + CGFloat(lastAvatarPixel - visibleBottom)
      scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
      let screenshot = snapshot(window)
      let rows = try magentaRows(screenshot, x: x)
      XCTAssertTrue(rows.contains(visibleBottom - 10),
        "The same top-row avatar at y=\(visibleBottom - 10) must remain rendered until it leaves the screen")
      let capture = XCTAttachment(image: screenshot)
      capture.name = "Category row avatar bottom at \(visibleBottom)"
      capture.lifetime = .keepAlways
      add(capture)
    }
  }

  private struct BrowseScrollHarness: View {
    let service: BrowseService

    var body: some View {
      TabView {
        NavigationStack {
          BrowseCategoriesView(service: service, isLoading: false, onSelectCategory: { _ in })
        }
        .tabItem { Text("Browse") }
      }
    }
  }

  private func scrollViews(in view: UIView) -> [UIScrollView] {
    (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }
}

private struct CategoryScrollHarness: View {
  let category: TwitchCategory
  let service: BrowseService
  @State private var path: [TwitchCategory] = []

  var body: some View {
    TabView {
      NavigationStack(path: $path) {
        Text("Browse")
          .navigationDestination(for: TwitchCategory.self) { category in
            CategoryStreamsView(category: category, selectedChannel: .constant(nil),
              channelPageTarget: .constant(nil), service: service)
          }
      }
      .tabItem { Text("Browse") }
    }
    .task { path = [category] }
  }
}
