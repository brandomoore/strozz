import XCTest

@testable import Strozz

@MainActor
final class YouTubeMergedChatViewerTests: XCTestCase {
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

  func testPlayerUsesMergedChatCountWithoutSnapshotAlias() {
    let player = PlayerView(channel: "valkyrae", auth: TwitchAuthSession())
    player.chat.youtubeConcurrentViewers = 14_841
    XCTAssertEqual(player.youtubeViewerCountForCurrentStream, 14_841)
  }
}
