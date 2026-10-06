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
