import XCTest

#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class YouTubeMergedChatViewerTests: XCTestCase {
  private var bootstrapHTML: String {
    #"""
      {"continuation":"unrelated","INNERTUBE_API_KEY":"test\u0026key",
      "INNERTUBE_CLIENT_VERSION":"v\u003d1","isLiveNow":true,"originalViewCount":"14841",
      "liveChatRenderer":{"continuation":"one\/two\\three\u003d"}}
      """#
  }

  func testBootstrapKeepsLiveChatPrecedenceAndDecodesJSONEscapesOnce() async throws {
    let parsed = try await ChatService.parseYouTubeBootstrap(Data(bootstrapHTML.utf8))
    XCTAssertEqual(parsed.apiKey, "test&key")
    XCTAssertEqual(parsed.clientVersion, "v=1")
    XCTAssertEqual(parsed.continuation, "one/two\\three=")
    XCTAssertEqual(parsed.concurrentViewers, 14_841)
  }

  func testLookupResolvesEscapedCanonicalURLAndFinalRedirectWithoutScanningInvalidHTML() async throws {
    let html = #"{"canonicalUrl":"https:\/\/www.youtube.com\/watch?v\u003dAbcd_12-xyz"}"#
    let canonical = try await ChatService.resolveYouTubeLookup(Data(html.utf8), finalURL: nil)
    XCTAssertEqual(canonical, "Abcd_12-xyz")
    let redirected = try await ChatService.resolveYouTubeLookup(Data("not HTML".utf8),
      finalURL: URL(string: "https://www.youtube.com/watch?v=Abcd_12-xyz"))
    XCTAssertEqual(redirected, "Abcd_12-xyz")
    let missing = try await ChatService.resolveYouTubeLookup(Data(#"{"videoId":"invalid"}"#.utf8), finalURL: nil)
    XCTAssertNil(missing)
  }

  func testBootstrapFallbackAndMalformedEscapesRemainExplicitFailures() async throws {
    let fallback = #"{"INNERTUBE_API_KEY":"test","INNERTUBE_CLIENT_VERSION":"v1","continuation":"fallback"}"#
    let parsed = try await ChatService.parseYouTubeBootstrap(Data(fallback.utf8))
    XCTAssertEqual(parsed.continuation, "fallback")
    for invalid in [
      #"{"INNERTUBE_API_KEY":"bad\u00zz","INNERTUBE_CLIENT_VERSION":"v1","continuation":"c"}"#,
      #"{"INNERTUBE_API_KEY":"test","INNERTUBE_CLIENT_VERSION":"v1"}"#,
    ] {
      do {
        _ = try await ChatService.parseYouTubeBootstrap(Data(invalid.utf8))
        XCTFail("Invalid bootstrap must not become a successful chat connection")
      } catch {
        XCTAssertEqual(error.localizedDescription, "Could not initialize YouTube live chat.")
      }
    }
  }

  func testCancelledBootstrapDoesNotReturnAStaleChatConnection() async {
    let data = Data(bootstrapHTML.utf8)
    let parsing = Task { try await ChatService.parseYouTubeBootstrap(data) }
    parsing.cancel()
    do {
      _ = try await parsing.value
      XCTFail("Cancelled chat work must not publish its bootstrap")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testOptInLargeUnicodeBootstrapKeepsMainActorResponsive() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_YOUTUBE_PARSER_PERFORMANCE"] == "1" else {
      throw XCTSkip("Opt in on an isolated simulator to measure large watch-page parsing.")
    }
    let page = Data((String(repeating: "視聴者 café 👋 chat ", count: 100_000) + bootstrapHTML).utf8)
    var maximumMainDelay = 0.0
    let heartbeat = Task { @MainActor in
      var previous = ContinuousClock.now
      for _ in 0..<50 {
        try await Task.sleep(for: .milliseconds(5))
        let now = ContinuousClock.now
        let interval = previous.duration(to: now).components
        maximumMainDelay = max(maximumMainDelay, Double(interval.seconds) + Double(interval.attoseconds) / 1e18)
        previous = now
      }
    }
    let started = ContinuousClock.now
    for _ in 0..<4 {
      let parsed = try await ChatService.parseYouTubeBootstrap(page)
      XCTAssertEqual(parsed.continuation, "one/two\\three=")
    }
    try await heartbeat.value
    let elapsed = started.duration(to: .now).components
    print("YOUTUBE_PARSE bytes=\(page.count) iterations=4 elapsed_seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) max_main_interval_seconds=\(maximumMainDelay)")
    XCTAssertLessThan(maximumMainDelay, 0.1, "Watch-page parsing must not hold playback's main actor")
  }

  func testLiveWatchPageSuppliesMergedChatViewerCountWithoutAlias() {
    let html = """
      {"isLiveNow":true,"originalViewCount":"14841"}
      """
    XCTAssertEqual(
      YouTubeConcurrentViewersService.concurrentViewers(inWatchHTML: html), 14_841)
  }

  func testRecordedVideoTotalIsNotShownAsLiveViewers() {
    let html = """
      {"isLiveNow":false,"originalViewCount":"14841"}
      """
    XCTAssertNil(YouTubeConcurrentViewersService.concurrentViewers(inWatchHTML: html))
  }

  func testYouTubeChatDisconnectClearsItsViewerCount() {
    let chat = ChatService()
    chat.youtubeConcurrentViewers = 14_841
    chat.stopYouTubeLoop(clearStatus: true)
    XCTAssertNil(chat.youtubeConcurrentViewers)
  }

  #if os(tvOS)
  func testPlayerUsesMergedChatCountWithoutSnapshotAlias() {
    let player = PlayerView(channel: "valkyrae", auth: TwitchAuthSession())
    player.chat.youtubeConcurrentViewers = 14_841
    XCTAssertEqual(player.youtubeViewerCountForCurrentStream, 14_841)
  }
  #endif
}
