#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct ChannelFollowFixture: View {
  @State private var state = ChannelFollowFixtureState()
  @Namespace private var focusScope
  @Environment(\.colorScheme) private var colorScheme
  private let theme = ProcessInfo.processInfo.environment["STROZZ_FOLLOW_THEME"]
    .flatMap(AppTheme.init(rawValue:)) ?? .system

  var body: some View {
    let palette = theme.palette(systemColorScheme: colorScheme)
    VStack(spacing: 30) {
      Text("Channel").font(.title)
      ChannelFollowButton(login: "channel", displayName: "Channel", auth: state.auth,
        rewards: state.rewards, follows: state.follows, model: state.model)
        #if os(tvOS)
        .prefersDefaultFocus(true, in: focusScope)
        #endif
      Button("Adjacent control") {}
      Text(state.follows.followedLogins.contains("channel") ? "Following list updated" : "Not in Following")
        .accessibilityIdentifier("follow-list-state")
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LinearGradient(colors: palette.backgroundColors, startPoint: .top, endPoint: .bottom))
    .environment(\.themePalette, palette)
    #if os(tvOS)
    .environment(\.glassDisabled, ProcessInfo.processInfo.environment["STROZZ_FOLLOW_OPAQUE"] == "1")
    #endif
    .preferredColorScheme(theme.preferredColorScheme)
    #if os(tvOS)
    .focusScope(focusScope)
    #endif
  }
}

@MainActor
private final class ChannelFollowFixtureState {
  let auth: TwitchAuthSession
  let rewards: TwitchWatchRewardsSession
  let follows: FollowedChannelsService
  let model: TwitchChannelFollowModel

  init() {
    let transport = ChannelFollowFixtureTransport()
    let defaults = UserDefaults(suiteName: "ChannelFollowFixture")!
    let api = TwitchWatchRewardsAPI(load: { try await transport.load($0) })
    auth = TwitchAuthSession(userDefaults: defaults, secureService: "ChannelFollowFixture",
      saveTopShelf: { _ in }, loadAuthData: { try await transport.load($0) })
    auth.userID = "viewer"
    auth.userLogin = "viewer"
    auth.accessToken = "synthetic-helix"
    auth.isAuthenticated = ProcessInfo.processInfo.environment["STROZZ_FOLLOW_SIGNED_OUT"] != "1"
    auth.broadcasterIDCache["channel"] = "target"
    let connected = ProcessInfo.processInfo.environment["STROZZ_FOLLOW_DISCONNECTED"] != "1"
    rewards = TwitchWatchRewardsSession(api: api, store: .init(
      read: {
        guard connected else { return nil }
        return try JSONEncoder().encode(TwitchWatchRewardsAPI.Credential(
          token: "synthetic-rewards", userID: "viewer", login: "viewer", expiresAt: nil))
      }, write: { _ in }, remove: {}), preferences: defaults)
    follows = FollowedChannelsService(loadData: { try await transport.load($0) })
    model = TwitchChannelFollowModel(api: api)
  }
}

@MainActor
private final class ChannelFollowFixtureTransport {
  private var following = false

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    let json: String
    switch url.path {
    case "/oauth2/validate":
      json = #"{"client_id":"\#(TwitchWatchRewardsAPI.clientID)","user_id":"viewer","login":"viewer","expires_in":3600}"#
    case "/gql":
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
      if let operation = body?["operationName"] as? String, operation.hasPrefix("FollowButton_") {
        try await Task.sleep(for: .milliseconds(300))
        following = operation == "FollowButton_FollowUser"
        json = #"{"data":{"\#(following ? "followUser" : "unfollowUser")":{"error":null}}}"#
      } else {
        json = #"{"data":{"currentUser":{"id":"viewer"}}}"#
      }
    case "/helix/channels/followed":
      json = following
        ? #"{"data":[{"broadcaster_id":"target","broadcaster_login":"channel","broadcaster_name":"Channel"}]}"#
        : #"{"data":[]}"#
    case "/helix/streams/followed", "/helix/streams":
      json = #"{"data":[]}"#
    case "/helix/channels":
      json = #"{"data":[{"broadcaster_id":"target","game_name":"Game"}]}"#
    default:
      throw URLError(.unsupportedURL)
    }
    return (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
#endif
