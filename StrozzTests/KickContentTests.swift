import XCTest

#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class KickContentTests: XCTestCase {
  private let uuid = "00000000-0000-0000-0000-000000000001"

  func testOfflineProfileIgnoresUnusableLivePlaybackPlaceholder() throws {
    let data = Data(#"{"slug":"creator","user":{"username":"Creator","bio":"Offline bio"},"livestream":null,"playback_url":"?token=fixture","previous_livestreams":[]}"#.utf8)
    let content = try KickChannelContentService.decode(data, slug: "creator")
    XCTAssertFalse(content.channel.isLive)
    XCTAssertEqual(content.description, "Offline bio")
    XCTAssertTrue(content.videos.isEmpty)
    XCTAssertNil(try KickPlaybackService.parseChannel(data, requestedSlug: "creator").playbackURL)
    XCTAssertThrowsError(try KickPlaybackService.parseChannel(
      Data(#"{"slug":"creator","livestream":{"session_title":"Live"},"playback_url":"https://untrusted.invalid/live.m3u8"}"#.utf8),
      requestedSlug: "creator"))
  }

  func testPublicArchivesUseStableProviderIDsAndMillisecondDurations() throws {
    let content = try KickChannelContentService.decode(channelDocument(), slug: "creator")
    XCTAssertEqual(content.channel.slug, "creator")
    XCTAssertEqual(content.followerCount, 100)
    XCTAssertEqual(content.description, "About this creator")
    XCTAssertEqual(content.videos.count, 1)
    let video = try XCTUnwrap(content.videos.first)
    XCTAssertEqual(video.id, "kick:\(uuid)")
    XCTAssertEqual(video.platform, .kick)
    XCTAssertEqual(video.lengthSeconds, 50381)
    XCTAssertNotNil(video.publishedAt)
    XCTAssertEqual(video.viewCount, 123)
    XCTAssertEqual(video.thumbnailURL?.host, "images.kick.com")
  }

  func testPrivatePrunedDeletedAndActiveBroadcastsAreNotListed() throws {
    for change in [#""is_private":true"#, #""is_pruned":true"#,
                   #""deleted_at":"2026-10-30 00:00:00""#, #""status":"private""#] {
      XCTAssertTrue(try KickChannelContentService.decode(channelDocument(videoFields: change), slug: "creator").videos.isEmpty)
    }
    XCTAssertTrue(try KickChannelContentService.decode(channelDocument(live: true), slug: "creator").videos.isEmpty)
    XCTAssertThrowsError(try KickChannelContentService.decode(channelDocument(), slug: "another"))
  }

  func testArchiveResolutionRequestsUUIDAndValidatesPublicMedia() async throws {
    let url = try await KickChannelContentService.broadcastURL(id: "kick:\(uuid)") { request in
      XCTAssertEqual(request.url?.host, "kick.com")
      XCTAssertEqual(request.url?.path, "/api/v1/video/00000000-0000-0000-0000-000000000001")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      return (Data(#"{"status":"public","source":"https://stream.kick.com/path/master.m3u8"}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    XCTAssertEqual(url.host, "stream.kick.com")
  }

  func testArchiveResolutionRejectsPrivateAndUntrustedSources() throws {
    for source in ["http://stream.kick.com/master.m3u8", "https://stream.kick.com.evil.invalid/master.m3u8",
                   "https://user:password@stream.kick.com/master.m3u8", "https://stream.kick.com:444/master.m3u8",
                   "https://stream.kick.com/page.html"] {
      let data = try JSONSerialization.data(withJSONObject: ["status": "public", "source": source])
      XCTAssertThrowsError(try KickChannelContentService.decodeBroadcastURL(data))
    }
    for field in [#""is_private":true"#, #""is_pruned":true"#, #""deleted_at":"yesterday""#] {
      XCTAssertThrowsError(try KickChannelContentService.decodeBroadcastURL(
        Data("{\"status\":\"public\",\"source\":\"https://stream.kick.com/master.m3u8\",\(field)}".utf8)))
    }
  }

  func testClipCatalogueUsesQualifiedIdentityAndRejectsPrivateOrForeignChannels() throws {
    let clip = clipDocument()
    let page = try KickChannelContentService.decodeClips(
      Data("{\"clips\":[\(clip),\(clip)],\"nextCursor\":\"opaque+/=\"}".utf8), slug: "creator")
    XCTAssertEqual(page.clips.map(\.id), ["kick:clip_fixture"])
    XCTAssertEqual(page.clips.first?.durationSeconds, 143)
    XCTAssertEqual(page.nextCursor, "opaque+/=")
    XCTAssertTrue(try KickChannelContentService.decodeClips(
      Data("{\"clips\":[\(clip)],\"nextCursor\":null}".utf8), slug: "another").clips.isEmpty)
    XCTAssertTrue(try KickChannelContentService.decodeClips(
      Data("{\"clips\":[\(clipDocument(privacy: "private"))],\"nextCursor\":null}".utf8), slug: "creator").clips.isEmpty)
  }

  func testFreshClipResolverRejectsWrongIdentityPrivacyAndUntrustedMedia() throws {
    let data = Data("{\"clip\":\(clipDocument())}".utf8)
    XCTAssertEqual(try KickChannelContentService.decodeClipURL(data, expectedID: "clip_fixture").host, "clips.kick.com")
    XCTAssertThrowsError(try KickChannelContentService.decodeClipURL(data, expectedID: "clip_other"))
    for source in ["http://clips.kick.com/clip.m3u8", "https://clips.kick.com.evil.invalid/clip.m3u8",
                   "https://clips.kick.com/clip.html"] {
      XCTAssertThrowsError(try KickChannelContentService.decodeClipURL(
        Data("{\"clip\":\(clipDocument(source: source))}".utf8), expectedID: "clip_fixture"))
    }
    XCTAssertThrowsError(try KickChannelContentService.decodeClipURL(
      Data("{\"clip\":\(clipDocument(privacy: "private"))}".utf8), expectedID: "clip_fixture"))
  }

  func testLegacyHistoryRemainsTwitchAndKickRoundTripsSeparately() throws {
    let data = Data(#"{"login":"same","displayName":"Same","gameName":"Game","lastWatchedAt":0,"watchCount":3}"#.utf8)
    let legacy = try JSONDecoder().decode(WatchHistoryEntry.self, from: data)
    XCTAssertEqual(legacy.platform, .twitch)
    XCTAssertEqual(legacy.channelKey, "same")
    var kick = legacy
    kick.sourcePlatform = .kick
    let restored = try JSONDecoder().decode(WatchHistoryEntry.self, from: JSONEncoder().encode(kick))
    XCTAssertEqual(restored.channelKey, "kick:same")
    XCTAssertNotEqual(restored.id, legacy.id)
  }

  func testConfirmedCreatorFeedbackKeysIncludeBothProvidersButNotSameNamedStrangers() {
    let channel = KickChannel(slug: "same", displayName: "Same", title: "", category: "",
      viewerCount: nil, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    XCTAssertEqual(KickUnifiedFeed.identityKeys(for: channel, links: [:]), ["kick:same"])
    XCTAssertEqual(KickUnifiedFeed.identityKeys(for: channel, links: ["creator": "same"]), ["creator", "kick:same"])
    XCTAssertEqual(KickUnifiedFeed.identityKeys(for: channel, links: ["one": "same", "two": "same"]), ["kick:same"])
  }

  func testMixedHistoryAndRecommendationsCannotReintroduceCostreamDuplicate() {
    var twitch = KickChannel(slug: "creator", displayName: "Creator", title: "", category: "",
      viewerCount: 70, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    twitch.platform = .twitch
    let kick = KickChannel(slug: "creator", displayName: "Creator", title: "", category: "",
      viewerCount: 30, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    let merged = KickUnifiedFeed.merge(twitch: [twitch, kick], kick: [], links: ["creator": "creator"])
    XCTAssertEqual(merged.map(\.channelKey), ["creator"])
    XCTAssertEqual(merged.first?.combinedViewerCount, 100)
    var offline = KickChannel(slug: "creator", displayName: "Creator", title: "", category: "",
      viewerCount: nil, isLive: false, chatroomID: nil, imageURL: nil).followedChannel
    offline.platform = .twitch
    let promoted = KickUnifiedFeed.merge(twitch: [offline, kick], kick: [], links: ["creator": "creator"])
    XCTAssertEqual(promoted.map(\.channelKey), ["kick:creator"])
    let first = KickChannel(slug: "first", displayName: "First", title: "", category: "",
      viewerCount: 1, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    XCTAssertEqual(KickUnifiedFeed.preservingOrder(of: [kick, first, twitch],
      merged: [first] + merged, links: ["creator": "creator"]).map(\.channelKey), ["creator", "kick:first"])
  }

  #if os(tvOS) || os(macOS)
  func testTopShelfLinksKeepProviderAndRejectAmbiguousOrUnknownPlatforms() throws {
    let kick = TopShelf.channelDeepLink(login: "same", platform: "kick")
    XCTAssertEqual(TopShelf.channelKey(from: kick), "kick:same")
    XCTAssertEqual(TopShelf.channelKey(from: TopShelf.channelDeepLink(login: "same")), "same")
    for raw in ["strozz://channel/same?platform=unknown", "strozz://channel/same?platform=kick&platform=twitch",
                "strozz://channel/a/b", "https://channel/same"] {
      XCTAssertNil(TopShelf.channelKey(from: try XCTUnwrap(URL(string: raw))))
    }
  }

  func testLegacyTopShelfSnapshotDecodesWithoutProvider() throws {
    let raw = Data(#"{"id":"old","login":"same","displayName":"Same","title":"","gameName":""}"#.utf8)
    let item = try JSONDecoder().decode(TopShelfSnapshot.Item.self, from: raw)
    XCTAssertEqual(item.channelKey, "same")
    var kick = item
    kick.sourcePlatform = "kick"
    XCTAssertEqual(kick.channelKey, "kick:same")
  }

  func testTopShelfRefreshMergesConfirmedCreatorAndPreservesIndependentSources() throws {
    let twitch = TopShelfSnapshot.Item(id: "creator", login: "creator", displayName: "Creator",
      title: "", gameName: "", viewerCount: 70)
    var kick = TopShelfSnapshot.Item(id: "kick:creator", login: "creator", displayName: "Creator",
      title: "", gameName: "", viewerCount: 30, sourcePlatform: "kick")
    XCTAssertEqual(TopShelfSnapshot.mergingCreators([twitch, kick]).count, 2)
    kick.creatorKey = "creator"
    let merged = TopShelfSnapshot.mergingCreators([twitch, kick])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.channelKey, "creator")
    XCTAssertEqual(merged.first?.viewerCount, 100)
    XCTAssertEqual(TopShelfSnapshot.sourceItems(in: merged).compactMap(\.viewerCount), [70, 30])
    let restored = try JSONDecoder().decode([TopShelfSnapshot.Item].self, from: JSONEncoder().encode(merged))
    XCTAssertEqual(restored, merged)
    let kickOnly = TopShelfSnapshot.mergingCreators([kick], knownItems: restored)
    XCTAssertEqual(kickOnly.first?.channelKey, "kick:creator")
    XCTAssertEqual(kickOnly.first?.identityKey, "creator")
    XCTAssertEqual(kickOnly.first?.viewerCount, 30)
    XCTAssertEqual(TopShelfSnapshot.mergingCreators([twitch], knownItems: kickOnly).first?.identityKey,
      kickOnly.first?.identityKey)
  }
  #endif

  #if !os(tvOS)
  func testMobileBroadcastResumeKeepsKickProvider() throws {
    let video = try XCTUnwrap(KickChannelContentService.decode(channelDocument(), slug: "creator").videos.first)
    let progress = MobileVODProgress(video: video, login: "creator", displayName: "Creator", avatarURL: nil,
      seconds: 300, updatedAt: Date())
    let restored = try JSONDecoder().decode(MobileVODProgress.self, from: JSONEncoder().encode(progress))
    XCTAssertEqual(restored.selection.channel.id, "kick:creator")
    XCTAssertEqual(restored.selection.video.id, video.id)
  }

  func testMobileHistoryRankingDoesNotMixSameHandleAcrossProviders() throws {
    var twitch = KickChannel(slug: "same", displayName: "Same", title: "", category: "",
      viewerCount: 100, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    let kick = twitch
    twitch.platform = .twitch
    let history = [WatchHistoryEntry(login: "same", displayName: "Same", gameName: "",
      lastWatchedAt: Date(), watchCount: 10, sourcePlatform: .kick)]
    let ranked = MobileHomeFeed.homeChannels(follows: [twitch, kick], watched: [],
      recommendations: [], history: history, category: nil)
    XCTAssertEqual(ranked.map(\.channelKey), ["kick:same", "same"])
  }
  #endif

  private func channelDocument(videoFields: String = #""status":"public""#, live: Bool = false) -> Data {
    let status = videoFields.contains("\"status\"") ? "" : "\"status\":\"public\","
    return Data("""
    {"slug":"creator","user":{"username":"Creator","bio":"About this creator"},"livestream":null,
     "followersCount":100,"previous_livestreams":[{"session_title":"A broadcast","duration":50381000,
     "is_live":\(live),"created_at":"2026-10-29 20:07:19","views":123,
     "thumbnail":{"src":"https://images.kick.com/thumb.webp"},
     "video":{"uuid":"\(uuid)",\(status)\(videoFields)}}]}
    """.utf8)
  }

  private func clipDocument(privacy: String = "public", source: String = "https://clips.kick.com/path/clip.m3u8") -> String {
    """
    {"id":"clip_fixture","title":"A clip","privacy":"\(privacy)","views":12,"duration":143,
    "video_url":"\(source)","created_at":"2026-10-31T00:00:00Z","channel":{"slug":"creator"}}
    """
  }
}
