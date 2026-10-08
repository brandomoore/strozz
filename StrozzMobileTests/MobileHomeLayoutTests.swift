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
