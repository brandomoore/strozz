import XCTest
@testable import StrozzMobile

@MainActor
final class MobileVODProgressTests: XCTestCase {
  private var selection: MobileVODSelection {
    .init(video: .init(id: "123", title: "A broadcast", lengthSeconds: 3600,
                      thumbnailURL: nil, gameName: nil, publishedAt: nil, viewCount: 1),
          channel: .init(login: "fixture", displayName: "Fixture"))
  }

  func testResumePersistsAcrossRelaunchAndKeepsAccountsSeparate() throws {
    let name = "MobileVODProgress.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = MobileVODProgressStore(accountID: "first", defaults: defaults)
    first.save(selection, seconds: 125, duration: 3600)
    XCTAssertEqual(first.entries.first?.selection, selection)
    XCTAssertEqual(MobileVODProgressStore(accountID: "first", defaults: defaults).progress(for: "123"), 125)
    XCTAssertTrue(MobileVODProgressStore(accountID: "second", defaults: defaults).entries.isEmpty)
    first.clear()
    XCTAssertTrue(MobileVODProgressStore(accountID: "first", defaults: defaults).entries.isEmpty)
  }

  func testHiddenPlatformProgressSurvivesOtherPlatformCheckpoints() throws {
    let preferences = StreamPlatformPreferences.shared
    let previous = preferences.selection
    let name = "MobileVODProgress.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer {
      preferences.selection = previous
      defaults.removePersistentDomain(forName: name)
    }
    preferences.selection = .both
    let store = MobileVODProgressStore(accountID: "fixture", defaults: defaults)
    store.save(selection, seconds: 120, duration: 3600)
    preferences.selection = .kick
    XCTAssertTrue(store.entries.isEmpty)
    let video = ChannelVOD(id: "kick:456", title: "Kick broadcast", lengthSeconds: 3600,
      thumbnailURL: nil, gameName: nil, publishedAt: nil, viewCount: 1)
    let kick = MobileVODSelection(video: video, channel: .init(login: "fixture"))
    store.save(kick, seconds: 180, duration: 3600)
    XCTAssertEqual(store.entries.map(\.id), ["kick:456"])
    preferences.selection = .both
    let restored = MobileVODProgressStore(accountID: "fixture", defaults: defaults)
    XCTAssertEqual(restored.progress(for: "123"), 120)
    XCTAssertEqual(restored.progress(for: "kick:456"), 180)
    XCTAssertEqual(restored.entries.count, 2)
  }

  func testInvalidClockCannotOverwriteProgressAndCompletedBroadcastLeavesContinueWatching() throws {
    let name = "MobileVODProgress.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MobileVODProgressStore(accountID: "fixture", defaults: defaults)
    store.save(selection, seconds: 120, duration: 3600)
    for seconds in [Double.nan, .infinity, -1, 0] { store.save(selection, seconds: seconds, duration: 3600) }
    store.save(selection, seconds: 180, duration: .nan)
    XCTAssertEqual(store.progress(for: "123"), 120)
    store.save(selection, seconds: 3590, duration: 3600)
    XCTAssertTrue(store.entries.isEmpty)
  }

  func testRepeatedCheckpointsDoNotDuplicateContinueWatchingCards() throws {
    let name = "MobileVODProgress.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MobileVODProgressStore(accountID: "fixture", defaults: defaults)
    for seconds in stride(from: 15.0, to: 200, by: 15) { store.save(selection, seconds: seconds, duration: 3600) }
    XCTAssertEqual(store.entries.count, 1)
    XCTAssertEqual(store.entries.first?.seconds, 195)
  }
}
