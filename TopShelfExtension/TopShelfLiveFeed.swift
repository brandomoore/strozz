import Foundation
import OSLog

/// Fetches fresh Twitch and Kick live status directly from the Top Shelf
/// extension process so the shelf reflects what is live *right now* instead of a
/// snapshot the app cached the last time it was open.
///
/// This is deliberately small and dependency-free to respect the extension's
/// tight memory/time budget. Every call is best-effort: any failure lets the
/// caller fall back to the last published snapshot.
enum TopShelfLiveFeed {
    private static let maxItemsPerSection = 12
    private static let helixBase = "https://api.twitch.tv/helix"

    /// Refreshes providers independently; one expired session must not prevent
    /// public Kick status from updating. An empty result means confirmed offline,
    /// while cancellation returns nil so the caller can retain its snapshot.
    static func run(
        credentials: TopShelfCredentials?,
        recommended: TopShelfSnapshot.Section?,
        following: TopShelfSnapshot.Section? = nil
    ) async -> [TopShelfSnapshot.Section]? {
        let cachedFollowing = TopShelfSnapshot.sourceItems(in: following?.items ?? [])
        let cachedRecommended = TopShelfSnapshot.sourceItems(in: recommended?.items ?? [])
        let knownItems = cachedFollowing + cachedRecommended
        async let refreshedKickFollowing = refreshKick(cachedFollowing)
        async let refreshedKickRecommended = refreshKick(cachedRecommended)
        var followingItems = cachedFollowing.filter { $0.sourcePlatform != "kick" }
        if let credentials {
            do { followingItems = try await followedLive(credentials) }
            catch {
                Logger(subsystem: "com.thatcube.Strozz", category: "top-shelf")
                    .warning("Twitch following refresh failed; preserving snapshot: \((error as NSError).code)")
            }
        }

        var sections: [TopShelfSnapshot.Section] = []
        let kickFollowing = await refreshedKickFollowing
        let primaryItems = Array(TopShelfSnapshot.mergingCreators(followingItems + kickFollowing, knownItems: knownItems)
            .sorted { ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) }.prefix(maxItemsPerSection))
        if !primaryItems.isEmpty {
            sections.append(
                TopShelfSnapshot.Section(
                    id: following?.id ?? "following",
                    title: following?.title ?? "Following · Live now",
                    items: primaryItems
                )
            )
        }

        // Recommended — refresh the liveness/thumbnails of the last published
        // recommended set, dropping any channel that has since gone offline.
        if recommended != nil {
            let primaryLogins = Set(primaryItems.map(\.identityKey))
            var twitch = cachedRecommended.filter { $0.sourcePlatform != "kick" }
            if let credentials {
                do { twitch = try await liveStreams(forLogins: twitch.map(\.login), credentials).map(item(from:)) }
                catch {
                    Logger(subsystem: "com.thatcube.Strozz", category: "top-shelf")
                        .warning("Twitch recommendations refresh failed; preserving snapshot: \((error as NSError).code)")
                }
            }
            let kick = await refreshedKickRecommended
            let items = TopShelfSnapshot.mergingCreators(twitch + kick, knownItems: knownItems)
                .filter { !primaryLogins.contains($0.identityKey) }
                .sorted { ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) }
                .prefix(maxItemsPerSection)
            if !items.isEmpty {
                sections.append(
                    TopShelfSnapshot.Section(
                        id: "recommended",
                        title: "Recommended",
                        items: Array(items)
                    )
                )
            }
        }

        return Task.isCancelled ? nil : sections
    }

    // MARK: - Endpoints

    private static func refreshKick(_ items: [TopShelfSnapshot.Item]) async -> [TopShelfSnapshot.Item] {
        await withTaskGroup(of: TopShelfSnapshot.Item?.self) { group in
            var iterator = items.filter { $0.sourcePlatform == "kick" }.prefix(maxItemsPerSection).makeIterator()
            func enqueue(_ item: TopShelfSnapshot.Item) {
                group.addTask {
                    do {
                        var components = URLComponents(string: "https://kick.com")!
                        components.path = "/api/v1/channels/\(item.login)"
                        var request = URLRequest(url: components.url!)
                        request.timeoutInterval = 6
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("Strozz tvOS TopShelf", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        try Task.checkCancellation()
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1024 * 1024,
                              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              document["livestream"] != nil,
                              (document["slug"] as? String)?.lowercased() == item.login.lowercased()
                        else { throw URLError(.badServerResponse) }
                        guard let live = document["livestream"] as? [String: Any] else {
                            if document["livestream"] is NSNull { return nil }
                            throw URLError(.badServerResponse)
                        }
                        var updated = item
                        updated.title = live["session_title"] as? String ?? item.title
                        updated.viewerCount = live["show_view_count"] as? Bool == false
                            ? nil : live["viewer_count"] as? Int
                        updated.gameName = (live["categories"] as? [[String: Any]])?.first?["name"] as? String ?? item.gameName
                        updated.thumbnailURL = ((live["thumbnail"] as? [String: Any])?["url"] as? String)
                            .flatMap(URL.init(string:)) ?? item.thumbnailURL
                        return updated
                    } catch {
                        if Task.isCancelled { return nil }
                        Logger(subsystem: "com.thatcube.Strozz", category: "top-shelf")
                            .warning("Kick refresh failed; preserving snapshot: \((error as NSError).code)")
                        return item
                    }
                }
            }
            for _ in 0..<4 { if let item = iterator.next() { enqueue(item) } }
            var result: [TopShelfSnapshot.Item] = []
            for await item in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let item { result.append(item) }
                if let next = iterator.next() { enqueue(next) }
            }
            return result
        }
    }

    private static func followedLive(
        _ credentials: TopShelfCredentials
    ) async throws -> [TopShelfSnapshot.Item] {
        var components = URLComponents(string: "\(helixBase)/streams/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: credentials.userID),
            URLQueryItem(name: "first", value: "\(maxItemsPerSection)")
        ]

        let streams = try await getStreams(url: components.url!, credentials)
        return streams.filter { $0.type == "live" }.map(item(from:))
    }

    private static func liveStreams(
        forLogins ids: [String],
        _ credentials: TopShelfCredentials
    ) async throws -> [Stream] {
        let capped = Array(Set(ids)).prefix(100)
        guard !capped.isEmpty else { return [] }

        var components = URLComponents(string: "\(helixBase)/streams")!
        components.queryItems = [URLQueryItem(name: "first", value: "100")]
        components.queryItems?.append(
            contentsOf: capped.map { URLQueryItem(name: "user_login", value: $0) }
        )

        let streams = try await getStreams(url: components.url!, credentials)
        return streams.filter { $0.type == "live" }
    }

    /// Performs a Helix GET with the access token last published by the main app.
    /// On 401 the caller falls back to the cached shelf instead of letting this
    /// short-lived extension process rotate the canonical refresh token.
    private static func getStreams(
        url: URL,
        _ credentials: TopShelfCredentials
    ) async throws -> [Stream] {
        try await decodeStreams(url: url, credentials: credentials)
    }

    private static func decodeStreams(
        url: URL,
        credentials: TopShelfCredentials
    ) async throws -> [Stream] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.clientID, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Strozz/0.1 tvOS TopShelf", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw HTTPError(status: status) }

        return try JSONDecoder().decode(StreamsEnvelope.self, from: data).data
    }

    // MARK: - Mapping

    private static func item(from stream: Stream) -> TopShelfSnapshot.Item {
        let thumbnail = stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "640")
            .replacingOccurrences(of: "{height}", with: "360")

        return TopShelfSnapshot.Item(
            id: stream.userLogin.lowercased(),
            login: stream.userLogin.lowercased(),
            displayName: stream.userName,
            title: stream.title,
            gameName: stream.gameName,
            thumbnailURL: URL(string: thumbnail),
            viewerCount: stream.viewerCount
        )
    }

    // MARK: - Wire models

    struct Stream: Decodable {
        let userID: String
        let userLogin: String
        let userName: String
        let gameName: String
        let title: String
        let viewerCount: Int
        let thumbnailURL: String
        let type: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case userLogin = "user_login"
            case userName = "user_name"
            case gameName = "game_name"
            case title
            case viewerCount = "viewer_count"
            case thumbnailURL = "thumbnail_url"
            case type
        }
    }

    private struct StreamsEnvelope: Decodable {
        let data: [Stream]
    }

    private struct HTTPError: Error {
        let status: Int
    }
}
