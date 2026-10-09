import AVKit
import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobilePictureInPictureTests: XCTestCase {
  func testDownwardGestureMustBeDeliberateAndVertical() {
    XCTAssertTrue(MobilePlayerCollapseGesture.shouldCollapse(translation: .init(width: 0, height: 70)))
    XCTAssertTrue(MobilePlayerCollapseGesture.shouldCollapse(translation: .init(width: -30, height: 90)))
    for translation in [CGSize(width: 0, height: 69), .init(width: 100, height: 80),
                        .init(width: 0, height: -120), .init(width: 150, height: 0)] {
      XCTAssertFalse(MobilePlayerCollapseGesture.shouldCollapse(translation: translation))
    }
  }

  func testCollapseAndBackgroundRetainPlaybackAndRestoreTheSameSurface() async {
    let session = makeSession()
    session.select(channel("first"))
    let model = session.model
    let player = model.player
    let surface = session.videoController
    session.willStartPictureInPicture()
    session.sceneChanged(.background)
    XCTAssertTrue(session.keepsPlayingInBackground)
    session.didStartPictureInPicture()
    session.collapseAnimationCompleted()
    session.presentationDismissed()
    XCTAssertFalse(session.isPresented)
    XCTAssertTrue(model.isActive)
    session.sceneChanged(.active)
    await Task.yield()
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(model.player === player)
    XCTAssertTrue(session.videoController === surface)

    var restored: Bool?
    session.restorePictureInPicture { restored = $0 }
    XCTAssertTrue(session.isPresented)
    XCTAssertNil(restored, "Wait for the actual player surface before completing AVKit restoration")
    session.playerDidAppear()
    XCTAssertEqual(restored, true)
    session.didStopPictureInPicture()
    XCTAssertEqual(session.pictureInPictureState, .inline)
    XCTAssertTrue(model.isActive)
    XCTAssertTrue(session.videoController === surface)
    session.close()
  }

  func testSelectingAnotherStreamStopsOldPlaybackBeforeReplacingPiP() {
    let session = makeSession()
    session.select(channel("first"))
    let old = session.model
    session.didStartPictureInPicture()
    session.select(channel("second"))
    XCTAssertFalse(old.isActive)
    XCTAssertEqual(session.channel?.login, "first", "Wait for the native PiP stop transition")
    XCTAssertEqual(session.pictureInPictureState, .stopping)
    session.select(channel("third"))
    session.didStopPictureInPicture()
    XCTAssertEqual(session.channel?.login, "third", "The newest selection wins")
    XCTAssertTrue(session.isPresented)
    XCTAssertFalse(session.model === old)
    XCTAssertTrue(session.model.isActive)
    session.close()
  }

  func testSelectingTheCurrentStreamRestoresWithoutRestarting() {
    let session = makeSession()
    let channel = channel("first")
    session.select(channel)
    let model = session.model
    session.didStartPictureInPicture()
    session.select(channel)
    XCTAssertTrue(session.isPresented)
    session.playerDidAppear()
    session.didStopPictureInPicture()
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(model.isActive)
    session.close()
  }

  func testLateDismissalCannotCloseAReplacementOrRestoredPlayer() {
    let session = makeSession()
    session.select(channel("first"))
    session.didStartPictureInPicture()
    session.select(channel("second"))
    session.didStopPictureInPicture()
    session.presentationDismissed()
    XCTAssertTrue(session.isPresented)
    XCTAssertEqual(session.channel?.login, "second")
    XCTAssertTrue(session.model.isActive)

    session.didStartPictureInPicture()
    session.select(channel("second"))
    session.playerDidAppear()
    session.didStopPictureInPicture()
    session.presentationDismissed()
    XCTAssertTrue(session.model.isActive)
    session.isPresented = false
    session.presentationDismissed()
    XCTAssertNil(session.channel, "An actual inline dismissal must still stop playback")
  }

  func testDismissalWaitsForBothNativePiPAndThePageExitInEitherOrder() {
    for animationFirst in [true, false] {
      let session = makeSession()
      session.select(channel("first"))
      session.willStartPictureInPicture()
      if animationFirst { session.collapseAnimationCompleted() }
      else { session.didStartPictureInPicture() }
      XCTAssertTrue(session.isPresented, "Neither transition alone should detach the source")
      if animationFirst { session.didStartPictureInPicture() }
      else { session.collapseAnimationCompleted() }
      XCTAssertFalse(session.isPresented)
      XCTAssertTrue(session.model.isActive)
      session.close()
      session.didStopPictureInPicture()
    }
  }

  func testFailedStartCannotDismissAfterTheExitAnimationCompletes() {
    let session = makeSession()
    session.select(channel("first"))
    session.willStartPictureInPicture()
    session.failedToStartPictureInPicture(URLError(.notConnectedToInternet))
    session.collapseAnimationCompleted()
    XCTAssertTrue(session.isPresented)
    XCTAssertTrue(session.model.isActive)
    XCTAssertNotNil(session.errorMessage)
    session.close()
  }

  func testNativeCloseAndVODReplacementEndLivePlayback() {
    for explicitClose in [false, true] {
      let session = makeSession()
      session.select(channel("first"))
      let old = session.model
      session.didStartPictureInPicture()
      if explicitClose { session.close() }
      session.didStopPictureInPicture()
      XCTAssertNil(session.channel)
      XCTAssertFalse(session.isPresented)
      XCTAssertFalse(old.isActive)
      XCTAssertNil(session.videoController.player)
    }
  }

  func testCloseDuringStartWaitsForAVKitAndCannotResurrectPlayback() {
    let session = makeSession()
    session.select(channel("first"))
    session.willStartPictureInPicture()
    session.close()
    XCTAssertFalse(session.model.isActive)
    session.didStartPictureInPicture()
    XCTAssertEqual(session.pictureInPictureState, .stopping)
    session.didStopPictureInPicture()
    XCTAssertNil(session.channel)
    XCTAssertFalse(session.isPresented)
  }

  func testStartFailureKeepsInlinePlayerAndReportsError() {
    let session = makeSession()
    session.select(channel("first"))
    let model = session.model
    session.collapse()
    XCTAssertNotNil(session.errorMessage, "Unavailable PiP must not silently dismiss the player")
    XCTAssertTrue(session.isPresented)
    XCTAssertTrue(model.isActive)
    session.willStartPictureInPicture()
    session.failedToStartPictureInPicture(URLError(.notConnectedToInternet))
    XCTAssertEqual(session.pictureInPictureState, .inline)
    XCTAssertTrue(session.isPresented)
    XCTAssertNotNil(session.errorMessage)
    session.close()
  }

  func testReplacementDuringFailedStartStillStartsSelectedStream() {
    let session = makeSession()
    session.select(channel("first"))
    session.willStartPictureInPicture()
    session.select(channel("second"))
    session.failedToStartPictureInPicture(URLError(.cancelled))
    XCTAssertEqual(session.channel?.login, "second")
    XCTAssertTrue(session.isPresented)
    session.close()
  }

  func testBackgroundAudioIsDeclaredForNativePiP() {
    XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
  }

  func testOptInNativePiPContinuesAfterDismissalRestoresAndReplacesPlayback() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_PIP_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_PIP_LIVE_TESTS=1 on a PiP-capable device.")
    }
    XCTAssertTrue(AVPictureInPictureController.isPictureInPictureSupported())
    let browse = BrowseService()
    await browse.loadCategories()
    let category = try XCTUnwrap(browse.categories.first)
    await browse.loadStreams(for: category)
    XCTAssertGreaterThanOrEqual(browse.categoryStreams.count, 2)
    let first = browse.categoryStreams[0]
    let second = browse.categoryStreams[1]
    let session = MobilePlaybackSession {
      let model = MobilePlaybackModel(muted: true)
      model.select(.native)
      return model
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let root = UIHostingController(rootView: MobileRootView()
      .environment(session).environment(ThemeManager())
      .environment(TwitchAuthSession()).environment(TwitchWatchRewardsSession())
      .environment(TwitchAccountSync())
      .environment(\.scenePhase, .active))
    window.rootViewController = root
    defer {
      session.close()
      window.rootViewController = previous
    }
    root.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    session.select(first)
    try await waitUntil { session.model.isReadyForDisplay && !session.model.isLoading }
    XCTAssertTrue(session.model.requestsNativePlayback)
    let model = session.model
    let surface = session.videoController
    try await Task.sleep(for: .seconds(2))
    session.collapse()
    try await waitUntil { session.pictureInPictureState == .active || session.errorMessage != nil }
    XCTAssertNil(session.errorMessage)
    XCTAssertEqual(session.pictureInPictureState, .active)
    try await waitUntil { root.presentedViewController == nil }
    XCTAssertFalse(session.isPresented)
    XCTAssertNil(surface.view.window)
    let start = model.player.currentTime().seconds
    try await Task.sleep(for: .seconds(12))
    XCTAssertGreaterThan(model.player.currentTime().seconds - start, 8)
    XCTAssertTrue(model.isActive)
    XCTAssertNil(model.errorMessage)
    XCTAssertTrue(model.requestsNativePlayback)

    session.select(first)
    try await waitUntil { session.pictureInPictureState == .inline && surface.view.window != nil }
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(session.videoController === surface)
    XCTAssertTrue(model.isReadyForDisplay)
    session.collapse()
    try await waitUntil { session.pictureInPictureState == .active }
    try await waitUntil { root.presentedViewController == nil }
    session.select(second)
    try await waitUntil { session.channel?.channelKey == second.channelKey && session.model.isReadyForDisplay }
    XCTAssertFalse(model.isActive)
    XCTAssertFalse(session.model === model)
    XCTAssertTrue(session.isPresented)
    try await Task.sleep(for: .seconds(2))
    session.collapse()
    try await waitUntil { session.pictureInPictureState == .active }
    session.close()
    try await waitUntil { session.channel == nil }
    XCTAssertFalse(session.model.isActive)
    XCTAssertFalse(session.isPresented)
    let evidence = XCTAttachment(string: "Native PiP retained detached playback for 12 seconds, restored the same surface, replaced the stream, and stopped.")
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<450 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Timed out waiting for native playback/PiP transition", file: file, line: line)
    throw URLError(.timedOut)
  }

  private func makeSession() -> MobilePlaybackSession {
    MobilePlaybackSession {
      let model = MobilePlaybackModel(muted: true) { _ in throw URLError(.cancelled) }
      model.activateAudioSession = {}
      model.loadMetadata = { _ in nil }
      return model
    }
  }

  private func channel(_ login: String) -> FollowedChannel {
    FollowedChannel(id: login, login: login, displayName: login, title: "Live stream",
                    gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }
}
