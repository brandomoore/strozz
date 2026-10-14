import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileSidebarLayoutTests: XCTestCase {
  func testSidebarUsesAllRealLiveFollowsWithoutHomeCategoryOrShortcutLimits() {
    let channels = (0..<12).map { index in
      FollowedChannel(id: "\(index)", login: "streamer\(index)", displayName: "Streamer \(index)",
        title: "", gameName: index.isMultiple(of: 2) ? "Minecraft" : "Just Chatting",
        viewerCount: index, thumbnailURL: nil, profileImageURL: nil, isLive: index != 11)
    }
    let sidebar = MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: nil)
    XCTAssertEqual(sidebar.map(\.channelKey), channels.dropLast().map(\.channelKey))
    XCTAssertGreaterThan(sidebar.count, MobileFollowedShortcutCount.limit)
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: false, isDemo: false, category: nil).isEmpty)
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: true, category: nil).isEmpty)
  }

  func testSidebarRowsAdaptToColumnWidthAndAccessibleTypeInEveryTheme() {
    for theme in [AppTheme.system, .light, .dark, .oled] {
      for typeSize in [DynamicTypeSize.large, .accessibility3] {
        for width in [240.0, 300, 340] {
          let host = UIHostingController(rootView:
            MobileSidebarChannelRow(name: "A streamer with a longer display name", category: "Just Chatting",
              title: "An evening stream with friends and a longer stream title", viewers: 12900, avatarURL: nil)
              .environment(\.themePalette, theme.palette(systemColorScheme: .light))
              .environment(\.dynamicTypeSize, typeSize))
          let size = host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
          XCTAssertEqual(size.width, width, accuracy: 1)
          XCTAssertGreaterThanOrEqual(size.height, 44)
          XCTAssertLessThan(size.height, 600, "Accessible text must wrap within the sidebar, not escape its column")
          if !typeSize.isAccessibilitySize {
            XCTAssertLessThanOrEqual(size.height, 60, "Normal sidebar rows use three text lines, not a separate viewer-count line")
          }
        }

        func testNavigationRowsKeepCompactAccessibleTouchTargets() {
          for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let host = UIHostingController(rootView:
              MobileSidebarNavigationRow(title: "Account", glyph: .userCircle, selected: true, action: {})
                .environment(\.dynamicTypeSize, typeSize))
            let size = host.sizeThatFits(in: CGSize(width: 276, height: UIView.layoutFittingExpandedSize.height))
            XCTAssertGreaterThanOrEqual(size.height, 44)
            if !typeSize.isAccessibilitySize { XCTAssertLessThanOrEqual(size.height, 48) }
          }
        }
      }
    }
  }
}
