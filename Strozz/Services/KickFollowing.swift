import Foundation

struct KickFollowAccount: Codable, Equatable, Sendable {
  let id: Int
  let username: String
}

struct KickFollow: Codable, Equatable, Sendable {
  let slug: String
  let displayName: String
  let imageURL: URL?
  var isLive = false
  var title = ""
  var category = ""
  var viewerCount: Int?

  var channel: KickChannel {
    KickChannel(slug: slug, displayName: displayName, title: title, category: category,
      viewerCount: viewerCount, isLive: isLive, chatroomID: nil, imageURL: imageURL)
  }
}

struct KickFollowImport: Equatable, Sendable {
  let account: KickFollowAccount
  let follows: [KickFollow]

  /// Only a complete roster, read under the same account at both ends, may
  /// replace a saved list. Website responses are not a stable public API.
  @MainActor
  static func read(get: (String) async throws -> Data) async throws -> Self {
    try Task.checkCancellation()
    let account = try decodeAccount(await get("/api/v1/user"))
    var cursor = 0
    var cursors = Set<Int>()
    var follows: [KickFollow] = []
    var slugs = Set<String>()
    while true {
      try Task.checkCancellation()
      guard cursors.insert(cursor).inserted, cursors.count <= 100 else {
        throw KickFollowingError.incomplete
      }
      let page = try decodePage(await get("/api/v2/channels/followed?cursor=\(cursor)"))
      for follow in page.follows where slugs.insert(follow.slug).inserted { follows.append(follow) }
      guard follows.count <= 10_000 else { throw KickFollowingError.incomplete }
      guard let next = page.nextCursor else { break }
      guard !page.follows.isEmpty, next >= 0 else { throw KickFollowingError.incomplete }
      cursor = next
    }
    let finalAccount = try decodeAccount(await get("/api/v1/user"))
    try Task.checkCancellation()
    guard finalAccount.id == account.id else { throw KickFollowingError.accountChanged }
    return Self(account: finalAccount, follows: follows)
  }

  static func decodeAccount(_ data: Data) throws -> KickFollowAccount {
    guard data.count <= 1_000_000 else { throw KickFollowingError.invalidResponse }
    let value: KickFollowAccount
    do { value = try JSONDecoder().decode(KickFollowAccount.self, from: data) }
    catch { throw KickFollowingError.signInRequired }
    guard value.id > 0, !value.username.isEmpty, value.username.count <= 100 else {
      throw KickFollowingError.invalidResponse
    }
    return value
  }

  static func decodePage(_ data: Data) throws -> (follows: [KickFollow], nextCursor: Int?) {
    struct Page: Decodable {
      struct Row: Decodable {
        let channel_slug: String
        let user_username: String?
        let profile_picture: URL?
        let is_live: Bool
        let session_title: String?
        let category_name: String?
        let viewer_count: Int?
      }
      let channels: [Row]
      let nextCursor: Int?
      enum CodingKeys: String, CodingKey { case channels, nextCursor }
      init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.nextCursor) else { throw KickFollowingError.incomplete }
        channels = try values.decode([Row].self, forKey: .channels)
        nextCursor = try values.decodeIfPresent(Int.self, forKey: .nextCursor)
      }
    }
    guard data.count <= 4_000_000 else { throw KickFollowingError.invalidResponse }
    do {
      let page = try JSONDecoder().decode(Page.self, from: data)
      let follows = try page.channels.map { row in
        let slug = try KickPlaybackService.slug(from: row.channel_slug)
        guard slug == row.channel_slug.lowercased(),
          (row.user_username?.count ?? 0) <= 100 else { throw KickFollowingError.invalidResponse }
        var follow = KickFollow(slug: slug, displayName: row.user_username ?? slug,
          imageURL: row.profile_picture.flatMap { $0.scheme == "https" ? $0 : nil })
        follow.isLive = row.is_live
        follow.title = row.session_title ?? ""
        follow.category = row.category_name ?? ""
        follow.viewerCount = row.viewer_count
        return follow
      }
      return (follows, page.nextCursor)
    } catch { throw KickFollowingError.invalidResponse }
  }
}

struct KickFollowDocument: Codable, Equatable, Sendable {
  let connectionID: UUID
  let account: KickFollowAccount?
  let follows: [KickFollow]
  let importedAt: Date

  func validated() throws -> Self {
    guard follows.count <= 10_000,
      Set(follows.map(\.slug)).count == follows.count,
      account != nil || follows.isEmpty,
      account.map({ $0.id > 0 && !$0.username.isEmpty && $0.username.count <= 100 }) ?? true
    else { throw KickFollowingError.invalidResponse }
    for follow in follows {
      guard try KickPlaybackService.slug(from: follow.slug) == follow.slug,
        !follow.displayName.isEmpty, follow.displayName.count <= 100,
        follow.title.count <= 10_000, follow.category.count <= 300,
        follow.viewerCount.map({ $0 >= 0 }) ?? true,
        follow.imageURL.map({ $0.scheme == "https" && $0.user == nil && $0.password == nil }) ?? true
      else { throw KickFollowingError.invalidResponse }
    }
    guard try JSONEncoder().encode(self).count <= 900_000 else { throw KickFollowingError.incomplete }
    return self
  }
}

enum KickFollowingError: LocalizedError, Equatable {
  case signInRequired, restricted, invalidResponse, incomplete, accountChanged, conflict, unavailable

  var errorDescription: String? {
    switch self {
    case .signInRequired:
      String(localized: "Sign in to Kick to refresh your follows. Your saved list has not been changed.")
    case .restricted:
      String(localized: "Kick isn't allowing this follow-list request. Complete any sign-in step on the Kick page or try again later.")
    case .invalidResponse:
      String(localized: "Kick returned an unreadable follow list. Your saved list has not been changed.")
    case .incomplete:
      String(localized: "The complete Kick follow list could not be imported. Your saved list has not been changed.")
    case .accountChanged:
      String(localized: "The connected account changed. Please connect Kick again.")
    case .conflict:
      String(localized: "Your Kick connection changed on another device. Sync again before reconnecting.")
    case .unavailable:
      String(localized: "Sign in to iCloud to share Kick follows with your other Strozz devices.")
    }
  }
}
