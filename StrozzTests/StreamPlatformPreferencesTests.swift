import SwiftUI
import XCTest

#if os(tvOS)
  @testable import Strozz
#else
  @testable import StrozzMobile
#endif

@MainActor
final class StreamPlatformPreferencesTests: XCTestCase {
  func testFirstChoicePersistsWithoutChangingSavedAccounts() throws {
    let name = "StreamPlatformPreferencesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("saved-account", forKey: "account-fixture")
    let preferences = StreamPlatformPreferences(defaults: defaults, shelfDefaults: defaults)
    XCTAssertFalse(preferences.hasChosen)
    XCTAssertEqual(preferences.selection, .both)
    preferences.completeOnboarding(.kick)
    XCTAssertTrue(preferences.hasChosen)
    XCTAssertEqual(defaults.string(forKey: "account-fixture"), "saved-account")
    let restored = StreamPlatformPreferences(defaults: defaults, shelfDefaults: defaults)
    XCTAssertTrue(restored.hasChosen)
    XCTAssertEqual(restored.selection, .kick)
    XCTAssertEqual(defaults.string(forKey: BrowsePlatformFilter.storageKey), "kick")
    restored.selection = .both
    XCTAssertEqual(defaults.string(forKey: BrowsePlatformFilter.storageKey), "all")
  }

  func testEverySelectionIncludesAtLeastOneServiceAndLeavesYouTubeAvailable() {
    for selection in StreamPlatforms.allCases {
      XCTAssertTrue(selection.includesTwitch || selection.includesKick)
      XCTAssertTrue(selection.includes(.youtube))
    }
    XCTAssertEqual(StreamPlatforms.twitch.resolve(.kick), .twitch)
    XCTAssertEqual(StreamPlatforms.kick.resolve(.twitch), .kick)
    XCTAssertEqual(StreamPlatforms.both.resolve(.all), .all)
  }

  func testSingleProviderCardsKeepOnlyItsCountsAndIdentity() {
    var channel = FollowedChannel(
      id: "one", login: "one", displayName: "One",
      title: "", gameName: "", viewerCount: 30, thumbnailURL: nil, profileImageURL: nil,
      isLive: true)
    channel.kick = KickChannel(
      slug: "one-kick", displayName: "One", title: "", category: "",
      viewerCount: 40, isLive: true, chatroomID: nil, imageURL: nil)
    let twitch = StreamPlatforms.twitch.filter([channel])
    XCTAssertEqual(twitch.map(\.channelKey), ["one"])
    XCTAssertNil(twitch.first?.kick)
    XCTAssertEqual(twitch.first?.combinedViewerCount, 30)
    let kick = StreamPlatforms.kick.filter([channel])
    XCTAssertEqual(kick.map(\.channelKey), ["kick:one-kick"])
    XCTAssertEqual(kick.first?.combinedViewerCount, 40)
    XCTAssertEqual(StreamPlatforms.both.filter([channel]).first?.combinedViewerCount, 70)
  }

  func testFilteringCreatorLinksDoesNotEraseDisabledAccounts() {
    var saved = CreatorLiveSources(root: .init(platform: .kick, channel: "one-kick"))
    saved.twitch = "one"
    saved.youtube = "@one"
    let visible = StreamPlatforms.kick.filter(saved)
    XCTAssertEqual(visible.targets.map(\.platform), [.kick, .youtube])
    XCTAssertEqual(saved.twitch, "one")
    XCTAssertEqual(StreamPlatforms.both.filter(saved), saved)
  }

  func testTopShelfFiltersIndividualSourcesBeforeCombiningCounts() {
    let twitch = TopShelfSnapshot.Item(
      id: "one", login: "one", displayName: "One",
      title: "", gameName: "", thumbnailURL: nil, viewerCount: 30, sourcePlatform: "twitch",
      creatorKey: "one")
    let kick = TopShelfSnapshot.Item(
      id: "kick:one-kick", login: "one-kick", displayName: "One",
      title: "", gameName: "", thumbnailURL: nil, viewerCount: 40, sourcePlatform: "kick",
      creatorKey: "one")
    let snapshot = TopShelfSnapshot(sections: [
      .init(
        id: "following", title: "Following",
        items: TopShelfSnapshot.mergingCreators([twitch, kick]))
    ])
    let kickOnly = snapshot.filtering(.kick)
    XCTAssertEqual(kickOnly.sections.first?.items.first?.sourcePlatform, "kick")
    XCTAssertEqual(kickOnly.sections.first?.items.first?.viewerCount, 40)
    XCTAssertNil(kickOnly.sections.first?.items.first?.sources)
    XCTAssertEqual(snapshot.filtering(.twitch).sections.first?.items.first?.viewerCount, 30)
    XCTAssertEqual(snapshot.filtering(.both), snapshot)
  }

  func testHiddenWatchHistorySurvivesRecordingOnTheOtherPlatform() {
    let preferences = StreamPlatformPreferences.shared
    let previous = preferences.selection
    let key = "platform-history-fixture-\(UUID().uuidString)"
    let history = WatchHistoryService(storageKey: key)
    defer {
      preferences.selection = previous
      history.clear()
    }
    preferences.selection = .both
    let twitch = FollowedChannel(
      id: "one", login: "one", displayName: "One",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil,
      isLive: true)
    var kick = twitch
    kick.platform = .kick
    history.record(twitch)
    preferences.selection = .kick
    XCTAssertTrue(history.entries.isEmpty)
    history.record(kick)
    XCTAssertEqual(history.entries.map(\.platform), [.kick])
    preferences.selection = .both
    XCTAssertEqual(Set(history.entries.map(\.platform)), [.twitch, .kick])
  }

  func testOnboardingResolvesNativeAppearanceAndFillsSafeAreas() async throws {
    let name = "platform-appearance-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = StreamPlatformPreferences(defaults: defaults, shelfDefaults: nil)
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    defer { previousKeyWindow?.makeKey() }

    for theme in AppTheme.allCases {
      for style in [UIUserInterfaceStyle.light, .dark] {
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(
          rootView: StreamPlatformOnboardingView(preferences: preferences, theme: theme))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
          window.isHidden = true
          window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image {
          _ in
          host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Platform onboarding \(theme.rawValue) native-\(style.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let light = theme == .light || (theme == .system && style == .light)
        let bitmap = try XCTUnwrap(image.cgImage)
        for x in [8, bitmap.width - 9] {
          for y in [8, bitmap.height / 2, bitmap.height - 9] {
            let pixel = try backgroundPixel(bitmap, x: x, y: y)
            XCTAssertEqual(pixel[3], 255, "The backdrop must cover the entire screen")
            for component in pixel.prefix(3) {
              if light {
                XCTAssertGreaterThan(component, 220)
              } else {
                XCTAssertLessThan(component, 70)
              }
            }
          }
        }
      }
    }
  }

  private func backgroundPixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    let sample = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
    var pixel = [UInt8](repeating: 0, count: 4)
    try pixel.withUnsafeMutableBytes { bytes in
      let context = try XCTUnwrap(
        CGContext(
          data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return pixel
  }
}
