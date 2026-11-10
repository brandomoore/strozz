import Foundation
import OSLog

/// Retires only local data from the removed YouTube account integration.
enum YouTubeAccountRemoval {
  static func run() {
    do {
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      try remove(
        shared: UserDefaults(suiteName: TopShelf.appGroupID) ?? .standard,
        standard: .standard, applicationSupport: directory)
    } catch {
      Logger(subsystem: "com.thatcube.Strozz", category: "migration")
        .error("Could not remove retired YouTube account data: \(error.localizedDescription, privacy: .public)")
    }
  }

  static func remove(shared: UserDefaults, standard: UserDefaults, applicationSupport: URL) throws {
    // Older builds used the standard suite if the App Group was unavailable.
    for defaults in [shared, standard] {
      for key in [
        PersistenceKey.youTubeAccessToken, PersistenceKey.youTubeRefreshToken,
        PersistenceKey.youTubeTokenExpiry, "youtube.auth.displayName", "youtube.auth.profileImageURL",
        PersistenceKey.showYouTubeSubscriptions, PersistenceKey.youTubeSubscriptionsLastFetch,
      ] {
        defaults.removeObject(forKey: key)
      }
    }
    do {
      try FileManager.default.removeItem(
        at: applicationSupport.appendingPathComponent("YouTubeSubscriptions.cache.json"))
    } catch let error as NSError where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError {
      // Fresh installs and subsequent launches have no retired cache.
    }
  }
}
