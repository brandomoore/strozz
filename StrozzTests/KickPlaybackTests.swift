import AVFoundation
import XCTest

#if os(tvOS)
  @testable import Strozz
#else
  @testable import StrozzMobile
#endif

final class KickPlaybackTests: XCTestCase {
  private static let masterURL = URL(
    string: "https://edge.live-video.net/live/master.m3u8?token=fixture")!
  private static let channelJSON = Data(
    #"""
    {"slug":"fixture","user":{"username":"Fixture"},"livestream":{"session_title":"Live","viewer_count":12,
    "categories":[{"name":"Just Chatting"}]},"chatroom":{"id":123},
    "playback_url":"https://edge.live-video.net/live/master.m3u8?token=fixture"}
    """#.utf8)
  private static let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=1920x1080,FRAME-RATE=60,CODECS="avc1.64002a,mp4a.40.2"
    source.m3u8?token=fixture
    #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=852x480,FRAME-RATE=30,CODECS="avc1.4d401f,mp4a.40.2"
    low.m3u8?token=fixture
    """

  func testChannelInputsCannotBecomeArbitraryHostsOrPaths() throws {
    for input in [
      "fixture", "@FiXtUrE", "https://kick.com/fixture", "https://www.kick.com/fixture/",
    ] {
      XCTAssertEqual(try KickPlaybackService.slug(from: input), "fixture")
    }
    for input in [
      "", "../fixture", "https://kick.com.evil.test/fixture", "http://kick.com/fixture",
      "https://kick.com/a/b", "https://user:pass@kick.com/fixture", "search", "api",
    ] {
      XCTAssertThrowsError(try KickPlaybackService.slug(from: input), input)
    }
  }

  func testRealChannelShapePreservesLiveMetadataButNotSignedURLsInTheChannelModel() throws {
    let result = try KickPlaybackService.parseChannel(Self.channelJSON, requestedSlug: "fixture")
    XCTAssertEqual(result.channel.chatroomID, 123)
    XCTAssertEqual(result.channel.viewerCount, 12)
    XCTAssertTrue(result.channel.isLive)
    XCTAssertEqual(result.playbackURL, Self.masterURL)
    let encoded = String(decoding: try JSONEncoder().encode(result.channel), as: UTF8.self)
    XCTAssertFalse(encoded.contains("token"))
    XCTAssertFalse(encoded.contains("live-video.net"))
    XCTAssertThrowsError(
      try KickPlaybackService.parseChannel(Self.channelJSON, requestedSlug: "someone-else"))
    XCTAssertThrowsError(
      try KickPlaybackService.parseChannel(
        Data(#"{"slug":"fixture"}"#.utf8), requestedSlug: "fixture"))
  }

  func testOfflineRequiresAnActualNullLiveField() throws {
    let channel = try KickPlaybackService.parseChannel(
      Data(#"{"slug":"fixture","livestream":null}"#.utf8), requestedSlug: "fixture")
    XCTAssertFalse(channel.channel.isLive)
    XCTAssertNil(channel.playbackURL)
  }

  func testAllAdvertisedQualitiesRemainSelectableWithDistinctIDsAndAbsoluteURLs() throws {
    let qualities = try KickPlaybackService.qualities(in: Self.master, base: Self.masterURL)
    XCTAssertEqual(qualities.map(\.name), ["1080p60", "480p"])
    XCTAssertEqual(Set(qualities.map(\.id)).count, 2)
    XCTAssertEqual(
      qualities[1].url.absoluteString, "https://edge.live-video.net/live/low.m3u8?token=fixture")
    XCTAssertTrue(qualities.allSatisfy { !$0.isAudioOnly })
    for url in [
      "https://live-video.net.evil.test/live", "http://edge.live-video.net/live",
      "https://127.0.0.1/live", "https://user:pass@edge.live-video.net/live",
    ] {
      XCTAssertFalse(KickPlaybackService.validMediaURL(URL(string: url)!))
    }
  }

  func testResolutionUsesFreshChannelURLsAndRetainsTheFullMaster() async throws {
    let resolved = try await KickPlaybackService.resolve("fixture") { request in
      let url = try XCTUnwrap(request.url)
      let bytes = url.host == "kick.com" ? Self.channelJSON : Data(Self.master.utf8)
      return (
        bytes, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    func testKickPreviewsUseKickVariantsForInitialPlaybackAndRecovery() async throws {
      for original in [false, true] {
        let url = try await KickPlaybackService.previewHLSURL(for: "fixture", original: original) { request in
          let url = try XCTUnwrap(request.url)
          XCTAssertTrue(url.host == "kick.com" || url.host == "edge.live-video.net")
          let data = url.host == "kick.com" ? Self.channelJSON : Data(Self.master.utf8)
          return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(url.lastPathComponent, original ? "source.m3u8" : "low.m3u8")
      }
    }
    XCTAssertEqual(resolved.playback.master, Self.masterURL)
    XCTAssertEqual(resolved.playback.qualities.count, 2)
    XCTAssertEqual(resolved.channel.slug, "fixture")
  }

  func testRenditionSelectionSurvivesRotatedHostsPathsAndBitrates() throws {
    let first = try KickPlaybackService.qualities(in: Self.master, base: Self.masterURL)
    let fresh = Self.master
      .replacingOccurrences(of: "9000000", with: "9100000")
      .replacingOccurrences(
        of: "source.m3u8?token=fixture", with: "https://fresh.live-video.net/new/source.m3u8"
      )
      .replacingOccurrences(
        of: "low.m3u8?token=fixture", with: "https://other.live-video.net/rotated/low.m3u8")
    let second = try KickPlaybackService.qualities(in: fresh, base: Self.masterURL)
    XCTAssertEqual(first.map(\.id), second.map(\.id))
    XCTAssertNotEqual(first.map(\.url), second.map(\.url))
    XCTAssertThrowsError(
      try KickPlaybackService.qualities(
        in:
          "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200000\nunknown.m3u8", base: Self.masterURL))
  }

  func testBlockedKickRequestsStayRestrictedNotOffline() async {
    for status in [401, 403, 404, 500] {
      do {
        _ = try await KickPlaybackService.channel("fixture") { request in
          (
            Data(),
            HTTPURLResponse(
              url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
          )
        }
        XCTFail("Expected explicit failure")
      } catch {
        let expected: KickPlaybackService.Failure =
          [401, 403].contains(status)
          ? .restricted : status == 404 ? .notFound : .http(status)
        XCTAssertEqual(error as? KickPlaybackService.Failure, expected)
      }
    }
  }

  func testChatNegotiatesTheCurrentAnonymousPusherApp() async throws {
    let url = try await KickPlaybackService.chatURL { request in
      XCTAssertEqual(request.url?.host, "web.kick.com")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
      let body = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      let client = try XCTUnwrap(body["client"] as? [String: String])
      XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(client["id"])))
      let data = Data(
        #"{"data":{"connections":[{"provider":"pusher","credentials":{"app_key":"freshpublickey1234567","cluster":"us2"}}]}}"#
          .utf8)
      return (
        data,
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    XCTAssertEqual(url.host, "ws-us2.pusher.com")
    XCTAssertEqual(url.path, "/app/freshpublickey1234567")
    XCTAssertEqual(url.scheme, "wss")
  }

  func testChatNegotiationCannotRedirectTheSocketToAnArbitraryHost() async {
    do {
      _ = try await KickPlaybackService.chatURL { request in
        let data = Data(
          #"{"data":{"connections":[{"provider":"pusher","credentials":{"app_key":"freshpublickey1234567","cluster":"evil.test/path"}}]}}"#
            .utf8)
        return (
          data,
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
      XCTFail("Untrusted provider metadata must not become an arbitrary WebSocket URL")
    } catch {
      XCTAssertEqual(error as? KickPlaybackService.Failure, .chatUnavailable)
    }
  }

  func testIVSPrefetchHintsPreserveSequencesDatesAndDiscontinuities() throws {
    let media = """
      #EXTM3U
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:42
      #EXT-X-PROGRAM-DATE-TIME:2026-10-24T00:00:00.000Z
      #EXTINF:2,
      42.ts
      #EXT-X-PREFETCH:43.ts
      #EXT-X-PREFETCH-DISCONTINUITY
      #EXT-X-PREFETCH:44.ts
      """
    let manifest = try NativeCMAF.manifest(media, url: Self.masterURL)
    XCTAssertTrue(manifest.hasPrefetch)
    XCTAssertEqual(manifest.entries.map(\.sequence), [42, 43, 44])
    XCTAssertEqual(manifest.entries.map(\.discontinuity), [0, 0, 1])
    XCTAssertNil(manifest.entries[1].duration)
    XCTAssertNil(manifest.entries[2].date)
    let twitch = try NativeCMAF.manifest(
      media.replacingOccurrences(
        of: "#EXT-X-PREFETCH:", with: "#EXT-X-TWITCH-PREFETCH:"), url: Self.masterURL)
    XCTAssertEqual(twitch.entries.map(\.sequence), manifest.entries.map(\.sequence))
    XCTAssertEqual(twitch.entries.map(\.duration), manifest.entries.map(\.duration))
  }
}
