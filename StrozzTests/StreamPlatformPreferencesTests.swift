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
}
