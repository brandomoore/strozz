import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileHomeLayoutTests: XCTestCase {
  private func channel(_ name: String, category: String = "Just Chatting", live: Bool = true) -> FollowedChannel {
    FollowedChannel(id: name, login: name.lowercased(), displayName: name,
                    title: "A live stream with a longer title", gameName: category, viewerCount: 7500,
                    thumbnailURL: nil, profileImageURL: nil, isLive: live)
  }

  func testFollowingNeverIncludesAnonymousDemoOrOfflineChannels() {
    let channels = [channel("Live"), channel("Offline", live: false)]
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: false, isDemo: false, category: nil).isEmpty)
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: true, category: nil).isEmpty)
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: nil).map(\.login), ["live"])
  }

  func testFollowingCategoryFilterUsesActualLiveFollows() {
    let category = TwitchCategory(id: "chat", name: "Just Chatting", boxArtURL: nil, viewerCount: nil)
    let channels = [channel("Chat", category: "JUST CHATTING"), channel("Game", category: "Minecraft")]
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: category).map(\.login), ["chat"])
  }

  func testSignedInHomeComponentsRenderWithoutAccountOrNetworkAccess() async throws {
    let channels = ["Ludwig", "xQc", "Valkyrae", "Extra", "Another", "Last"].map { channel($0) }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    for theme in [AppTheme.light, .dark] {
      let content = ScrollView {
        VStack(spacing: 20) {
          MobileFollowedShortcuts(channels: channels, onSelect: { _ in }, onSeeAll: {})
          MobileFollowingContent(authenticated: true, channels: channels,
                                 isLoading: false, errorMessage: nil, filtered: false,
                                 onAccount: {}, onRetry: {}, onSelect: { _ in })
        }
        .padding()
      }
      .background(theme.palette(systemColorScheme: .light).chatSideSurface)
      .environment(\.themePalette, theme.palette(systemColorScheme: .light))
      .preferredColorScheme(theme.preferredColorScheme)
      let controller = UIHostingController(rootView: content)
      window.rootViewController = controller
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "signed-in-components-\(theme.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertGreaterThan(controller.view.bounds.width, 0)
    }
  }
}
