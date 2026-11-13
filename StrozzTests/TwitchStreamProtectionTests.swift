import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

@MainActor
final class TwitchStreamProtectionTests: XCTestCase {
  func testMetadataLookupBatchesDeduplicatesAndNeverProbesPlayback() async throws {
    let logins = (0..<205).map { "channel\($0)" } + ["CHANNEL0"]
    let state = ProbeState()
    let result = try await TwitchStreamProtection.encryptedLogins(logins, clientID: "test") { request in
      await MainActor.run { state.requests += 1 }
      XCTAssertEqual(request.url?.absoluteString, "https://gql.twitch.tv/gql")
      XCTAssertEqual(request.timeoutInterval, 6)
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      let variables = try XCTUnwrap(body["variables"] as? [String: [String]])
      let batch = try XCTUnwrap(variables["logins"])
      XCTAssertLessThanOrEqual(batch.count, 100)
      XCTAssertTrue(try XCTUnwrap(body["query"] as? String).contains("isEncrypted"))
      let users = batch.map { ["login": $0, "stream": ["isEncrypted": $0 == "channel0"]] as [String: Any] }
      let data = try JSONSerialization.data(withJSONObject: ["data": ["users": users]])
      return Self.response(request, data: data)
    }
    XCTAssertEqual(state.requests, 3)
    XCTAssertEqual(result, ["channel0"])
  }

  func testEmptyLookupDoesNotMakeARequest() async throws {
    let result = try await TwitchStreamProtection.encryptedLogins([], clientID: "test") { _ in
      XCTFail("No network work for an empty list")
      throw URLError(.badURL)
    }
    XCTAssertTrue(result.isEmpty)
  }

  func testOnlyExplicitCurrentEncryptionHidesChannelAndNextBroadcastReturns() async throws {
    let state = ProbeState()
    let load: TwitchStreamProtection.Loader = { request in
      let encrypted = await state.encrypted
      return Self.response(request, json: """
        {"data":{"users":[{"login":"PrimeVideo","stream":{"isEncrypted":\(encrypted)}},
        {"login":"normal","stream":{"isEncrypted":false}},
        {"login":"unknown","stream":{}},{"login":"offline","stream":null},null,
        {"login":"unrequested","stream":{"isEncrypted":true}}]}}
        """)
    }
    let logins = ["primevideo", "normal", "unknown", "offline"]
    let first = try await TwitchStreamProtection.encryptedLogins(logins, clientID: "test", load: load)
    XCTAssertEqual(first, ["primevideo"])
    state.encrypted = false
    let next = try await TwitchStreamProtection.encryptedLogins(logins, clientID: "test", load: load)
    XCTAssertTrue(next.isEmpty, "A previous encrypted broadcast must not blacklist the channel")
  }

  func testMetadataFailuresAreNotAnEncryptedClassification() async {
    for json in ["{}", #"{"errors":[{"message":"Unavailable"}],"data":{"users":[]}}"#, "invalid"] {
      do {
        _ = try await TwitchStreamProtection.encryptedLogins(["primevideo"], clientID: "test") {
          Self.response($0, json: json)
        }
        XCTFail("Expected explicit metadata failure")
      } catch {}
    }
  }

  func testSharedFilteringIsConditionalAndProviderSpecific() {
    let protected = channel(encrypted: true)
    let playable = channel(encrypted: false)
    var offline = protected
    offline = FollowedChannel(id: offline.id, login: offline.login, displayName: offline.displayName,
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil,
      isLive: false, isEncrypted: true)
    var kick = protected
    kick.platform = .kick
    XCTAssertTrue(StreamPlatforms.both.filter([protected]).isEmpty)
    XCTAssertEqual(StreamPlatforms.both.filter([playable, offline, kick]), [playable, offline, kick])
    XCTAssertTrue(protected.isEncrypted, "Filtering must not modify the backing follow data")
    var linked = protected
    linked.kick = KickChannel(slug: "playable-kick", displayName: "Playable", title: "", category: "",
      viewerCount: 1, isLive: true, chatroomID: nil, imageURL: nil)
    XCTAssertEqual(StreamPlatforms.both.filter([linked]).first?.channelKey, "kick:playable-kick")
  }

  func testDiscoveryUsesExistingRequestsAndRestoresUnencryptedResults() async throws {
    let state = ProbeState()
    let loader: NetworkClient.DataLoader = { request in
      let encrypted = await MainActor.run {
        state.requests += 1
        return state.encrypted
      }
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      XCTAssertTrue(body.contains("isEncrypted"))
      let stream = """
        {"id":"live","title":"Broadcast","isEncrypted":\(encrypted),"viewersCount":100,
        "broadcaster":{"login":"primevideo","displayName":"PrimeVideo"}}
        """
      if body.contains("Search(") {
        return Self.response(request, json: """
          {"data":{"searchFor":{"channels":{"edges":[{"item":{"id":"user","login":"primevideo","stream":\(stream)}}]}}}}
          """)
      }
      if body.contains("GameStreams") {
        return Self.response(request, json: #"{"data":{"game":{"streams":{"edges":[{"node":\#(stream)}]}}}}"#)
      }
      return Self.response(request, json: #"{"data":{"streams":{"edges":[{"node":\#(stream)}]}}}"#)
    }
    let preferences = StreamPlatformPreferences.shared
    let original = preferences.selection
    preferences.selection = .both
    defer { preferences.selection = original }
    let browse = BrowseService(creatorLinks: [:], loadData: loader)
    let search = SearchService(loadData: loader, loadKickSearch: { _ in .init(channels: [], categories: []) })
    for protection in [true, false] {
      state.encrypted = protection
      let recommended = try await RecommendationsService.fetchRecommendedChannels(limit: 10, loadData: loader)
      let demo = try await FollowedChannelsDemoProvider(loadData: loader).fetchTrendingChannels()
      await browse.loadStreams(for: TwitchCategory(id: "sports", name: "Sports", boxArtURL: nil, viewerCount: nil),
        filter: .twitch)
      await search.search("primevideo", filter: .twitch)
      for channels in [StreamPlatforms.both.filter(recommended), StreamPlatforms.both.filter(demo),
                       browse.categoryStreams, search.channelResults] {
        XCTAssertEqual(channels.count, protection ? 0 : 1)
      }
    }
    XCTAssertEqual(state.requests, 8, "Exactly one existing request per discovery operation; no playback probes")
  }

  func testFollowingMetadataIsBatchedAndFollowsAreNotChanged() async throws {
    let state = ProbeState()
    let fetcher = FollowedChannelsFetcher { request in
      XCTAssertEqual(request.httpMethod, request.url?.host == "gql.twitch.tv" ? "POST" : "GET")
      if request.url?.host == "gql.twitch.tv" {
        let encrypted = await MainActor.run {
          state.requests += 1
          return state.encrypted
        }
        return Self.response(request, json: """
          {"data":{"users":[{"login":"primevideo","stream":{"isEncrypted":\(encrypted)}}]}}
          """)
      }
      if request.url?.path == "/helix/users" {
        return Self.response(request, json: #"{"data":[{"id":"168843586","login":"primevideo"}]}"#)
      }
      return Self.response(request, json: """
        {"data":[{"user_id":"168843586","user_login":"primevideo","user_name":"PrimeVideo",
        "game_name":"Sports","title":"Broadcast","viewer_count":10,"is_mature":false,
        "thumbnail_url":"","type":"live"}]}
        """)
    }
    for protection in [true, false] {
      state.encrypted = protection
      let channels = try await fetcher.fetchLiveFollowedChannels(clientID: "test", accessToken: "test", userID: "test")
      XCTAssertEqual(channels.count, 1, "Retain the raw follow; only the visible projection is filtered")
      XCTAssertEqual(channels.first?.isEncrypted, protection)
      XCTAssertEqual(StreamPlatforms.both.filter(channels).count, protection ? 0 : 1)
    }
    XCTAssertEqual(state.requests, 2)
  }

  func testOnlyExplicitCDMFailureGetsProtectedPlaybackError() {
    for (json, expected) in [
      (#"[{"error_code":"no_cdm_specified"}]"#, PlaybackError.protectedBroadcast),
      (#"[{"error_code":"access_denied"}]"#, .http(403)),
      ("invalid", .http(403)),
    ] {
      XCTAssertThrowsError(try PlaybackService.validatePlaylistResponse(Data(json.utf8), status: 403)) {
        XCTAssertEqual($0 as? PlaybackError, expected)
      }
    }
  }

  func testLivePrimeVideoIsExcludedWithoutAPlaybackProbe() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["STROZZ_RUN_LIVE_PROTECTION_TESTS"] == "1",
      "Requires a live encrypted PrimeVideo broadcast.")
    let channels = try await RecommendationsService.fetchRecommendedChannels(limit: 30)
    let prime = try XCTUnwrap(channels.first { $0.login.lowercased() == "primevideo" })
    XCTAssertTrue(prime.isEncrypted)
    XCTAssertFalse(StreamPlatforms.both.filter(channels).contains { $0.login.lowercased() == "primevideo" })
    XCTAssertFalse(StreamPlatforms.both.filter(channels).isEmpty)
    let encrypted = try await TwitchStreamProtection.encryptedLogins(
      ["primevideo"], clientID: TwitchConfig.webPublicClientID,
      load: { try await URLSession.shared.data(for: $0) })
    XCTAssertEqual(encrypted, ["primevideo"])
  }

  private func channel(encrypted: Bool) -> FollowedChannel {
    FollowedChannel(id: "168843586", login: "primevideo", displayName: "PrimeVideo",
      title: "", gameName: "Sports", viewerCount: 10, thumbnailURL: nil, profileImageURL: nil,
      isLive: true, isEncrypted: encrypted)
  }

  @MainActor private final class ProbeState {
    var encrypted = true
    var requests = 0
  }

  nonisolated private static func response(_ request: URLRequest, json: String) -> (Data, URLResponse) {
    response(request, data: Data(json.utf8))
  }

  nonisolated private static func response(_ request: URLRequest, data: Data) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
