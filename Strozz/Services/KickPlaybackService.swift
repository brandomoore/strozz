import Foundation

struct KickChannel: Identifiable, Codable, Equatable, Sendable {
  let slug: String
  let displayName: String
  let title: String
  let category: String
  let viewerCount: Int?
  let isLive: Bool
  let chatroomID: Int?
  let imageURL: URL?
  var id: String { slug }
}

enum KickPlaybackService {
  typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  static let headers = ["User-Agent": "Strozz/0.68.0", "Accept": "application/json"]

  enum Failure: LocalizedError, Equatable {
    case invalidChannel, notFound, offline, restricted, invalidResponse, unsupportedMedia,
      chatUnavailable, http(Int)
    var errorDescription: String? {
      switch self {
      case .invalidChannel: String(localized: "Enter a Kick channel name or kick.com channel URL.")
      case .notFound: String(localized: "No Kick channel was found with that name.")
      case .offline: String(localized: "This Kick channel is offline.")
      case .restricted:
        String(localized: "Kick isn't allowing access to this stream. Try again later.")
      case .invalidResponse: String(localized: "Kick returned an invalid channel response.")
      case .unsupportedMedia: String(localized: "Kick didn't return a supported live stream.")
      case .chatUnavailable: String(localized: "Kick chat is unavailable right now.")
      case .http(let status): String(localized: "Kick request failed (HTTP \(status)).")
      }
    }
  }

  struct Resolved: Sendable {
    let channel: KickChannel
    let playback: StreamPlayback
  }

  static func slug(from input: String) throws -> String {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate: String
    if input.contains("://") || input.lowercased().hasPrefix("kick.com/")
      || input.lowercased().hasPrefix("www.kick.com/")
    {
      guard let url = URL(string: input.contains("://") ? input : "https://\(input)"),
        url.scheme == "https", ["kick.com", "www.kick.com"].contains(url.host?.lowercased() ?? ""),
        url.user == nil, url.password == nil, url.port == nil,
        url.pathComponents.filter({ $0 != "/" }).count == 1
      else { throw Failure.invalidChannel }
      candidate = url.lastPathComponent
    } else {
      candidate = input.hasPrefix("@") ? String(input.dropFirst()) : input
    }
    let slug = candidate.lowercased()
    guard slug.range(of: #"^[a-z0-9][a-z0-9_-]{0,99}$"#, options: .regularExpression) != nil,
      !["browse", "categories", "search", "settings", "api", "video", "videos", "clips"].contains(
        slug)
    else { throw Failure.invalidChannel }
    return slug
  }

  static func channel(_ input: String, load: Loader = defaultLoader) async throws -> KickChannel {
    try await channelDocument(input, load: load).channel
  }

  static func resolve(_ input: String, load: Loader = defaultLoader) async throws -> Resolved {
    let document = try await channelDocument(input, load: load)
    guard document.channel.isLive else { throw Failure.offline }
    guard let master = document.playbackURL else { throw Failure.unsupportedMedia }
    let data = try await response(master, accept: "application/vnd.apple.mpegurl", load: load)
    let playback = StreamPlayback(
      master: master,
      qualities: try qualities(in: String(decoding: data, as: UTF8.self), base: master))
    return Resolved(channel: document.channel, playback: playback)
  }

  static func qualities(in text: String, base: URL) throws -> [StreamQuality] {
    guard text.hasPrefix("#EXTM3U"), validMediaURL(base) else { throw Failure.unsupportedMedia }
    var pending: [String: String]?
    var results: [StreamQuality] = []
    var identities = Set<String>()
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("#EXT-X-STREAM-INF:") {
        guard pending == nil else { throw Failure.unsupportedMedia }
        pending = NativeCMAF.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
      } else if !line.isEmpty, !line.hasPrefix("#"), let attributes = pending {
        guard let url = URL(string: line, relativeTo: base)?.absoluteURL, validMediaURL(url),
          let bitrate = Int(attributes["BANDWIDTH"] ?? ""), bitrate > 0
        else { throw Failure.unsupportedMedia }
        let size = (attributes["RESOLUTION"] ?? "").split(separator: "x")
        let height = size.count == 2 ? Int(size[1]) : nil
        let codecs = (attributes["CODECS"] ?? "").lowercased().split(separator: ",")
        let audioOnly =
          height == nil && !codecs.isEmpty && codecs.allSatisfy { $0.hasPrefix("mp4a") }
        guard height != nil || audioOnly else { throw Failure.unsupportedMedia }
        let name: String
        if let label = attributes["NAME"] ?? attributes["IVS-NAME"], !label.isEmpty {
          name = label
        } else if let height {
          let fps = Double(attributes["FRAME-RATE"] ?? "") ?? 0
          name = "\(height)p" + (fps > 30 ? String(Int(fps.rounded())) : "")
        } else {
          name = String(localized: "Audio only")
        }
        let id = NativeCMAF.renditionIdentity(attributes)
        guard identities.insert(id).inserted else { throw Failure.unsupportedMedia }
        results.append(
          StreamQuality(id: id, name: name, url: url, isAudioOnly: audioOnly, bitrate: bitrate))
        pending = nil
      }
    }
    guard pending == nil, results.contains(where: { !$0.isAudioOnly }) else {
      throw Failure.unsupportedMedia
    }
    return results.sorted {
      $0.isAudioOnly != $1.isAudioOnly ? !$0.isAudioOnly : $0.bitrate > $1.bitrate
    }
  }

  static func validMediaURL(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443,
      let host = url.host?.lowercased()
    else { return false }
    return host == "live-video.net" || host.hasSuffix(".live-video.net")
  }

  static func chatURL(load: Loader = defaultLoader) async throws -> URL {
    let endpoint = URL(string: "https://web.kick.com/api/v1/realtime/connection")!
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client": ["id": UUID().uuidString.lowercased(), "type": "web"],
      "capabilities": ["accepted_providers": [["provider": "pusher"]]],
    ])
    struct Payload: Decodable {
      struct Connections: Decodable {
        struct Connection: Decodable {
          struct Credentials: Decodable {
            let app_key: String
            let cluster: String
          }
          let provider: String
          let credentials: Credentials?
        }
        let connections: [Connection]
      }
      let data: Connections
    }
    let bytes = try await response(request, load: load)
    let payload: Payload
    do { payload = try JSONDecoder().decode(Payload.self, from: bytes) } catch {
      throw Failure.chatUnavailable
    }
    guard
      let credentials = payload.data.connections.first(where: { $0.provider == "pusher" })?
        .credentials,
      credentials.app_key.range(of: #"^[A-Za-z0-9]{8,64}$"#, options: .regularExpression) != nil,
      credentials.cluster.range(of: #"^[a-z0-9-]{1,30}$"#, options: .regularExpression) != nil,
      let url = URL(
        string:
          "wss://ws-\(credentials.cluster).pusher.com/app/\(credentials.app_key)?protocol=7&client=js&version=8.4.0&flash=false"
      )
    else { throw Failure.chatUnavailable }
    return url
  }

  private struct Document {
    let channel: KickChannel
    let playbackURL: URL?
  }

  private static func channelDocument(_ input: String, load: Loader) async throws -> Document {
    let slug = try slug(from: input)
    let url = URL(string: "https://kick.com/api/v2/channels/\(slug)")!
    return try decodeChannel(
      await response(url, accept: "application/json", load: load), requestedSlug: slug)
  }

  static func parseChannel(_ data: Data, requestedSlug: String) throws -> (
    channel: KickChannel, playbackURL: URL?
  ) {
    let document = try decodeChannel(data, requestedSlug: requestedSlug)
    return (document.channel, document.playbackURL)
  }

  private static func decodeChannel(_ data: Data, requestedSlug: String) throws -> Document {
    struct Payload: Decodable {
      struct User: Decodable {
        let username: String?
        let profile_pic: URL?
      }
      struct Live: Decodable {
        struct Category: Decodable { let name: String? }
        let session_title: String?
        let viewer_count: Int?
        let viewers: Int?
        let categories: [Category]?
      }
      struct Chatroom: Decodable { let id: Int }
      let slug: String
      let user: User?
      let livestream: Live?
      let chatroom: Chatroom?
      let playback_url: String?
      enum CodingKeys: String, CodingKey { case slug, user, livestream, chatroom, playback_url }
      init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.livestream) else { throw Failure.invalidResponse }
        slug = try values.decode(String.self, forKey: .slug)
        user = try values.decodeIfPresent(User.self, forKey: .user)
        livestream = try values.decodeIfPresent(Live.self, forKey: .livestream)
        chatroom = try values.decodeIfPresent(Chatroom.self, forKey: .chatroom)
        playback_url = try values.decodeIfPresent(String.self, forKey: .playback_url)
      }
    }
    let payload: Payload
    do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
      throw Failure.invalidResponse
    }
    guard try slug(from: payload.slug) == requestedSlug else { throw Failure.invalidResponse }
    let playbackURL = payload.playback_url.flatMap(URL.init(string:))
    if let playbackURL, !validMediaURL(playbackURL) { throw Failure.unsupportedMedia }
    return Document(
      channel: KickChannel(
        slug: requestedSlug, displayName: payload.user?.username ?? requestedSlug,
        title: payload.livestream?.session_title ?? "",
        category: payload.livestream?.categories?.first?.name ?? "",
        viewerCount: payload.livestream?.viewer_count ?? payload.livestream?.viewers,
        isLive: payload.livestream != nil,
        chatroomID: payload.chatroom?.id, imageURL: payload.user?.profile_pic),
      playbackURL: playbackURL)
  }

  private static func response(_ url: URL, accept: String, load: Loader) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    request.setValue(accept, forHTTPHeaderField: "Accept")
    return try await response(request, load: load)
  }

  private static func response(_ request: URLRequest, load: Loader) async throws -> Data {
    let (data, response) = try await load(request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
    switch http.statusCode {
    case 200: break
    case 401, 403: throw Failure.restricted
    case 404 where request.url?.host == "kick.com": throw Failure.notFound
    default: throw Failure.http(http.statusCode)
    }
    guard data.count <= 4 * 1024 * 1024 else { throw Failure.invalidResponse }
    return data
  }

  static func defaultLoader(_ request: URLRequest) async throws -> (Data, URLResponse) {
    try await NetworkClient.api.data(for: request)
  }
}
