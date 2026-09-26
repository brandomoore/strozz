import Foundation

// Wire models and request errors backing `FollowedChannelsService` and its
// `FollowedChannelsFetcher`. These mirror the Twitch Helix JSON envelopes 1:1
// and carry no behavior beyond decoding. Kept Foundation-only so the followed
// channels stack can back a future iOS target.

struct FollowedStreamsEnvelope: Decodable {
  let data: [HelixStream]
}

struct HelixStream: Decodable {
  let userID: String
  let userLogin: String
  let userName: String
  let gameName: String
  let title: String
  let viewerCount: Int
  let isMature: Bool
  let thumbnailURL: String
  let type: String

  private enum CodingKeys: String, CodingKey {
    case userID = "user_id"
    case userLogin = "user_login"
    case userName = "user_name"
    case gameName = "game_name"
    case title
    case viewerCount = "viewer_count"
    case isMature = "is_mature"
    case thumbnailURL = "thumbnail_url"
    case type
  }
}

struct FollowedChannelsEnvelope: Decodable {
  let data: [FollowedBroadcaster]
  let pagination: HelixPagination?
}

struct HelixPagination: Decodable {
  let cursor: String?
}

struct ChannelInformationEnvelope: Decodable {
  let data: [ChannelInformation]
}

struct ChannelInformation: Decodable {
  let broadcasterID: String?
  let gameName: String?
  let title: String?

  private enum CodingKeys: String, CodingKey {
    case broadcasterID = "broadcaster_id"
    case gameName = "game_name"
    case title
  }
}

struct HelixUsersEnvelope: Decodable {
  let data: [HelixUser]
}

struct HelixUser: Decodable {
  let id: String
  let login: String?
  let displayName: String?
  let profileImageURL: URL?
  let offlineImageURL: URL?

  private enum CodingKeys: String, CodingKey {
    case id
    case login
    case displayName = "display_name"
    case profileImageURL = "profile_image_url"
    case offlineImageURL = "offline_image_url"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    login = try container.decodeIfPresent(String.self, forKey: .login)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    profileImageURL = Self.url(in: container, forKey: .profileImageURL)
    offlineImageURL = Self.url(in: container, forKey: .offlineImageURL)
  }

  private static func url(
    in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
  ) -> URL? {
    let raw = try? container.decodeIfPresent(String.self, forKey: key)
    guard let raw, !raw.isEmpty else { return nil }
    return URL(string: raw)
  }
}

struct FollowedBroadcaster: Decodable {
  let broadcasterID: String
  let broadcasterLogin: String?
  let broadcasterName: String?

  private enum CodingKeys: String, CodingKey {
    case broadcasterID = "broadcaster_id"
    case broadcasterLogin = "broadcaster_login"
    case broadcasterName = "broadcaster_name"
  }
}

struct TwitchHelixErrorPayload: Decodable {
  let error: String?
  let status: Int?
  let message: String?
}

struct TwitchHelixRequestError: LocalizedError {
  let context: String
  let status: Int
  let message: String?

  var errorDescription: String? {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return "\(context): \(trimmed) (HTTP \(status))"
    }
    return "\(context) failed (HTTP \(status))"
  }
}
