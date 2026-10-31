import Foundation
import Observation

@MainActor
@Observable
final class SearchService {
    private(set) var channelResults: [FollowedChannel] = []
    private(set) var categoryResults: [TwitchCategory] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var query = ""
    private(set) var platformFilter = BrowsePlatformFilter.all
    private var requestID = UUID()
    private let loadData: NetworkClient.DataLoader
    private let loadKickSearch: @Sendable (String) async throws -> KickBrowseService.SearchPage
    private let creatorLinks: [String: String]?

    init(creatorLinks: [String: String]? = nil,
         loadData: @escaping NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) },
         loadKickSearch: @escaping @Sendable (String) async throws -> KickBrowseService.SearchPage = {
             try await KickBrowseService.search($0)
         }) {
        self.loadData = loadData
        self.loadKickSearch = loadKickSearch
        self.creatorLinks = creatorLinks
    }

    var hasResults: Bool { !channelResults.isEmpty || !categoryResults.isEmpty }

    // MARK: - Public API

    func clear() {
        requestID = UUID()
        query = ""
        channelResults = []
        categoryResults = []
        errorMessage = nil
        isSearching = false
    }

    func search(_ rawQuery: String, preservingResultsOnFailure: Bool = false,
                filter: BrowsePlatformFilter = .all) async {
        let currentRequestID = UUID()
        requestID = currentRequestID
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        platformFilter = filter
        channelResults = channelResults.filter { filter.includes($0.platform) }.map { channel in
            var channel = channel
            if !filter.includes(.kick) { channel.kick = nil }
            return channel
        }
        categoryResults = categoryResults.filter { filter.includes($0.platform) }
        let previousKickChannels = channelResults.filter { $0.platform == .kick }
        let previousKickCategories = categoryResults.filter { $0.platform == .kick }

        guard !trimmed.isEmpty else {
            channelResults = []
            categoryResults = []
            errorMessage = nil
            isSearching = false
            return
        }

        isSearching = true
        errorMessage = nil
        defer {
            if requestID == currentRequestID { isSearching = false }
        }

        async let kick = kickResult(for: trimmed, enabled: filter.includes(.kick))
        do {
            let results = filter.includes(.twitch) ? try await fetchSearchResults(for: trimmed)
                : SearchResults(channels: [], categories: [])
            // Ignore stale responses if the query changed while in flight.
            guard !Task.isCancelled, requestID == currentRequestID, query == trimmed else { return }
            channelResults = results.channels + (preservingResultsOnFailure ? previousKickChannels : [])
            categoryResults = results.categories + (preservingResultsOnFailure ? previousKickCategories : [])
            prewarmStaticArtwork(channels: results.channels, categories: results.categories)
        } catch {
            guard !Task.isCancelled, requestID == currentRequestID, query == trimmed else { return }
            if !preservingResultsOnFailure {
                channelResults = []
                categoryResults = []
            }
            errorMessage = "Could not search right now."
        }
        let kickResult = await kick
        guard !Task.isCancelled, requestID == currentRequestID, query == trimmed else { return }
        switch kickResult {
        case .success(let result):
            channelResults.removeAll { $0.platform == .kick }
            categoryResults.removeAll { $0.platform == .kick }
            channelResults.append(contentsOf: result.channels)
            categoryResults.append(contentsOf: result.categories)
            if let warning = result.warning {
                errorMessage = [errorMessage, warning].compactMap { $0 }.joined(separator: "\n")
            }
        case .failure(let error):
            errorMessage = [errorMessage,
                String(localized: "Kick search is unavailable: \(error.localizedDescription)")]
                .compactMap { $0 }.joined(separator: "\n")
        }
        let twitch = channelResults.filter { $0.platform == .twitch }
        channelResults = KickUnifiedFeed.mergeDirectory(twitch: twitch,
            kick: channelResults.filter { $0.platform == .kick },
            links: creatorLinks ?? KickUnifiedFeed.confirmedLinks(for: twitch))
        if !hasResults, errorMessage == nil { errorMessage = "No results for \"\(trimmed)\"." }
    }

    private func kickResult(for query: String, enabled: Bool) async -> Result<KickBrowseService.SearchPage, Error> {
        let empty = KickBrowseService.SearchPage(channels: [], categories: [])
        guard enabled else { return .success(empty) }
        let term = (try? KickPlaybackService.slug(from: query)) ?? query
        do { return .success(try await loadKickSearch(term)) }
        catch KickBrowseService.Failure.searchTooShort {
            return .success(.init(channels: [], categories: [],
                                  warning: KickBrowseService.Failure.searchTooShort.localizedDescription))
        }
        catch KickPlaybackService.Failure.notFound { return .success(empty) }
        catch { return .failure(error) }
    }

    /// Warm the decoded-image cache for the *static* artwork search results show —
    /// channel avatars and category box art — so the results grids paint each tile
    /// instantly instead of decoding on the fly as they scroll. Live stream
    /// preview thumbnails (`FollowedChannel.thumbnailURL`) are deliberately never
    /// prewarmed: they must always reflect the current moment. Best-effort and low
    /// priority.
    private func prewarmStaticArtwork(channels: [FollowedChannel], categories: [TwitchCategory]) {
        let urls = channels.compactMap(\.profileImageURL)
            + categories.compactMap(\.boxArtURL)
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if Task.isCancelled { return }
                await ImageMemoryCache.shared.prewarm(url)
            }
        }
    }

    // MARK: - GQL: searchFor

    private struct SearchResults {
        let channels: [FollowedChannel]
        let categories: [TwitchCategory]
    }

    private func fetchSearchResults(for query: String) async throws -> SearchResults {
        struct StreamNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let previewImageURL: String?
            let game: GameRef?

            struct GameRef: Decodable { let name: String? }
        }
        struct UserItem: Decodable {
            let id: String?
            let login: String?
            let displayName: String?
            let profileImageURL: String?
            let stream: StreamNode?
        }
        struct GameItem: Decodable {
            let id: String?
            let name: String?
            let boxArtURL: String?
            let viewersCount: Int?
        }
        struct ChannelEdge: Decodable { let item: UserItem? }
        struct GameEdge: Decodable { let item: GameItem? }
        struct ChannelsConn: Decodable { let edges: [ChannelEdge]? }
        struct GamesConn: Decodable { let edges: [GameEdge]? }
        struct SearchFor: Decodable {
            let channels: ChannelsConn?
            let games: GamesConn?
        }
        struct GQLData: Decodable { let searchFor: SearchFor? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        let gqlQuery = """
            query Search($query: String!) {
              searchFor(userQuery: $query, platform: "web", options: null) {
                channels {
                  edges {
                    item {
                      ... on User {
                        id
                        login
                        displayName
                        profileImageURL(width: 70)
                        stream {
                          id
                          title
                          viewersCount
                          previewImageURL(width: 640, height: 360)
                          game { name }
                        }
                      }
                    }
                  }
                }
                games {
                  edges {
                    item {
                      ... on Game {
                        id
                        name
                        boxArtURL(width: 285, height: 380)
                        viewersCount
                      }
                    }
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(
            query: gqlQuery, variables: ["query": query])
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        let searchFor = decoded.data?.searchFor

        let channels: [FollowedChannel] = (searchFor?.channels?.edges ?? []).compactMap { edge in
            guard let item = edge.item,
                  let login = item.login?.trimmingCharacters(in: .whitespaces),
                  !login.isEmpty
            else { return nil }

            let displayName = item.displayName?.trimmingCharacters(in: .whitespaces) ?? login
            let profileURL = item.profileImageURL.flatMap { URL(string: $0) }
            let stream = item.stream
            let isLive = stream != nil
            let title = stream?.title?.trimmingCharacters(in: .whitespaces) ?? ""
            let previewURL = stream?.previewImageURL.flatMap { URL(string: $0) }

            return FollowedChannel(
                id: item.id ?? login,
                login: login,
                displayName: displayName,
                title: title,
                gameName: stream?.game?.name ?? "",
                viewerCount: stream?.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: profileURL,
                isLive: isLive
            )
        }

        let categories: [TwitchCategory] = (searchFor?.games?.edges ?? []).compactMap { edge in
            guard let item = edge.item,
                  let id = item.id,
                  let name = item.name?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { return nil }

            return TwitchCategory(
                id: id,
                name: name,
                boxArtURL: item.boxArtURL.flatMap { URL(string: $0) },
                viewerCount: item.viewersCount
            )
        }

        return SearchResults(channels: channels, categories: categories)
    }

    // MARK: - GQL Transport

    private func performGQL(query: String, variables: [String: Any]) async throws -> Data {
        var req = TwitchAPIClient.graphQLRequest(userAgent: TwitchConfig.apiUserAgent)
        req.httpBody = try JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: variables))

        let (data, response) = try await loadData(req)
        return try TwitchAPIClient.validatedData(data, response)
    }
}
