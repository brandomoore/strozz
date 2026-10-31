import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class BrowseService {
    private(set) var categories: [TwitchCategory] = []
    private(set) var isLoadingCategories = false
    private(set) var categoryErrorMessage: String?

    private(set) var categoryStreams: [FollowedChannel] = []
    private(set) var isLoadingStreams = false
    private(set) var streamsErrorMessage: String?
    private(set) var isLoadingMore = false
    private(set) var nextKickCursor: String?
    private(set) var moreStreamsErrorMessage: String?
    private var streamsCategoryID: String?
    private var categoriesContext: String?
    private var currentCategory: TwitchCategory?
    private var twitchStreams: [FollowedChannel] = []
    private var kickStreams: [FollowedChannel] = []
    private var streamsRequestID = UUID()
    private var categoriesRequestID = UUID()
    private let loadData: NetworkClient.DataLoader
    private let creatorLinks: [String: String]?
    private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "browse")

    init(creatorLinks: [String: String]? = nil,
         loadData: @escaping NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }) {
        self.loadData = loadData
        self.creatorLinks = creatorLinks
    }

    // MARK: - Public API

    func loadCategories(filter: BrowsePlatformFilter = .twitch) async {
        let requestID = UUID()
        categoriesRequestID = requestID
        isLoadingCategories = true
        categoryErrorMessage = nil
        let context = "\(filter.rawValue):\(StreamLanguagePreference.current())"
        if categoriesContext != context { categories = [] }
        categoriesContext = context
        defer { if categoriesRequestID == requestID { isLoadingCategories = false } }

        async let twitch = capture {
            filter.includes(.twitch) ? try await self.fetchTopCategories(limit: 40) : []
        }
        async let kick = capture {
            filter.includes(.kick)
                ? try await KickBrowseService.page(limit: 100, load: self.loadData).categories : []
        }
        let results = await (twitch, kick)
        guard !Task.isCancelled, categoriesRequestID == requestID else { return }
        var errors: [String] = []
        let twitchCategories = apply(results.0, previous: categories.filter { $0.platform == .twitch },
                                     platform: "Twitch", errors: &errors)
        let kickCategories = apply(results.1, previous: categories.filter { $0.platform == .kick },
                                   platform: "Kick", errors: &errors)
        categories = KickUnifiedFeed.interleave(twitchCategories, kickCategories, id: \.id)
        categoryErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        prewarmBoxArt(categories)
        recordFixtureState()
    }

    /// Warm the decoded-image cache for category box art right after the grid
    /// loads, so flicking through the Browse grid paints each tile instantly
    /// instead of decoding it on the fly as cards scroll in. Box art is static
    /// artwork, so caching it ahead is safe (unlike live stream thumbnails, which
    /// are never prewarmed). Best-effort and low priority; if the user scrolls
    /// first, `CachedAsyncImage` still loads on demand.
    private func prewarmBoxArt(_ categories: [TwitchCategory]) {
        let urls = categories.compactMap(\.boxArtURL)
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            for url in urls {
                if Task.isCancelled { return }
                await ImageMemoryCache.shared.prewarm(url)
            }
        }
    }

    func loadStreams(for category: TwitchCategory? = nil, filter: BrowsePlatformFilter = .twitch) async {
        let filter = category.map { $0.platform == .kick ? BrowsePlatformFilter.kick : .twitch } ?? filter
        let requestID = UUID()
        streamsRequestID = requestID
        isLoadingStreams = true
        streamsErrorMessage = nil
        isLoadingMore = false
        moreStreamsErrorMessage = nil
        nextKickCursor = nil
        let key = "\(category?.id ?? "directory"):\(filter.rawValue):\(StreamLanguagePreference.current())"
        if streamsCategoryID != key {
            categoryStreams = []
            twitchStreams = []
            kickStreams = []
        }
        streamsCategoryID = key
        currentCategory = category
        defer {
            if streamsRequestID == requestID { isLoadingStreams = false }
        }

        async let twitch = capture {
            guard filter.includes(.twitch) else { return [FollowedChannel]() }
            if let category { return try await self.fetchStreams(for: category, limit: 100) }
            return try await RecommendationsService.fetchRecommendedChannels(limit: 30, loadData: self.loadData)
        }
        async let kick = capture {
            guard filter.includes(.kick) else {
                return KickBrowseService.Page(channels: [], categories: [], nextCursor: nil)
            }
            return try await KickBrowseService.page(categoryID: category?.sourceID, load: self.loadData)
        }
        let results = await (twitch, kick)
        guard !Task.isCancelled, streamsRequestID == requestID else { return }
        var errors: [String] = []
        twitchStreams = apply(results.0, previous: twitchStreams, platform: "Twitch", errors: &errors)
        switch results.1 {
        case .success(let page):
            kickStreams = page.channels
            nextKickCursor = page.nextCursor
        case .failure(let error):
            errors.append(failureMessage(error, platform: "Kick"))
        }
        categoryStreams = mergedStreams()
        streamsErrorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        recordFixtureState()
    }

    func loadMoreStreams() async {
        guard !isLoadingStreams, !isLoadingMore, let cursor = nextKickCursor else { return }
        let requestID = streamsRequestID
        isLoadingMore = true
        moreStreamsErrorMessage = nil
        defer { if streamsRequestID == requestID { isLoadingMore = false } }
        do {
            let page = try await KickBrowseService.page(categoryID: currentCategory?.sourceID,
                                                        after: cursor, load: loadData)
            guard !Task.isCancelled, streamsRequestID == requestID else { return }
            var seen = Set(kickStreams.map(\.channelKey))
            let added = page.channels.filter { seen.insert($0.channelKey).inserted }
            kickStreams += added
            let merged = mergedStreams()
            let byID = Dictionary(merged.map { ($0.channelKey, $0) }, uniquingKeysWith: { first, _ in first })
            let previousIDs = Set(categoryStreams.map(\.channelKey))
            // Enrich existing cards in place when their second platform arrives on a later page.
            categoryStreams = categoryStreams.compactMap { byID[$0.channelKey] }
                + merged.filter { !previousIDs.contains($0.channelKey) }
            nextKickCursor = page.nextCursor == cursor ? nil : page.nextCursor
            recordFixtureState()
        } catch {
            guard !Task.isCancelled, streamsRequestID == requestID else { return }
            moreStreamsErrorMessage = failureMessage(error, platform: "Kick")
        }
    }

    private func mergedStreams() -> [FollowedChannel] {
        KickUnifiedFeed.mergeDirectory(twitch: twitchStreams, kick: kickStreams,
                                       links: creatorLinks ?? KickUnifiedFeed.confirmedLinks(for: twitchStreams))
    }

    private func capture<Value>(_ operation: @MainActor () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private func apply<Value>(_ result: Result<Value, Error>, previous: Value,
                              platform: String, errors: inout [String]) -> Value {
        switch result {
        case .success(let value): return value
        case .failure(let error):
            errors.append(failureMessage(error, platform: platform))
            return previous
        }
    }

    private func failureMessage(_ error: Error, platform: String) -> String {
        Self.logger.warning("\(platform) browse failed: \((error as NSError).domain) \((error as NSError).code)")
        return String(localized: "\(platform) couldn't be refreshed. \(error.localizedDescription)")
    }

    private func recordFixtureState() {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["STROZZ_BROWSE_UI_FIXTURE"] == "1" else { return }
        do {
            let state: [String: Any] = [
                "request": streamsCategoryID ?? "",
                "streams": categoryStreams.map {
                    ["id": $0.channelKey, "platform": $0.platform.rawValue, "linkedKick": $0.kick?.slug ?? ""]
                },
                "categories": categories.map { ["id": $0.id, "platform": $0.platform.rawValue] },
                "streamError": streamsErrorMessage ?? "", "categoryError": categoryErrorMessage ?? "",
                "hasMore": nextKickCursor != nil,
            ]
            let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                .write(to: root.appendingPathComponent("browse-fixture.json"), options: .atomic)
        } catch {
            Self.logger.error("Browse fixture export failed: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - GQL: Top Categories

    private func fetchTopCategories(limit: Int) async throws -> [TwitchCategory] {
        struct GameNode: Decodable {
            let id: String?
            let name: String?
            let boxArtURL: String?
            let viewersCount: Int?
            let isMature: Bool?
        }
        struct GameEdge: Decodable { let node: GameNode? }
        struct TopGamesConn: Decodable { let edges: [GameEdge]? }
        struct GQLData: Decodable { let games: TopGamesConn? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        let query = """
            query TopGames($first: Int!) {
              games(first: $first) {
                edges {
                  node {
                    id
                    name
                    boxArtURL(width: 285, height: 380)
                    viewersCount
                    isMature
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(
            query: query, variables: ["first": limit])
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        guard let edges = decoded.data?.games?.edges else { throw URLError(.badServerResponse) }

        return edges.compactMap { edge -> TwitchCategory? in
            guard let node = edge.node,
                  let id = node.id,
                  let name = node.name?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty
            else { return nil }

            let boxArtURL = node.boxArtURL.flatMap { URL(string: $0) }
            return TwitchCategory(
                id: id,
                name: name,
                boxArtURL: boxArtURL,
                viewerCount: node.viewersCount,
                isMature: node.isMature ?? false
            )
        }
    }

    // MARK: - GQL: Streams by Category

    private func fetchStreams(
        for category: TwitchCategory,
        limit: Int
    ) async throws -> [FollowedChannel] {
        struct StreamNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let previewImageURL: String?
            let isMature: Bool?
            let broadcaster: Broadcaster?

            struct Broadcaster: Decodable {
                let login: String?
                let displayName: String?
                let profileImageURL: String?
            }
        }
        struct StreamEdge: Decodable {
            let node: StreamNode?
        }
        struct StreamsConn: Decodable {
            let edges: [StreamEdge]?
        }
        struct GameResult: Decodable { let streams: StreamsConn? }
        struct GQLData: Decodable { let game: GameResult? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        // `broadcasterLanguages` is a GQL enum (e.g. EN), not a string, so it is
        // taken from a whitelisted token below — never interpolated from raw
        // input. When the viewer chooses "All", options are omitted entirely so
        // the category's default ordering is preserved.
        let optionsClause: String
        if let token = StreamLanguagePreference.currentToken() {
          optionsClause = ", options: {broadcasterLanguages: [\(token)]}"
        } else {
          optionsClause = ""
        }
        let query = """
            query GameStreams($id: ID!, $first: Int!) {
              game(id: $id) {
                streams(first: $first\(optionsClause)) {
                  edges {
                    node {
                      id
                      title
                      viewersCount
                      isMature
                      previewImageURL(width: 640, height: 360)
                      broadcaster {
                        login
                        displayName
                                                profileImageURL(width: 70)
                      }
                    }
                  }
                }
              }
            }
            """

        let responseData = try await performGQL(
            query: query, variables: ["id": category.id, "first": limit])
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        let edges = decoded.data?.game?.streams?.edges ?? []

        return edges.compactMap { edge -> FollowedChannel? in
            guard let node = edge.node,
                  let broadcaster = node.broadcaster,
                  let login = broadcaster.login?.trimmingCharacters(in: .whitespaces),
                  !login.isEmpty
            else { return nil }

            let streamID = node.id ?? UUID().uuidString
            let displayName = broadcaster.displayName?.trimmingCharacters(in: .whitespaces) ?? login
            let title = node.title?.trimmingCharacters(in: .whitespaces) ?? "Live now"
            let previewURL = node.previewImageURL.flatMap { URL(string: $0) }
            let profileURL = broadcaster.profileImageURL.flatMap { URL(string: $0) }

            return FollowedChannel(
                id: streamID,
                login: login,
                displayName: displayName,
                title: title,
                gameName: category.name,
                viewerCount: node.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: profileURL,
                isLive: true,
                isMature: node.isMature ?? false
            )
        }
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
