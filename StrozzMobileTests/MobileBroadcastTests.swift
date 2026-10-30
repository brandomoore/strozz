import AVFoundation
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileBroadcastTests: XCTestCase {
  private func model() -> MobilePlaybackModel {
    let session = CreatorLiveSession(resolve: { CreatorLiveSources(root: $0) },
      loadTwitch: { _ in .unknown }, defaults: nil)
    let model = MobilePlaybackModel(muted: true, creatorSession: session)
    model.activateAudioSession = {}
    model.loadMetadata = { _ in nil }
    model.prepareLayoutFixtureMetadata(channel: .init(id: "fixture", login: "fixture",
      displayName: "Fixture", title: "", gameName: "", viewerCount: nil,
      thumbnailURL: nil, profileImageURL: nil, isLive: true))
    session.start(.init(platform: .twitch, channel: "fixture"))
    session.hermes.prepareBroadcastFixture(channel: "fixture")
    return model
  }

  func testStreamDownReplacesTerminalNativeFailureWithoutAnotherRetry() {
    let model = model()
    defer { model.stop() }
    model.recoverNative(.transportCodec)
    XCTAssertNotNil(model.nativeFailure)
    model.creatorSession.hermes.handle(HermesBroadcastTests.frame("stream-down"))
    XCTAssertTrue(model.isOffline)
    XCTAssertNil(model.nativeFailure)
    XCTAssertEqual(model.errorMessage, String(localized: "The stream has ended."))
    XCTAssertNil(model.player.currentItem)
    model.retry()
    XCTAssertFalse(model.isOffline)
    XCTAssertNil(model.errorMessage)
  }

  func testNetworkLossAndChatOnlyDoNotPresentOffline() {
    let model = model()
    defer { model.stop() }
    model.creatorSession.hermes.invalidateBroadcastStatus()
    XCTAssertFalse(model.isOffline)
    model.selectMode(.chatOnly)
    model.creatorSession.hermes.handle(HermesBroadcastTests.frame("stream-down"))
    XCTAssertFalse(model.isOffline)
    XCTAssertNil(model.errorMessage)
  }

  func testStoppedModelIgnoresSubsequentBroadcastEvents() {
    let model = model()
    model.stop()
    model.creatorSession.hermes.handle(HermesBroadcastTests.frame("stream-down"))
    XCTAssertFalse(model.isOffline)
    XCTAssertNil(model.player.currentItem)
  }

  func testPausedVideoSurvivesStreamDownAndCanReachItsBufferedEnd() {
    let model = model()
    defer { model.stop() }
    model.select(.fixed("fixture"))
    let item = model.player.currentItem
    XCTAssertNotNil(item)
    model.togglePlayPause()
    XCTAssertTrue(model.isPaused)
    model.creatorSession.hermes.handle(HermesBroadcastTests.frame("stream-down"))
    XCTAssertFalse(model.isOffline)
    XCTAssertTrue(model.player.currentItem === item)
    model.togglePlayPause()
    XCTAssertFalse(model.isPaused)
    XCTAssertTrue(model.presentConfirmedBroadcastEndIfNeeded(reachedEnd: true))
    XCTAssertTrue(model.isOffline)
  }
}
