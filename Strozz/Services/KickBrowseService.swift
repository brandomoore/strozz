import Foundation

enum KickBrowseService {
  struct Page {
    let channels: [FollowedChannel]
    let categories: [TwitchCategory]
    let nextCursor: String?
  }

  enum Failure: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
      String(localized: "Kick returned an invalid directory response.")
    }
  }

  static func page(categoryID: String? = nil, after: String? = nil, limit: Int = 40,
                   language: String? = StreamLanguagePreference.currentToken(),
                   load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader) async throws -> Page {
    var url = URLComponents(string: "https://web.kick.com/api/v1/livestreams")!
    var query = [
      URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
      URLQueryItem(name: "sort", value: "viewer_count_desc"),
    ]
    if let language { query.append(.init(name: "language", value: language.lowercased())) }
    if let categoryID { query.append(.init(name: "category_id", value: categoryID)) }
    if let after { query.append(.init(name: "after", value: after)) }
    url.queryItems = query
    var request = URLRequest(url: url.url!)
    request.timeoutInterval = 15
    KickPlaybackService.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let (data, response) = try await load(request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
    switch response.statusCode {
    case 200: break
    case 401, 403: throw KickPlaybackService.Failure.restricted
    default: throw KickPlaybackService.Failure.http(response.statusCode)
    }
    guard data.count <= 4 * 1024 * 1024 else { throw Failure.invalidResponse }
    return try decode(data)
  }

  static func decode(_ data: Data) throws -> Page {
    struct Envelope: Decodable {
      struct Directory: Decodable {
        struct Pagination: Decodable { let next_cursor: String? }
        let livestreams: [Stream]
        let pagination: Pagination?
      }
      let data: Directory
    }
    struct Stream: Decodable {
      struct Channel: Decodable {
        let slug: String
        let username: String
        let profile_pic: String?
      }
      struct Category: Decodable {
        let id: Int
        let name: String
      }
      struct Thumbnail: Decodable { let src: String? }
      let title: String
      let channel: Channel
      let category: Category
      let thumbnail: Thumbnail?
      let viewer_count: Int?
      let show_view_count: Bool?
      let is_mature: Bool?
    }
    let payload: Envelope
    do { payload = try JSONDecoder().decode(Envelope.self, from: data) }
    catch { throw Failure.invalidResponse }
    var channels: [FollowedChannel] = []
    var categories: [TwitchCategory] = []
    var seenChannels = Set<String>()
    var seenCategories = Set<Int>()
    for row in payload.data.livestreams {
      let slug = try KickPlaybackService.slug(from: row.channel.slug)
      if seenChannels.insert(slug).inserted {
        var channel = FollowedChannel(id: "kick:\(slug)", login: slug, displayName: row.channel.username,
          title: row.title, gameName: row.category.name,
          viewerCount: row.show_view_count == false ? nil : row.viewer_count,
          thumbnailURL: row.thumbnail?.src.flatMap(URL.init(string:)),
          profileImageURL: row.channel.profile_pic.flatMap(URL.init(string:)), isLive: true,
          isMature: row.is_mature ?? false)
        channel.platform = .kick
        channels.append(channel)
      }
      if seenCategories.insert(row.category.id).inserted {
        // This is a sample of live categories, not an authoritative category viewer total.
        categories.append(TwitchCategory(id: String(row.category.id), name: row.category.name,
          boxArtURL: nil, viewerCount: nil, platform: .kick))
      }
    }
    return Page(channels: channels, categories: categories,
      nextCursor: payload.data.pagination?.next_cursor.flatMap { $0.isEmpty ? nil : $0 })
  }
}
