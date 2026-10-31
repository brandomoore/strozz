import Foundation
import OSLog

enum KickBrowseService {
  struct Page {
    let channels: [FollowedChannel]
    let categories: [TwitchCategory]
    let nextCursor: String?
    var categoryID: String? = nil
  }

  struct CategoriesPage {
    let categories: [TwitchCategory]
    let nextPage: Int?
  }

  struct SearchPage {
    var channels: [FollowedChannel]
    let categories: [TwitchCategory]
    var warning: String? = nil
  }

  private struct Category: Decodable {
    struct Banner: Decodable {
      let url: String?
      let src: String?
    }
    let id: Int
    let name: String
    let viewers: Int?
    let is_mature: Bool?
    let banner: Banner?

    var model: TwitchCategory {
      TwitchCategory(id: String(id), name: name,
        boxArtURL: (banner?.url ?? banner?.src).flatMap(URL.init(string:)),
        viewerCount: viewers, isMature: is_mature ?? false, platform: .kick)
    }
  }

  enum Failure: LocalizedError, Equatable {
    case invalidResponse, searchTooShort

    var errorDescription: String? {
      switch self {
      case .invalidResponse: String(localized: "Kick returned an invalid directory response.")
      case .searchTooShort: String(localized: "Enter at least 3 characters to search Kick.")
      }
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
    var result = try decode(await response(url.url!, load: load))
    result.categoryID = categoryID
    return result
  }

  static func categories(page: Int = 1, load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader)
    async throws -> CategoriesPage {
    var url = URLComponents(string: "https://kick.com/api/v1/subcategories")!
    url.queryItems = [.init(name: "limit", value: "40"), .init(name: "page", value: String(page))]
    return try decodeCategories(await response(url.url!, load: load))
  }

  static func decodeCategories(_ data: Data) throws -> CategoriesPage {
    struct Envelope: Decodable {
      let current_page: Int
      let data: [Category]
      let next_page_url: String?
    }
    let value = try JSONDecoder().decode(Envelope.self, from: data)
    guard value.current_page > 0, value.current_page < Int.max else { throw Failure.invalidResponse }
    return CategoriesPage(categories: value.data.map(\.model),
                          nextPage: value.next_page_url == nil ? nil : value.current_page + 1)
  }

  static func search(_ input: String,
                     load: @escaping KickPlaybackService.Loader = KickPlaybackService.defaultLoader) async throws -> SearchPage {
    var result = try decodeSearch(await searchResponse(input, load: load))
    let live = Array(result.channels.filter(\.isLive).prefix(6))
    let details = await withTaskGroup(of: (String, KickChannel?).self) { group in
      var iterator = live.makeIterator()
      func enqueue(_ channel: FollowedChannel) {
        group.addTask {
          do { return (channel.channelKey, try await KickPlaybackService.channel(channel.login, load: load)) }
          catch {
            if !Task.isCancelled {
              Logger(subsystem: "com.thatcube.Strozz", category: "kick-search")
                .warning("Search metadata failed: \((error as NSError).domain) \((error as NSError).code)")
            }
            return (channel.channelKey, nil)
          }
        }
      }
      for _ in 0..<4 { if let channel = iterator.next() { enqueue(channel) } }
      var values: [String: KickChannel] = [:]
      for await (key, channel) in group {
        if Task.isCancelled { group.cancelAll(); break }
        if let channel { values[key] = channel }
        if let next = iterator.next() { enqueue(next) }
      }
      return values
    }
    try Task.checkCancellation()
    result.channels = result.channels.map { details[$0.channelKey]?.followedChannel ?? $0 }
    if details.count != live.count {
      result.warning = String(localized: "Some Kick channel details couldn't be refreshed.")
    }
    return result
  }

  static func searchCategories(_ input: String,
                               load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader)
    async throws -> [TwitchCategory] {
    try decodeSearch(await searchResponse(input, load: load)).categories
  }

  static func recommendationCandidates(for names: [String],
                                       load: @escaping KickPlaybackService.Loader = KickPlaybackService.defaultLoader)
    async -> [FollowedChannel] {
    await withTaskGroup(of: [FollowedChannel].self) { group in
      var iterator = names.prefix(6).makeIterator()
      func enqueue(_ name: String) {
        group.addTask {
          do {
            let matches = try await searchCategories(name, load: load)
              .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1, let category = matches.first else { return [] }
            return try await page(categoryID: category.sourceID, load: load).channels
          } catch {
            if !Task.isCancelled {
              Logger(subsystem: "com.thatcube.Strozz", category: "kick-recommendations")
                .warning("Category recommendations failed: \((error as NSError).domain) \((error as NSError).code)")
            }
            return []
          }
        }
      }
      for _ in 0..<3 { if let name = iterator.next() { enqueue(name) } }
      var result: [FollowedChannel] = []
      for await channels in group {
        if Task.isCancelled { group.cancelAll(); break }
        result += channels
        if let name = iterator.next() { enqueue(name) }
      }
      return result
    }
  }

  private static func searchResponse(_ input: String, load: KickPlaybackService.Loader) async throws -> Data {
    let term = (try? KickPlaybackService.slug(from: input)) ?? input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard term.count >= 3 else { throw Failure.searchTooShort }
    var url = URLComponents(string: "https://kick.com/api/search")!
    url.queryItems = [.init(name: "searched_word", value: term)]
    return try await response(url.url!, load: load)
  }

  static func decodeSearch(_ data: Data) throws -> SearchPage {
    struct Channel: Decodable {
      struct User: Decodable {
        let username: String
        let profilePic: String?
      }
      let slug: String
      let user: User
      let isLive: Bool
      let is_banned: Bool?
      let recentCategories: [Category]?
    }
    struct Envelope: Decodable {
      let channels: [Channel]
      let categories: [Category]
    }
    let value = try JSONDecoder().decode(Envelope.self, from: data)
    let channels = try value.channels.filter { $0.is_banned != true }.map { row in
      let slug = try KickPlaybackService.slug(from: row.slug)
      var channel = FollowedChannel(id: "kick:\(slug)", login: slug, displayName: row.user.username,
        title: "", gameName: row.recentCategories?.first?.name ?? "", viewerCount: nil,
        thumbnailURL: nil, profileImageURL: row.user.profilePic.flatMap(URL.init(string:)), isLive: row.isLive)
      channel.platform = .kick
      return channel
    }
    return SearchPage(channels: channels, categories: value.categories.map(\.model))
  }

  static func response(_ url: URL, load: KickPlaybackService.Loader) async throws -> Data {
    var request = URLRequest(url: url)
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
    return data
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
      let language: String?
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
        channel.language = row.language
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
