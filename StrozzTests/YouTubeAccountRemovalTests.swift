import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

final class YouTubeAccountRemovalTests: XCTestCase {
  func testRemovalIsScopedAndRepeatable() throws {
    let suite = "YouTubeAccountRemovalTests.\(UUID().uuidString)"
    let shared = try XCTUnwrap(UserDefaults(suiteName: suite + ".shared"))
    let standard = try XCTUnwrap(UserDefaults(suiteName: suite + ".standard"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      shared.removePersistentDomain(forName: suite + ".shared")
      standard.removePersistentDomain(forName: suite + ".standard")
      try? FileManager.default.removeItem(at: directory)
    }
    let retiredKeys = [
      "youtube.auth.accessToken", "youtube.auth.refreshToken", "youtube.auth.expiry",
      "youtube.auth.displayName", "youtube.auth.profileImageURL",
      "showYouTubeSubscriptions", "youTubeSubscriptionsLastFetch",
    ]
    for defaults in [shared, standard] {
      for key in retiredKeys { defaults.set("fixture", forKey: key) }
      defaults.set("keep", forKey: "twitch.auth.accessToken")
      defaults.set(true, forKey: PersistenceKey.preferYouTubeSource)
      defaults.set("keep", forKey: PersistenceKey.watchHistoryEntries)
      defaults.set("keep", forKey: PersistenceKey.twitchYouTubeAliasETag)
    }
    let cache = directory.appendingPathComponent("YouTubeSubscriptions.cache.json")
    let publicData = directory.appendingPathComponent("YouTubeLive.json")
    try Data("[]".utf8).write(to: cache)
    try Data("public".utf8).write(to: publicData)

    for _ in 0..<2 {
      try YouTubeAccountRemoval.remove(shared: shared, standard: standard, applicationSupport: directory)
      for defaults in [shared, standard] {
        for key in retiredKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "twitch.auth.accessToken"), "keep")
        XCTAssertTrue(defaults.bool(forKey: PersistenceKey.preferYouTubeSource))
        XCTAssertEqual(defaults.string(forKey: PersistenceKey.watchHistoryEntries), "keep")
        XCTAssertEqual(defaults.string(forKey: PersistenceKey.twitchYouTubeAliasETag), "keep")
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
      XCTAssertEqual(try Data(contentsOf: publicData), Data("public".utf8))
    }
  }
}
