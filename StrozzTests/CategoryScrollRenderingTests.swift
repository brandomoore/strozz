import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class CategoryScrollRenderingTests: XCTestCase {
  func testCategoryGridDoesNotClipAtInsetViewportWhenScrolled() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let category = TwitchCategory(id: "fixture", name: "Category streams", boxArtURL: nil,
      viewerCount: 10_000, isMature: false)
    let edges = (0..<30).map { index -> [String: Any] in
      ["node": [
        "id": "stream-\(index)", "title": "Stream \(index)", "viewersCount": 100 - index,
        "broadcaster": ["login": "strozz-layout-fixture-\(index)", "displayName": "Channel \(index)"],
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
    XCTAssertFalse(scroll.clipsToBounds,
      "The inset tvOS scroll viewport must not cut thumbnails off below the empty top safe area")
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Category scrolled viewport"
    attachment.lifetime = .keepAlways
    add(attachment)
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
