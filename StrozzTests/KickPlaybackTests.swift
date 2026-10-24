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

private actor KickResolutionGate {
  var requests: [PlatformLiveTarget] = []
  private var pending: [String: CheckedContinuation<PlatformLivePlayback.Resolution, Error>] = [:]
  func resolve(_ target: PlatformLiveTarget) async throws -> PlatformLivePlayback.Resolution {
    requests.append(target)
    return try await withCheckedThrowingContinuation { pending[target.id] = $0 }
  }
  func fail(_ target: PlatformLiveTarget) {
    pending.removeValue(forKey: target.id)?.resume(throwing: KickPlaybackService.Failure.restricted)
  }
  func reply(_ target: PlatformLiveTarget) {
    pending.removeValue(forKey: target.id)?.resume(
      returning: .init(
        playback: StreamPlayback(
          master: URL(string: "https://edge.live-video.net/fixture.m3u8")!, qualities: []),
        title: "Stale creator", viewers: 1))
  }
}

@MainActor
final class KickPlaybackLifecycleTests: XCTestCase {
  func testSourceSwitchKeepsTheMountedPlayerAndRejectsAStaleResolution() async throws {
    let gate = KickResolutionGate()
    let first = PlatformLiveTarget(platform: .kick, channel: "first")
    let second = PlatformLiveTarget(platform: .twitch, channel: "second")
    let model = PlatformLivePlayback(target: first, resolve: { try await gate.resolve($0) })
    defer { model.stop() }
    let player = model.player
    model.start()
    for _ in 0..<100 {
      if await gate.requests.count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    model.togglePause()
    model.switchSource(second)
    for _ in 0..<100 {
      if await gate.requests.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    await gate.reply(first)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertTrue(model.player === player)
    XCTAssertNil(model.player.currentItem)
    XCTAssertEqual(model.target, second)
    XCTAssertTrue(model.isPaused)
    XCTAssertTrue(model.title.isEmpty)
    await gate.fail(second)
    for _ in 0..<100 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(model.sources.count, 2)
  }

  func testDismissedOrBackgroundedKickResolveCannotRestartAudio() async throws {
    for stop in [false, true] {
      let gate = KickResolutionGate()
      let target = PlatformLiveTarget(platform: .kick, channel: "fixture")
      let model = PlatformLivePlayback(target: target, resolve: { try await gate.resolve($0) })
      model.start()
      for _ in 0..<100 {
        if await gate.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      if stop { model.stop() } else { model.sceneActive(false) }
      await gate.reply(target)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertNil(model.player.currentItem)
      XCTAssertEqual(model.player.rate, 0)
      model.stop()
    }
  }

  func testProviderIdentityValidationNeverUsesAKickSlugAsATwitchAccount() throws {
    XCTAssertEqual(
      try PlatformLiveTarget.validated(platform: .kick, input: "https://kick.com/fixture").id,
      "kick:fixture")
    XCTAssertEqual(
      try PlatformLiveTarget.validated(platform: .twitch, input: "https://twitch.tv/fixture").id,
      "twitch:fixture")
    XCTAssertThrowsError(
      try PlatformLiveTarget.validated(platform: .twitch, input: "https://kick.com/fixture"))
    XCTAssertThrowsError(
      try PlatformLiveTarget.validated(platform: .youtube, input: "https://example.test/live"))
    do {
      _ = try PlatformLiveTarget.validated(platform: .twitch, input: "https://kick.com/fixture")
      XCTFail("Wrong provider URL must be rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Twitch"))
      XCTAssertFalse(error.localizedDescription.contains("Kick"))
    }
  }

  func testMediaServicesResetRebuildsTheRendererWithoutUnpausing() async throws {
    let model = PlatformLivePlayback(
      target: .init(platform: .kick, channel: "fixture"),
      resolve: { _ in throw KickPlaybackService.Failure.restricted })
    defer { model.stop() }
    model.start()
    model.togglePause()
    for _ in 0..<100 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let oldPlayer = model.player
    model.mediaServicesReset()
    XCTAssertFalse(model.player === oldPlayer)
    XCTAssertTrue(model.isPaused)
    for _ in 0..<100 {
      if model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertNotNil(model.errorMessage)
    XCTAssertNil(model.player.currentItem)
    XCTAssertEqual(model.player.rate, 0)
  }
}
@MainActor
final class KickPlaybackLiveTests: XCTestCase {
  func testOptInKickAnonymousChatReceivesMessages() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_KICK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Explicit live Kick chat experiment only")
    }
    let chat = ChatService()
    defer { chat.disconnect() }
    chat.configureExperimentalKickMerge(
      enabled: true,
      channelOrURL: ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc")
    for _ in 0..<200 {
      if !chat.messages.isEmpty {
        XCTAssertNil(chat.channel, "Kick-only viewing must not join Twitch IRC")
        XCTAssertTrue(chat.kickStatusMessage?.hasPrefix("Connected") == true)
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Kick chat did not receive messages: \(chat.kickStatusMessage ?? "No status")")
  }

  func testOptInKickQualityAndPlatformHandoffs() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_KICK_LIVE_TESTS"] == "1",
      let twitch = ProcessInfo.processInfo.environment["STROZZ_KICK_SWITCH_TWITCH_CHANNEL"]
    else {
      throw XCTSkip("Explicit live Kick/Twitch handoff experiment only")
    }
    let kick = PlatformLiveTarget(
      platform: .kick,
      channel: ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc")
    let model = PlatformLivePlayback(target: kick)
    defer { model.stop() }
    let player = model.player
    model.start()
    try await assertDecoded(model, phase: "initial Kick Auto")
    let low = try XCTUnwrap(model.qualities.last(where: { !$0.isAudioOnly }))
    model.selectQuality(low.id)
    try await assertDecoded(model, phase: "explicit lowest Kick quality")
    XCTAssertEqual(model.qualityID, low.id)
    let lowSize = try XCTUnwrap(model.decodedSize)
    XCTAssertLessThanOrEqual(lowSize.height, 480)
    model.selectQuality(nil)
    try await assertDecoded(model, phase: "restored Kick Auto")
    XCTAssertNil(model.qualityID)
    model.switchSource(.init(platform: .twitch, channel: twitch))
    try await assertDecoded(model, phase: "Twitch handoff")
    XCTAssertEqual(model.target.platform, .twitch)
    model.switchSource(kick)
    try await assertDecoded(model, phase: "Kick handoff")
    XCTAssertEqual(model.target.platform, .kick)
    XCTAssertTrue(model.player === player, "Source switching must not replace the mounted renderer")
    model.togglePause()
    XCTAssertTrue(model.isPaused)
    XCTAssertFalse(model.isLoading)
    model.sceneActive(false)
    XCTAssertNil(model.player.currentItem)
    model.sceneActive(true)
    for _ in 0..<100 {
      if model.player.currentItem != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(model.player.currentItem)
    XCTAssertTrue(model.isPaused)
    XCTAssertEqual(model.player.rate, 0)
  }

  private func assertDecoded(_ model: PlatformLivePlayback, phase: String) async throws {
    for _ in 0..<400 {
      if let error = model.errorMessage {
        throw NSError(
          domain: "KickLiveTest", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "\(phase): \(error)"])
      }
      if model.decodedSize != nil, !model.isLoading,
        model.player.timeControlStatus == .playing
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    let description =
      "\(phase): status=\(model.player.currentItem?.status.rawValue ?? -1) clock=\(model.player.currentTime().seconds) loading=\(model.isLoading) quality=\(model.qualityID ?? "Auto")"
    XCTFail("No decoded video after \(description)")
    throw NSError(
      domain: "KickLiveTest", code: 2, userInfo: [NSLocalizedDescriptionKey: description])
  }

  func testOptInKickDecodedPlaybackAndLatencyComparison() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_KICK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Explicit live Kick playback/latency experiment only")
    }
    let slug = ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc"
    let model = PlatformLivePlayback(target: .init(platform: .kick, channel: slug))
    let baseline = AVPlayer()
    baseline.isMuted = true
    defer {
      model.stop()
      baseline.pause()
      baseline.replaceCurrentItem(with: nil)
    }
    let resolved = try await KickPlaybackService.resolve(slug)
    let item = AVPlayerItem(url: resolved.playback.master)
    baseline.replaceCurrentItem(with: item)
    baseline.play()
    model.start()
    var samples = 0
    var nativeLatencies: [Double] = []
    var baselineLatencies: [Double] = []
    for second in 0..<90 {
      try await Task.sleep(for: .seconds(1))
      if let error = model.errorMessage {
        XCTFail("Kick playback failed: \(error)")
        return
      }
      if second >= 30, model.decodedSize != nil, model.player.timeControlStatus == .playing,
        let native = model.player.currentItem?.currentDate(), let plain = item.currentDate(),
        baseline.timeControlStatus == .playing
      {
        samples += 1
        nativeLatencies.append(Date().timeIntervalSince(native))
        baselineLatencies.append(Date().timeIntervalSince(plain))
      }
      if second.isMultiple(of: 10) {
        print(
          "KICK_MEASUREMENT second=\(second) decoded=\(model.decodedSize != nil) playing=\(model.player.timeControlStatus == .playing)"
        )
      }
    }
    XCTAssertGreaterThanOrEqual(
      samples, 30, "A resolved URL or a ready item alone does not prove playback")
    if !nativeLatencies.isEmpty {
      let native = nativeLatencies.sorted()[nativeLatencies.count / 2]
      let plain = baselineLatencies.sorted()[baselineLatencies.count / 2]
      print(
        "KICK_LATENCY native_median_seconds=\(native) plain_hls_median_seconds=\(plain) samples=\(samples)"
      )
      let attachment = XCTAttachment(
        string: """
          {"channel":"\(slug)","native_median_seconds":\(native),"plain_hls_median_seconds":\(plain),"samples":\(samples),"actual_decoded_video":true,"platform":"\(PlaybackTelemetrySentry.platform)","measurement":"program_date_time_to_sample_time","environment":"simulator"}
          """)
      attachment.name = "Kick latency measurement.json"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertLessThan(
        native, plain, "Do not claim lowest latency unless incremental playback beats plain HLS")
    }
  }
}
