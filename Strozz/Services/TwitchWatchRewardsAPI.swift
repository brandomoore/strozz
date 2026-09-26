import Foundation

/// Unofficial Twitch rewards endpoints. These never use or replace Strozz's Helix login.
struct TwitchWatchRewardsAPI: Sendable {
  // The TV client supports device pairing; the mobile client's device grant is rejected.
  static let clientID = "ue6666qo983tsx6so1t0vnawi233wa"
  var load: NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }

  struct Credential: Codable, Equatable, Sendable {
    let token: String
    let userID: String
    let login: String
    /// Twitch TV sessions can have no scheduled expiry; they still require server revalidation.
    let expiresAt: Date?
  }

  struct DeviceCode: Decodable, Equatable, Sendable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int

    var activationURL: URL? {
      guard var url = URLComponents(string: verification_uri),
        url.scheme == "https",
        ["www.twitch.tv", "twitch.tv"].contains(url.host) else { return nil }
      url.queryItems = (url.queryItems ?? []).filter { $0.name != "device-code" }
        + [URLQueryItem(name: "device-code", value: user_code)]
      return url.url
    }
  }

  enum Failure: Error, LocalizedError, Equatable {
    case unauthorized, unsupported, accountMismatch, malformedResponse
    case authorizationPending, slowDown, denied, expiredCode
    case http(Int), secureStorage(Int)

    var diagnosticCode: String {
      switch self {
      case .unauthorized: "unauthorized"
      case .unsupported: "private_api_rejected"
      case .accountMismatch: "account_mismatch"
      case .malformedResponse: "unexpected_response"
      case .authorizationPending: "authorization_pending"
      case .slowDown: "slow_down"
      case .denied: "access_denied"
      case .expiredCode: "expired_code"
      case .http(let status): "http_\(status)"
      case .secureStorage(let status): "keychain_\(status)"
      }
    }

    var errorDescription: String? {
      switch self {
      case .unauthorized: String(localized: "Reconnect Twitch watch rewards in Settings > Accounts.")
      case .unsupported: String(localized: "Twitch rejected the unofficial watch rewards connection.")
      case .accountMismatch: String(localized: "Use the same Twitch account that is signed in to Strozz.")
      case .malformedResponse: String(localized: "Twitch returned an unexpected watch rewards response.")
      case .authorizationPending: String(localized: "Waiting for Twitch sign-in.")
      case .slowDown: String(localized: "Twitch requested a slower sign-in check.")
      case .denied: String(localized: "Twitch watch rewards sign-in was canceled.")
      case .expiredCode: String(localized: "The Twitch code expired. Request a new code.")
      case .http(let code): String(localized: "Twitch watch rewards returned HTTP \(code).")
      case .secureStorage: String(localized: "Could not access secure storage for Twitch watch rewards.")
      }
    }
  }

  struct Stream: Equatable, Sendable {
    let channelID: String
    let broadcastID: String
    let login: String
  }

  struct Streak: Equatable, Sendable {
    /// Nil means Twitch returned no milestone, not a verified zero-length streak.
    let count: Int?
  }

  func deviceCode() async throws -> DeviceCode {
    let result: DeviceCode = try await json(
      form("device", fields: ["client_id": Self.clientID, "scopes": ""]))
    guard result.activationURL != nil, !result.device_code.isEmpty,
      !result.user_code.isEmpty, result.expires_in > 0, result.interval > 0 else {
      throw Failure.malformedResponse
    }
    return result
  }

  func exchange(_ deviceCode: String) async throws -> String {
    struct Token: Decodable { let access_token: String }
    let token: Token = try await json(form("token", fields: [
      "client_id": Self.clientID,
      "device_code": deviceCode,
      "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
    ]))
    guard !token.access_token.isEmpty else { throw Failure.malformedResponse }
    return token.access_token
  }

  func validate(_ token: String, expectedUserID: String) async throws -> Credential {
    struct Identity: Decodable {
      let client_id: String
      let user_id: String
      let login: String
      let expires_in: Int
    }
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/validate")!)
    request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
    let identity: Identity = try await json(request)
    guard identity.client_id == Self.clientID else { throw Failure.unsupported }
    guard identity.user_id == expectedUserID, !expectedUserID.isEmpty else {
      throw Failure.accountMismatch
    }
    guard identity.expires_in >= 0, !identity.login.isEmpty else { throw Failure.malformedResponse }
    struct CurrentUser: Decodable {
      struct User: Decodable { let id: String }
      let currentUser: User
    }
    let viewer: CurrentUser = try await graphQL(
      ["query": "query { currentUser { id } }"], token: token)
    guard viewer.currentUser.id == expectedUserID else { throw Failure.accountMismatch }
    return Credential(
      token: token, userID: identity.user_id, login: identity.login,
      expiresAt: identity.expires_in == 0
        ? nil : Date().addingTimeInterval(TimeInterval(identity.expires_in)))
  }

  func stream(login: String, token: String) async throws -> Stream? {
    struct Result: Decodable {
      struct User: Decodable {
        struct Broadcast: Decodable { let id: String }
        let id: String
        let stream: Broadcast?
      }
      let user: User?
    }
    let result: Result = try await graphQL([
      "query": "query StrozzWatchStream($login: String!) { user(login: $login) { id stream { id } } }",
      "variables": ["login": login],
    ], token: token)
    guard let user = result.user, let broadcast = user.stream else { return nil }
    guard !user.id.isEmpty, !broadcast.id.isEmpty else { throw Failure.malformedResponse }
    return Stream(channelID: user.id, broadcastID: broadcast.id, login: login)
  }

  func streak(channelID: String, token: String) async throws -> Streak {
    struct Result: Decodable {
      struct Channel: Decodable {
        struct Viewer: Decodable {
          struct Milestone: Decodable {
            struct Value: Decodable { let value: String }
            let watchStreakMilestone: Value
          }
          let watchStreakMilestone: Milestone?
        }
        let viewer: Viewer
        enum CodingKeys: String, CodingKey { case viewer = "self" }
      }
      let channel: Channel
    }
    let result: Result = try await graphQL([
      "operationName": "RewardList",
      "variables": ["channelID": channelID, "shouldIncludeAllSuspendedStreaks": false],
      "extensions": ["persistedQuery": [
        "version": 1,
        "sha256Hash": "0b1471876d7647993731b9e3c6a13bf304c67fb31d07f06a945d42286ee377c4",
      ]],
    ], token: token)
    guard let value = result.channel.viewer.watchStreakMilestone?.watchStreakMilestone.value else {
      return Streak(count: nil)
    }
    guard let count = Int(value), count >= 0 else { throw Failure.malformedResponse }
    return Streak(count: count)
  }

  /// A 204 acknowledges ingestion only. The streak query, not this response, supplies the UI count.
  func reportMinute(stream: Stream, userID: String, muted: Bool, now: Date) async throws {
    let event: [[String: Any]] = [[
      "event": "minute-watched",
      "properties": [
        "user_id": userID, "channel_id": stream.channelID, "channel": stream.login,
        "broadcast_id": stream.broadcastID, "logged_in": true, "live": true,
        "hidden": false, "muted": muted, "location": "channel", "player": "site",
        "minutes_logged": 1, "client_time": now.ISO8601Format(),
      ],
    ]]
    let data = try JSONSerialization.data(withJSONObject: event).base64EncodedString()
    var request = URLRequest(url: URL(string: "https://spade.twitch.tv/track")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = encodedForm(["data": data])
    let (_, response) = try await perform(request)
    guard response.statusCode == 204 else { throw Failure.http(response.statusCode) }
  }

  private func form(_ path: String, fields: [String: String]) -> URLRequest {
    var request = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/\(path)")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = encodedForm(fields)
    return request
  }

  private func encodedForm(_ fields: [String: String]) -> Data {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return Data(fields.sorted { $0.key < $1.key }.map { key, value in
      "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&").utf8)
  }

  private struct Envelope<Value: Decodable>: Decodable {
    struct GraphError: Decodable { let message: String? }
    let data: Value?
    let errors: [GraphError]?
  }

  private struct OAuthError: Decodable {
    let message: String?
    let error: String?
  }

  func graphQL<Value: Decodable>(_ body: [String: Any], token: String) async throws -> Value {
    var request = TwitchAPIClient.graphQLRequest(clientID: Self.clientID)
    request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let envelope: Envelope<Value> = try await json(request)
    guard envelope.errors?.isEmpty != false else { throw Failure.unsupported }
    guard let value = envelope.data else { throw Failure.malformedResponse }
    return value
  }

  private func json<Value: Decodable>(_ request: URLRequest) async throws -> Value {
    let (data, response) = try await perform(request)
    guard (200...299).contains(response.statusCode) else {
      let error = try? JSONDecoder().decode(OAuthError.self, from: data)
      switch error?.message ?? error?.error {
      case "authorization_pending": throw Failure.authorizationPending
      case "slow_down": throw Failure.slowDown
      case "access_denied": throw Failure.denied
      case "expired_token", "invalid_device_code": throw Failure.expiredCode
      default: throw Failure.http(response.statusCode)
      }
    }
    do { return try JSONDecoder().decode(Value.self, from: data) }
    catch { throw Failure.malformedResponse }
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.timeoutInterval = 12
    let (data, response) = try await load(request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else { throw Failure.malformedResponse }
    if response.statusCode == 401 { throw Failure.unauthorized }
    if response.statusCode == 403 { throw Failure.unsupported }
    return (data, response)
  }
}
