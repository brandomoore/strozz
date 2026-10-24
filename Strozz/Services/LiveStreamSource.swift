import Foundation

enum LivePlatform: String, CaseIterable, Codable, Sendable {
  case twitch, kick, youtube

  var title: String {
    switch self {
    case .twitch: "Twitch"
    case .kick: "Kick"
    case .youtube: "YouTube"
    }
  }
}

struct PlatformLiveTarget: Identifiable, Equatable, Sendable {
  enum Failure: LocalizedError {
    case invalidChannel(LivePlatform)
    var errorDescription: String? {
      switch self {
      case .invalidChannel(let platform):
        String(localized: "Enter a valid \(platform.title) channel name or channel URL.")
      }
    }
  }

  let platform: LivePlatform
  let channel: String
  var id: String { "\(platform.rawValue):\(channel)" }
  var headers: [String: String] {
    switch platform {
    case .twitch: PlaybackService.streamHeaders
    case .kick: KickPlaybackService.headers
    case .youtube: AltSourceService.mediaHTTPHeaders
    }
  }
  var watchURL: URL? {
    switch platform {
    case .twitch: return URL(string: "https://www.twitch.tv/\(channel)")
    case .kick: return URL(string: "https://kick.com/\(channel)")
    case .youtube:
      if channel.contains("://") { return URL(string: channel) }
      let path =
        channel.hasPrefix("UC")
        ? "channel/\(channel)" : channel.hasPrefix("@") ? channel : "@\(channel)"
      return URL(string: "https://www.youtube.com/\(path)/live")
    }
  }

  func resolvePlayback() async throws -> StreamPlayback {
    switch platform {
    case .twitch: try await PlaybackService.resolve(for: channel)
    case .kick: try await KickPlaybackService.resolve(channel).playback
    case .youtube:
      StreamPlayback(
        master: try await AltSourceService.youtubeLive(forTarget: channel).hlsMaster, qualities: [])
    }
  }

  static func validated(platform: LivePlatform, input: String) throws -> Self {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    switch platform {
    case .kick: return Self(platform: platform, channel: try KickPlaybackService.slug(from: input))
    case .twitch:
      let name: String
      if input.contains("://") {
        guard let url = URL(string: input), url.scheme == "https",
          ["twitch.tv", "www.twitch.tv"].contains(url.host?.lowercased() ?? ""),
          url.user == nil, url.password == nil, url.pathComponents.count == 2
        else { throw Failure.invalidChannel(platform) }
        name = url.lastPathComponent
      } else {
        name = input.hasPrefix("@") ? String(input.dropFirst()) : input
      }
      guard name.range(of: #"^[A-Za-z0-9_]{1,25}$"#, options: .regularExpression) != nil
      else { throw Failure.invalidChannel(platform) }
      return Self(platform: platform, channel: name.lowercased())
    case .youtube:
      if input.contains("://") {
        guard let url = URL(string: input), url.scheme == "https",
          ["youtube.com", "www.youtube.com", "youtu.be"].contains(url.host?.lowercased() ?? ""),
          url.user == nil, url.password == nil
        else { throw Failure.invalidChannel(platform) }
      } else {
        guard input.range(of: #"^[@A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil
        else { throw Failure.invalidChannel(platform) }
      }
      return Self(platform: platform, channel: input)
    }
  }
}
