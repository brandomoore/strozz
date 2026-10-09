import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileHomeLayoutTests: XCTestCase {
  func testSkeletonCardsReserveLoadedGeometryAtPhoneAndTabletWidths() {
    for width in [300.0, 356, 480] {
      for typeSize in [DynamicTypeSize.large, .accessibility2] {
        for theme in [AppTheme.system, .light, .dark, .oled] {
          let palette = theme.palette(systemColorScheme: .light)
          let skeleton = UIHostingController(rootView:
            MobileChannelCard(channel: LoadingSkeleton.channels[0])
              .modifier(LoadingSkeletonStyle())
              .environment(\.dynamicTypeSize, typeSize).environment(\.themePalette, palette))
          let loaded = UIHostingController(rootView:
            MobileChannelCard(channel: channel("Streamer"))
              .environment(\.dynamicTypeSize, typeSize).environment(\.themePalette, palette))
          let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
          XCTAssertEqual(skeleton.sizeThatFits(in: proposal).height, loaded.sizeThatFits(in: proposal).height, accuracy: 1)
        }
      }
    }
  }

  func testShortcutSectionDoesNotMoveFeedForPartialOrEmptyResults() {
    for width in [300.0, 356, 788] {
      for typeSize in [DynamicTypeSize.large, .accessibility2] {
        let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        let restoring = UIHostingController(rootView:
          MobileFollowedShortcuts(channels: [], onSelect: { _ in }, onSeeAll: {},
                                  authenticated: false, isRestoringAccount: true)
            .environment(\.dynamicTypeSize, typeSize))
        let reservedHeight = restoring.sizeThatFits(in: proposal).height
        XCTAssertGreaterThan(reservedHeight, 100)
        for count in [0, 1, 3, 6] {
          for category in ["Just Chatting", ""] {
            let loaded = UIHostingController(rootView:
              MobileFollowedShortcuts(channels: (0..<count).map { channel("Streamer \($0)", category: category) },
                                      onSelect: { _ in }, onSeeAll: {})
                .environment(\.dynamicTypeSize, typeSize))
            XCTAssertEqual(reservedHeight, loaded.sizeThatFits(in: proposal).height, accuracy: 1,
                           "Reserve all shortcut rows at \(width), \(typeSize), \(count) follows, category '\(category)'")
          }
        }
      }
    }
  }

  func testRestoringAccountReservesShortcutSpaceBeforeAuthentication() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    var feedTop: CGFloat?
    func content(authenticated: Bool, restoring: Bool, loading: Bool, channels: [FollowedChannel]) -> some View {
      VStack(alignment: .leading, spacing: 16) {
        MobileFollowedShortcuts(channels: channels, onSelect: { _ in }, onSeeAll: {},
                                isLoading: loading, authenticated: authenticated, isRestoringAccount: restoring)
          .padding(.horizontal)
        Text("For you").font(.title3.bold())
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("followed-reservation")).minY } action: {
            feedTop = $0
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .coordinateSpace(name: "followed-reservation")
      .environment(\.themePalette, .light)
    }
    let controller = UIHostingController(rootView:
      content(authenticated: false, restoring: true, loading: false, channels: []))
    window.rootViewController = controller
    func layout() async throws {
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      controller.view.layoutIfNeeded()
    }
    try await layout()
    let reservedTop = try XCTUnwrap(feedTop)
    XCTAssertGreaterThan(reservedTop, 100, "Reserve the compact cards before authentication is known")
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "For you followed shortcuts during account restoration"
    attachment.lifetime = .keepAlways
    add(attachment)

    controller.rootView = content(authenticated: true, restoring: false, loading: true, channels: [])
    try await layout()
    XCTAssertEqual(try XCTUnwrap(feedTop), reservedTop, accuracy: 1)
    for count in [0, 1, 3, 6] {
      controller.rootView = content(authenticated: true, restoring: false, loading: false,
        channels: (0..<count).map { channel("Streamer \($0)", category: "") })
      try await layout()
      XCTAssertEqual(try XCTUnwrap(feedTop), reservedTop, accuracy: 1, "Loaded follows must not move the feed")
    }
    controller.rootView = content(authenticated: false, restoring: false, loading: false, channels: [])
    try await layout()
    XCTAssertEqual(try XCTUnwrap(feedTop), 0, accuracy: 1, "Signed-out users must not retain an empty section")
  }

  func testCategoryAndFollowingSkeletonsReserveMetadataLines() {
    let proposal = CGSize(width: 356, height: UIView.layoutFittingExpandedSize.height)
    let loading = UIHostingController(rootView: MobileFollowingRow(channel: LoadingSkeleton.channels[0]))
    for live in [false, true] {
      let loaded = UIHostingController(rootView: MobileFollowingRow(channel: channel("Streamer", live: live)))
      XCTAssertEqual(loading.sizeThatFits(in: proposal).height, loaded.sizeThatFits(in: proposal).height, accuracy: 1)
    }
    let categoryProposal = CGSize(width: 110, height: UIView.layoutFittingExpandedSize.height)
    let categoryLoading = UIHostingController(rootView: MobileCategoryCard(category: LoadingSkeleton.categories[0]))
    for viewers in [nil, 1200] as [Int?] {
      let category = TwitchCategory(id: "test", name: "Game", boxArtURL: nil, viewerCount: viewers)
      let loaded = UIHostingController(rootView: MobileCategoryCard(category: category))
      XCTAssertEqual(categoryLoading.sizeThatFits(in: categoryProposal).height,
                     loaded.sizeThatFits(in: categoryProposal).height, accuracy: 1)
    }
  }

  private func channel(_ name: String, category: String = "Just Chatting", live: Bool = true) -> FollowedChannel {
    FollowedChannel(id: name, login: name.lowercased(), displayName: name,
                    title: "A live stream with a longer title", gameName: category, viewerCount: 7500,
                    thumbnailURL: nil, profileImageURL: nil, isLive: live)
  }

  func testLiveHomeFollowsNeverIncludeAnonymousDemoOrOfflineChannels() {
    let channels = [channel("Live"), channel("Offline", live: false)]
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: false, isDemo: false, category: nil).isEmpty)
    XCTAssertTrue(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: true, category: nil).isEmpty)
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: nil).map(\.login), ["live"])
  }

  func testFollowingDirectoryIncludesOfflineChannelsWithoutAListLimit() {
    let channels = (0..<150).map { channel("Follow\($0)", live: $0.isMultiple(of: 2)) }
    let result = MobileHomeFeed.directory(channels, authenticated: true, category: nil)
    XCTAssertEqual(result.count, 150)
    XCTAssertEqual(result.filter { !$0.isLive }.count, 75)
    XCTAssertTrue(MobileHomeFeed.directory(channels, authenticated: false, category: nil).isEmpty)
  }

  func testHomePrioritizesMostWatchedAndFollowsBeforeDiscoveryWithoutDuplicates() {
    let date = Date(timeIntervalSince1970: 100)
    let history = [
      WatchHistoryEntry(login: "favorite", displayName: "Favorite", gameName: "Chat", viewerCount: nil,
                        lastWatchedAt: date, watchCount: 10),
      WatchHistoryEntry(login: "visited", displayName: "Visited", gameName: "Chat", viewerCount: nil,
                        lastWatchedAt: date, watchCount: 4)
    ]
    let result = MobileHomeFeed.homeChannels(
      follows: [channel("Follow"), channel("Favorite"), channel("Offline", live: false)],
      watched: [channel("Visited"), channel("FAVORITE")],
      recommendations: [channel("Discovery"), channel("Favorite")], history: history, category: nil)
    XCTAssertEqual(result.map(\.channelKey), ["favorite", "visited", "follow", "discovery"])
  }

  func testPersonalHomeCategoryFilterDoesNotReplaceFollowsWithGlobalPopularStreams() {
    let category = TwitchCategory(id: "minecraft", name: "Minecraft", boxArtURL: nil, viewerCount: nil)
    let result = MobileHomeFeed.homeChannels(
      follows: [channel("Mine", category: "MINECRAFT"), channel("Chat")],
      watched: [], recommendations: [channel("Suggested", category: "Minecraft")], history: [], category: category)
    XCTAssertEqual(result.map(\.login), ["mine", "suggested"])
    let offline = MobileHomeFeed.directory([channel("Offline", category: "Minecraft", live: false)],
                                          authenticated: true, category: category)
    XCTAssertEqual(offline.map(\.login), ["offline"])
  }

  func testMobileHistoryScopesDoNotReadOtherAccountsOrTheTVHistory() throws {
    let suffix = UUID().uuidString
    let firstKey = PersistenceKey.mobileWatchHistory(accountID: "first-\(suffix)")
    let secondKey = PersistenceKey.mobileWatchHistory(accountID: "second-\(suffix)")
    let entries = [WatchHistoryEntry(login: "favorite", displayName: "Favorite", gameName: "Game",
      viewerCount: nil, lastWatchedAt: Date(), watchCount: 8)]
    Defaults.save(entries, forKey: firstKey)
    defer { UserDefaults.standard.removeObject(forKey: firstKey) }
    XCTAssertEqual(WatchHistoryService(storageKey: firstKey).entries.first?.watchCount, 8)
    XCTAssertTrue(WatchHistoryService(storageKey: secondKey).entries.isEmpty)
    XCTAssertNotEqual(firstKey, PersistenceKey.watchHistoryEntries)
  }

  func testFollowingCategoryFilterUsesActualLiveFollows() {
    let category = TwitchCategory(id: "chat", name: "Just Chatting", boxArtURL: nil, viewerCount: nil)
    let channels = [channel("Chat", category: "JUST CHATTING"), channel("Game", category: "Minecraft")]
    XCTAssertEqual(MobileHomeFeed.visibleFollows(channels, authenticated: true, isDemo: false, category: category).map(\.login), ["chat"])
  }

  func testSignedInHomeComponentsRenderWithoutAccountOrNetworkAccess() async throws {
    let channels = ["Ludwig", "xQc", "Valkyrae", "Extra", "Another", "Last"].map { channel($0) }
      + [channel("Offline channel", live: false)]
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

  func testRestoringFollowingUsesNeutralPlaceholder() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let content = MobileFollowingContent(authenticated: false, isRestoringAccount: true,
      channels: [], isLoading: false, errorMessage: nil, filtered: false,
      onAccount: { XCTFail("Account restoration must not offer sign-in") }, onRetry: {}, onSelect: { _ in })
      .padding()
    let controller = UIHostingController(rootView: content)
    window.rootViewController = controller
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Following account restoration"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
