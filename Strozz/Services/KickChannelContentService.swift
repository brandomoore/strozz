import Foundation

enum KickChannelContentService {
  struct Content {
    let channel: KickChannel
    let description: String?
    let followerCount: Int?
    let videos: [ChannelVOD]
  }

  struct ClipsPage {
    let clips: [ChannelClip]
    let nextCursor: String?
  }

  enum Failure: LocalizedError {
    case unavailableBroadcast
    case unavailableClip
    var errorDescription: String? {
      switch self {
      case .unavailableBroadcast: String(localized: "This Kick broadcast is no longer available.")
      case .unavailableClip: String(localized: "This Kick clip is no longer available.")
      }
    }
  }

  static func clips(_ input: String, after: String? = nil,
                    load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader) async throws -> ClipsPage {
    let slug = try KickPlaybackService.slug(from: input)
    var url = URLComponents(string: "https://kick.com/api/v2/channels/\(slug)/clips")!
    if let after { url.queryItems = [.init(name: "cursor", value: after)] }
    return try decodeClips(await KickBrowseService.response(url.url!, load: load), slug: slug)
  }

  static func decodeClips(_ data: Data, slug: String) throws -> ClipsPage {
    struct Envelope: Decodable {
      let clips: [Clip]
      let nextCursor: String?
    }
    let value = try JSONDecoder().decode(Envelope.self, from: data)
    var seen = Set<String>()
    return ClipsPage(clips: value.clips.compactMap { clip in
      guard clip.privacy == "public", clip.channel.slug.lowercased() == slug,
        validClipID(clip.id), seen.insert(clip.id).inserted else { return nil }
      return ChannelClip(slug: "kick:\(clip.id)", title: clip.title, viewCount: clip.views,
        durationSeconds: clip.duration, thumbnailURL: clip.thumbnail_url.flatMap(URL.init(string:)),
        gameName: clip.category?.name, createdAt: date(clip.created_at))
    }, nextCursor: value.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
  }

  static func clipURL(id: String, load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader) async throws -> URL {
    guard id.hasPrefix("kick:") else { throw Failure.unavailableClip }
    let raw = String(id.dropFirst(5))
    guard validClipID(raw) else { throw Failure.unavailableClip }
    let data = try await KickBrowseService.response(
      URL(string: "https://kick.com/api/v2/clips/\(raw)")!, load: load)
    return try decodeClipURL(data, expectedID: raw)
  }

  static func decodeClipURL(_ data: Data, expectedID: String) throws -> URL {
    struct Envelope: Decodable { let clip: Clip }
    let clip = try JSONDecoder().decode(Envelope.self, from: data).clip
    guard clip.id == expectedID, clip.privacy == "public",
      let raw = clip.video_url ?? clip.clip_url, let url = URL(string: raw),
      url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, url.host?.lowercased() == "clips.kick.com",
      ["m3u8", "mp4"].contains(url.pathExtension.lowercased())
    else { throw Failure.unavailableClip }
    return url
  }

  private static func validClipID(_ id: String) -> Bool {
    id.range(of: #"^clip_[a-zA-Z0-9_-]{1,100}$"#, options: .regularExpression) != nil
  }

  static func load(_ input: String, load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader)
    async throws -> Content {
    let slug = try KickPlaybackService.slug(from: input)
    let data = try await KickBrowseService.response(
      URL(string: "https://kick.com/api/v1/channels/\(slug)")!, load: load)
    return try decode(data, slug: slug)
  }

  static func decode(_ data: Data, slug: String) throws -> Content {
    struct Payload: Decodable {
      struct User: Decodable { let bio: String? }
      let user: User?
      let followersCount: Int?
      let previous_livestreams: [Broadcast]?
    }
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    let channel = try KickPlaybackService.parseChannel(data, requestedSlug: slug).channel
    var seen = Set<String>()
    let videos = (payload.previous_livestreams ?? []).compactMap { row -> ChannelVOD? in
      guard !row.is_live, let video = row.video, video.status == "public",
        video.is_private != true, video.is_pruned != true, video.deleted_at == nil,
        let uuid = UUID(uuidString: video.uuid), seen.insert(uuid.uuidString).inserted else { return nil }
      return ChannelVOD(id: "kick:\(uuid.uuidString.lowercased())", title: row.session_title,
        lengthSeconds: max(0, row.duration / 1000), thumbnailURL: row.thumbnail?.src.flatMap(URL.init(string:)),
        gameName: row.categories?.first?.name, publishedAt: date(row.created_at), viewCount: row.views ?? 0)
    }
    return Content(channel: channel, description: payload.user?.bio,
                   followerCount: payload.followersCount, videos: videos)
  }

  static func broadcastURL(id: String, load: KickPlaybackService.Loader = KickPlaybackService.defaultLoader)
    async throws -> URL {
    guard id.hasPrefix("kick:"), let uuid = UUID(uuidString: String(id.dropFirst(5))) else {
      throw Failure.unavailableBroadcast
    }
    let data = try await KickBrowseService.response(
      URL(string: "https://kick.com/api/v1/video/\(uuid.uuidString.lowercased())")!, load: load)
    return try decodeBroadcastURL(data)
  }

  static func decodeBroadcastURL(_ data: Data) throws -> URL {
    struct Payload: Decodable {
      let source: String?
      let status: String
      let is_private: Bool?
      let is_pruned: Bool?
      let deleted_at: String?
    }
    let value = try JSONDecoder().decode(Payload.self, from: data)
    guard value.status == "public", value.is_private != true, value.is_pruned != true,
      value.deleted_at == nil, let source = value.source, let url = URL(string: source),
      url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, url.host?.lowercased() == "stream.kick.com",
      url.pathExtension.lowercased() == "m3u8"
    else { throw Failure.unavailableBroadcast }
    return url
  }

  private static func date(_ raw: String) -> Date? {
    let value = raw.contains("T") ? raw : raw.replacingOccurrences(of: " ", with: "T") + "Z"
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private struct Broadcast: Decodable {
    struct Video: Decodable {
      let uuid: String
      let status: String
      let is_private: Bool?
      let is_pruned: Bool?
      let deleted_at: String?
    }
    struct Thumbnail: Decodable { let src: String? }
    struct Category: Decodable { let name: String }
    let session_title: String
    let duration: Int
    let is_live: Bool
    let created_at: String
    let views: Int?
    let thumbnail: Thumbnail?
    let categories: [Category]?
    let video: Video?
  }

  private struct Clip: Decodable {
    struct Channel: Decodable { let slug: String }
    struct Category: Decodable { let name: String }
    let id: String
    let title: String
    let privacy: String
    let views: Int
    let duration: Int
    let thumbnail_url: String?
    let video_url: String?
    let clip_url: String?
    let created_at: String
    let channel: Channel
    let category: Category?
  }
}
