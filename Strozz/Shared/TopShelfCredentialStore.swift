import Foundation
import OSLog

/// The minimum Twitch credentials the Top Shelf extension needs to fetch fresh
/// live streams at render time.
struct TopShelfCredentials: Equatable, Codable {
    var clientID: String
    var accessToken: String
    var userID: String
}

/// Shares read-only Twitch credentials from the main app to Top Shelf through
/// an App Group Keychain item. Refresh tokens stay in the main app's Keychain.
///
/// The extension runs in a separate process and cannot see the app's in-memory
/// auth state. Only the main app rotates refresh tokens: an extension can be
/// terminated after Twitch spends a refresh token but before persistence, which
/// would irrecoverably lose the replacement token.
enum TopShelfCredentialStore {
    private static let service = "com.thatcube.Strozz.topshelf-auth"
    // Legacy defaults keys retained only for migration of existing installs.
    static let clientIDKey = "twitch.auth.clientID"
    static let accessTokenKey = "twitch.auth.accessToken"
    static let refreshTokenKey = "twitch.auth.refreshToken"
    static let userIDKey = "twitch.auth.userID"

    /// Shared App Group defaults. Falls back to `.standard` only if the suite is
    /// somehow unavailable (entitlement inactive), which keeps the app working.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: TopShelf.appGroupID) ?? .standard
    }

    /// The extension reads only the access token; it never rotates refresh tokens.
    static func load() -> TopShelfCredentials? {
        do {
            if let data = try CredentialKeychain.read(service: service, group: TopShelf.appGroupID) {
                return try JSONDecoder().decode(TopShelfCredentials.self, from: data)
            }
        } catch {
            Logger(subsystem: "com.thatcube.Strozz", category: "credentials").error("Top Shelf credentials unavailable")
            return nil
        }
        let defaults = defaults
        guard let clientID = nonEmpty(defaults.string(forKey: clientIDKey)),
              let accessToken = nonEmpty(defaults.string(forKey: accessTokenKey)),
              let userID = nonEmpty(defaults.string(forKey: userIDKey))
        else { return nil }

        return TopShelfCredentials(
            clientID: clientID,
            accessToken: accessToken,
            userID: userID
        )
    }

    static func save(_ credentials: TopShelfCredentials?) throws {
        if let credentials {
            try CredentialKeychain.write(JSONEncoder().encode(credentials), service: service, group: TopShelf.appGroupID)
        } else {
            try CredentialKeychain.remove(service: service, group: TopShelf.appGroupID)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
