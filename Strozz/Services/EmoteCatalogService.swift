import Foundation
import OSLog

actor EmoteCatalogService {
    static let shared = EmoteCatalogService()

    struct Catalog: Sendable {
        let urls: [String: URL]
        let needsRetry: Bool
    }

    private enum Failure: Error {
        case http(Int)
        case malformedResponse
    }

    private let clientID = TwitchConfig.webPublicClientID
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    private let load: NetworkClient.DataLoader
    private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "EmoteCatalog")

    private var cache = BoundedCache<String, [String: URL]>(capacity: 256, ttl: 1800)
    private var userIDs = BoundedCache<String, String>(capacity: 48, ttl: 1800)
    private var generation = UUID()

    init(load: @escaping NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }) {
        self.load = load
    }

    func catalog(for channel: String) async -> [String: URL] {
        await snapshot(for: channel).urls
    }

    func snapshot(for channel: String, refreshChannelEmotes: Bool = false) async -> Catalog {
        let key = channel.lowercased()
        let userID = await twitchUserID(for: key)

        async let twitchGlobal = source("twitch-global") { try await self.fetchTwitchGlobal() }
        async let sevenTVGlobal = source("7tv-global") { try await self.fetch7TVGlobal() }
        async let bttvGlobal = source("bttv-global") { try await self.fetchBTTVGlobal() }
        async let ffzGlobal = source("ffz-global") { try await self.fetchFFZGlobal() }

        async let twitchChannel = source("twitch:\(key)") { try await self.fetchTwitchChannel(login: key) }
        async let sevenTVChannel = source("7tv:\(key)", refresh: refreshChannelEmotes) {
            try await self.fetch7TVChannel(twitchUserID: userID)
        }
        async let bttvChannel = source("bttv:\(key)") { try await self.fetchBTTVChannel(twitchUserID: userID) }
        async let ffzChannel = source("ffz:\(key)") { try await self.fetchFFZChannel(channel: key) }

        let sources = await [
            twitchGlobal, sevenTVGlobal, bttvGlobal, ffzGlobal,
            twitchChannel, sevenTVChannel, bttvChannel, ffzChannel,
        ]
        return Self.combine(sources, needsRetry: userID == nil)
    }

    /// Fetches only the provider-global emote sets (7TV, BTTV, FFZ) with no
    /// channel context. Useful outside of a channel, e.g. the sign-in screen.
    func globalCatalog() async -> [String: URL] {
        async let twitchGlobal = source("twitch-global") { try await self.fetchTwitchGlobal() }
        async let sevenTVGlobal = source("7tv-global") { try await self.fetch7TVGlobal() }
        async let bttvGlobal = source("bttv-global") { try await self.fetchBTTVGlobal() }
        async let ffzGlobal = source("ffz-global") { try await self.fetchFFZGlobal() }
        return Self.combine(await [twitchGlobal, sevenTVGlobal, bttvGlobal, ffzGlobal]).urls
    }

    /// Drops all cached catalogs (e.g. on sign-out).
    func clear() {
        generation = UUID()
        cache.removeAll()
        userIDs.removeAll()
    }

    private static func combine(_ sources: [[String: URL]?], needsRetry: Bool = false) -> Catalog {
        var merged: [String: URL] = [:]
        for source in sources {
            if let source { merged.merge(source) { _, new in new } }
        }
        return Catalog(urls: merged, needsRetry: needsRetry || sources.contains { $0 == nil })
    }

    private func source(
        _ key: String, refresh: Bool = false, operation: () async throws -> [String: URL]
    ) async -> [String: URL]? {
        if !refresh, let cached = cache.value(forKey: key) { return cached }
        let attempt = generation
        do {
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            cache.insert(result, forKey: key)
            return result
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                // Only the provider and a fixed error category, never chat text or response bodies.
                let provider = String(key.prefix { $0 != ":" })
                Self.logger.warning("Emote source \(provider, privacy: .public) unavailable: \(Self.reason(error), privacy: .public)")
            }
            return nil
        }
    }

    private func twitchUserID(for login: String) async -> String? {
        if let cached = userIDs.value(forKey: login) { return cached }
        let attempt = generation
        var req = TwitchAPIClient.graphQLRequest(
            clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)

        let query = "query UserID($login: String!) { user(login: $login) { id } }"
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["login": login]))

        do {
            guard let json = try await fetchJSON(request: req) as? [String: Any],
                  let data = json["data"] as? [String: Any],
                  let user = data["user"] as? [String: Any],
                  let id = user["id"] as? String, !id.isEmpty else { throw Failure.malformedResponse }
            try Task.checkCancellation()
            guard generation == attempt else { return nil }
            userIDs.insert(id, forKey: login)
            return id
        } catch {
            if !Task.isCancelled {
                Self.logger.warning("Emote channel lookup unavailable: \(Self.reason(error), privacy: .public)")
            }
            return nil
        }
    }

    /// Twitch's first-party global emotes (Kappa, LUL, PogChamp, …) via the
    /// public web GQL endpoint. Emote set "0" is the global set.
    private func fetchTwitchGlobal() async throws -> [String: URL] {
        let query = "query { emoteSet(id: \"0\") { emotes { id token } } }"
        guard let json = try await fetchTwitchGQL(query: query) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let emoteSet = data["emoteSet"] as? [String: Any],
              let emotes = emoteSet["emotes"] as? [[String: Any]] else { throw Failure.malformedResponse }
        return parseTwitchEmotes(emotes)
    }

    /// A channel's first-party subscriber/bit emotes (e.g. `alveusCheer`). These
    /// only resolve on Twitch via the IRC `emotes` tag, so fetching them by name
    /// lets them render when typed on YouTube too.
    private func fetchTwitchChannel(login: String) async throws -> [String: URL] {
        let query = "query ChannelEmotes($login: String!) { user(login: $login) { subscriptionProducts { emotes { id token } } } }"
        guard let json = try await fetchTwitchGQL(query: query, variables: ["login": login]) as? [String: Any],
              let data = json["data"] as? [String: Any],
              let user = data["user"] as? [String: Any],
              let products = user["subscriptionProducts"] as? [[String: Any]] else { throw Failure.malformedResponse }

        var map: [String: URL] = [:]
        for product in products {
            guard let emotes = product["emotes"] as? [[String: Any]] else { continue }
            map.merge(parseTwitchEmotes(emotes)) { _, new in new }
        }
        return map
    }

    private func parseTwitchEmotes(_ list: [[String: Any]]) -> [String: URL] {
        var map: [String: URL] = [:]
        for emote in list {
            guard let token = emote["token"] as? String,
                  let id = emote["id"] as? String,
                  let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0") else { continue }
            map[token] = url
        }
        return map
    }

    private func fetchTwitchGQL(query: String, variables: [String: Any]? = nil) async throws -> Any? {
        var req = TwitchAPIClient.graphQLRequest(
            clientID: clientID, clientIDField: "Client-ID", userAgent: userAgent)
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

        return try await fetchJSON(request: req)
    }

    private func fetch7TVGlobal() async throws -> [String: URL] {
        let url = URL(string: "https://7tv.io/v3/emote-sets/global")!
        guard let json = try await fetchJSON(request: URLRequest(url: url)) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return try parse7TVEmoteSet(json)
    }

    private func fetch7TVChannel(twitchUserID: String?) async throws -> [String: URL] {
        guard let twitchUserID,
              let url = URL(string: "https://7tv.io/v3/users/twitch/\(twitchUserID)") else {
            throw Failure.malformedResponse
        }
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData)
        guard let response = try await fetchJSON(request: request, missingIsEmpty: true) else {
            return [:]
        }
        guard let json = response as? [String: Any] else { throw Failure.malformedResponse }
        if json["emote_set"] is NSNull { return [:] }
        guard let emoteSet = json["emote_set"] as? [String: Any] else { throw Failure.malformedResponse }
        return try parse7TVEmoteSet(emoteSet)
    }

    private func parse7TVEmoteSet(_ json: [String: Any]) throws -> [String: URL] {
        guard let emotes = json["emotes"] as? [[String: Any]] else { throw Failure.malformedResponse }
        var map: [String: URL] = [:]
        for emote in emotes {
            guard let name = emote["name"] as? String else { continue }
            let id = (emote["id"] as? String)
                ?? ((emote["data"] as? [String: Any])?["id"] as? String)
            guard let id, let url = URL(string: "https://cdn.7tv.app/emote/\(id)/2x.webp") else { continue }
            map[name] = url
        }
        return map
    }

    private func fetchBTTVGlobal() async throws -> [String: URL] {
        let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global")!
        guard let json = try await fetchJSON(request: URLRequest(url: url)) as? [[String: Any]] else {
            throw Failure.malformedResponse
        }
        return parseBTTVEmotes(json)
    }

    private func fetchBTTVChannel(twitchUserID: String?) async throws -> [String: URL] {
        guard let twitchUserID,
              let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(twitchUserID)") else {
            throw Failure.malformedResponse
        }
        guard let response = try await fetchJSON(request: URLRequest(url: url), missingIsEmpty: true) else {
            return [:]
        }
        guard let json = response as? [String: Any],
              let channelEmotes = json["channelEmotes"] as? [[String: Any]],
              let sharedEmotes = json["sharedEmotes"] as? [[String: Any]] else { throw Failure.malformedResponse }
        let channel = parseBTTVEmotes(channelEmotes)
        let shared = parseBTTVEmotes(sharedEmotes)
        return channel.merging(shared) { _, new in new }
    }

    private func parseBTTVEmotes(_ list: [[String: Any]]) -> [String: URL] {
        var map: [String: URL] = [:]
        for emote in list {
            guard let name = emote["code"] as? String,
                  let id = emote["id"] as? String,
                  let url = URL(string: "https://cdn.betterttv.net/emote/\(id)/2x") else { continue }
            map[name] = url
        }
        return map
    }

    private func fetchFFZGlobal() async throws -> [String: URL] {
        let url = URL(string: "https://api.frankerfacez.com/v1/set/global")!
        guard let json = try await fetchJSON(request: URLRequest(url: url)) as? [String: Any] else {
            throw Failure.malformedResponse
        }
        return try parseFFZSets(json)
    }

    private func fetchFFZChannel(channel: String) async throws -> [String: URL] {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/room/\(channel)") else {
            throw Failure.malformedResponse
        }
        guard let response = try await fetchJSON(request: URLRequest(url: url), missingIsEmpty: true) else {
            return [:]
        }
        guard let json = response as? [String: Any] else { throw Failure.malformedResponse }
        return try parseFFZSets(json)
    }

    private func parseFFZSets(_ json: [String: Any]) throws -> [String: URL] {
        guard let sets = json["sets"] as? [String: Any] else { throw Failure.malformedResponse }
        var map: [String: URL] = [:]

        for value in sets.values {
            guard let set = value as? [String: Any],
                  let emotes = set["emoticons"] as? [[String: Any]] else { continue }

            for emote in emotes {
                guard let name = emote["name"] as? String,
                      let urls = emote["urls"] as? [String: String] else { continue }
                let chosen = urls["4"] ?? urls["2"] ?? urls["1"]
                guard let chosen else { continue }
                let full = chosen.hasPrefix("//") ? "https:\(chosen)" : chosen
                guard let url = URL(string: full) else { continue }
                map[name] = url
            }
        }

        return map
    }

    private func fetchJSON(request: URLRequest, missingIsEmpty: Bool = false) async throws -> Any? {
        let load = load
        let data: Data? = try await NetworkClient.retrying(shouldRetry: { error in
            if let failure = error as? Failure, case .http(let status) = failure {
                return status == 429 || (500...599).contains(status)
            }
            if let error = error as? URLError { return error.code != .cancelled }
            return false
        }) {
            try Task.checkCancellation()
            let (data, response) = try await load(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw Failure.malformedResponse }
            if missingIsEmpty, response.statusCode == 404 { return nil }
            guard (200...299).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
            return data
        }
        guard let data else { return nil }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure.malformedResponse }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case Failure.http(let status): return "http_\(status)"
        case Failure.malformedResponse: return "unexpected_response"
        case let error as URLError: return "network_\(error.code.rawValue)"
        default: return "request_failed"
        }
    }
}
