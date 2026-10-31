import Foundation
import Observation

/// Anonymous live discovery for Home, sharing Browse's provider handling and
/// confirmed creator identities rather than maintaining a Twitch-only pool.
@MainActor
@Observable
final class RecommendationsService {
    private(set) var channels: [FollowedChannel] = []
    private(set) var categories: [TwitchCategory] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastUpdatedAt: Date?
    private let browse: BrowseService
    private var refreshID = UUID()
    private var language: String?

    init(creatorLinks: [String: String]? = nil,
         loadData: @escaping NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }) {
        browse = BrowseService(creatorLinks: creatorLinks, loadData: loadData)
    }

    func refresh() async {
        let request = UUID()
        refreshID = request
        let currentLanguage = StreamLanguagePreference.current()
        if language != currentLanguage { channels = []; categories = [] }
        language = currentLanguage
        isLoading = true
        errorMessage = nil
        defer {
            if refreshID == request {
                isLoading = false
                lastUpdatedAt = Date()
            }
        }

        async let streams: Void = browse.loadStreams(filter: .all)
        async let games: Void = browse.loadCategories(filter: .all)
        _ = await (streams, games)
        guard !Task.isCancelled, refreshID == request else { return }
        channels = KickUnifiedFeed.sortedByViewers(browse.categoryStreams)
        categories = browse.categories
        let failures = [browse.streamsErrorMessage, browse.categoryErrorMessage].compactMap { $0 }
        errorMessage = failures.isEmpty ? nil : Array(Set(failures)).sorted().joined(separator: "\n")
        prewarmStaticArtwork(channels: channels, categories: categories)
    }

    /// Warm the decoded-image cache for the *static* artwork the recommendation
    /// rails show — channel avatars and category box art — so those tiles paint
    /// instantly as the Home screen scrolls instead of decoding on the fly. Live
    /// stream preview thumbnails (`FollowedChannel.thumbnailURL`) are deliberately
    /// never prewarmed: they must always reflect the current moment. Best-effort
    /// and low priority; `CachedAsyncImage` still loads on demand if the user
    /// scrolls before the warm pass finishes.
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

    // MARK: - GQL: Recommended Channels (top live streams)

    /// Fetches the most-viewed live channels in viewer-count order, with the
    /// viewer's language filter applied server-side. Twitch's `streams`
    /// connection caps `first` at 30 per request, and paginating past that
    /// requires an integrity token the anonymous public client can't mint — so
    /// this is the full ranked page for the chosen language. "Top streams" then
    /// only hides channels the viewer marked "Not interested".
    static func fetchRecommendedChannels(limit: Int,
        loadData: NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }
    ) async throws -> [FollowedChannel] {
        struct StreamNode: Decodable {
            let id: String?
            let title: String?
            let viewersCount: Int?
            let isMature: Bool?
            let previewImageURL: String?
            let broadcaster: Broadcaster?
            let game: Game?

            struct Broadcaster: Decodable {
                let login: String?
                let displayName: String?
                let profileImageURL: String?
            }

            struct Game: Decodable {
                let displayName: String?
            }
        }
        struct StreamEdge: Decodable { let node: StreamNode? }
        struct StreamsConn: Decodable { let edges: [StreamEdge]? }
        struct GQLData: Decodable { let streams: StreamsConn? }
        struct GQLEnvelope: Decodable { let data: GQLData? }

        // `broadcasterLanguages` is a GQL enum (e.g. EN), not a string, so it
        // is taken from a whitelisted token below — never interpolated from raw
        // input. When the viewer chooses "All", the option is omitted entirely.
        let languageOption: String
        if let token = StreamLanguagePreference.currentToken() {
          languageOption = ", broadcasterLanguages: [\(token)]"
        } else {
          languageOption = ""
        }
        let query = """
            query RecommendedStreams($first: Int!) {
              streams(first: $first, options: {sort: VIEWER_COUNT\(languageOption)}) {
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
                    game {
                      displayName
                    }
                  }
                }
              }
            }
            """

        var request = TwitchAPIClient.graphQLRequest(userAgent: TwitchConfig.apiUserAgent)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["first": limit]))
        let (data, response) = try await loadData(request)
        let responseData = try TwitchAPIClient.validatedData(data, response)
        let decoded = try TwitchAPIClient.decode(GQLEnvelope.self, from: responseData)
        guard let edges = decoded.data?.streams?.edges else { throw URLError(.badServerResponse) }

        return edges.compactMap { edge -> FollowedChannel? in
            guard let node = edge.node,
                  let broadcaster = node.broadcaster,
                  let login = broadcaster.login?.trimmingCharacters(in: .whitespaces),
                  !login.isEmpty
            else { return nil }

            let streamID = node.id ?? UUID().uuidString
            let displayName = broadcaster.displayName?.trimmingCharacters(in: .whitespaces) ?? login
            let title = node.title?.trimmingCharacters(in: .whitespaces) ?? "Live now"
            let gameName = node.game?.displayName?.trimmingCharacters(in: .whitespaces) ?? "Live"
            let previewURL = node.previewImageURL.flatMap { URL(string: $0) }
            let profileURL = broadcaster.profileImageURL.flatMap { URL(string: $0) }

            return FollowedChannel(
                id: streamID,
                login: login,
                displayName: displayName,
                title: title,
                gameName: gameName,
                viewerCount: node.viewersCount,
                thumbnailURL: previewURL,
                profileImageURL: profileURL,
                isLive: true,
                isMature: node.isMature ?? false
            )
        }
    }

}
