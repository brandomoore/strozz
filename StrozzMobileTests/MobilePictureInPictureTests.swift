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

  func testMiniPlayerGeometryStaysInsidePhoneTabletAndSplitView() {
    for size in [CGSize(width: 390, height: 750), .init(width: 800, height: 350),
                 .init(width: 1024, height: 1300), .init(width: 320, height: 600)] {
      let expanded = CGRect(origin: .zero, size: size)
      let mini = MobileMiniPlayerLayout.frame(in: size, isPhone: size.width < 900)
      XCTAssertTrue(expanded.contains(mini))
      XCTAssertEqual(mini.width / mini.height, 16 / 9, accuracy: 0.001)
      XCTAssertEqual(MobileMiniPlayerLayout.interpolate(from: expanded, to: mini, progress: 0), expanded)
      XCTAssertEqual(MobileMiniPlayerLayout.interpolate(from: expanded, to: mini, progress: 1), mini)
      let midway = MobileMiniPlayerLayout.interpolate(from: expanded, to: mini, progress: 0.5)
      XCTAssertEqual(midway.width, (expanded.width + mini.width) / 2)
      XCTAssertEqual(midway.midY, (expanded.midY + mini.midY) / 2)
    }
  }

  func testMinimizeAndExpandNeverStartNativePiPOrReplaceTheSource() {
    let session = makeSession()
    session.select(channel("first"))
    let model = session.model
    let surface = session.videoController
    for _ in 0..<3 {
      session.collapse()
      XCTAssertFalse(session.isExpanded)
      XCTAssertEqual(session.pictureInPictureState, .inline)
      XCTAssertTrue(model.isActive)
      XCTAssertNil(session.errorMessage, "In-app minimization does not require native PiP capability")
      session.expand()
      XCTAssertTrue(session.isExpanded)
      XCTAssertTrue(session.model === model)
      XCTAssertTrue(session.videoController === surface)
    }
    session.close()
  }

  func testNativeBackgroundAndForegroundRetainThePreviousInAppLayout() async throws {
    for minimized in [false, true] {
      let session = makeSession()
      session.select(channel("first"))
      if minimized { session.collapse() }
      let model = session.model
      let surface = session.videoController
      session.willStartPictureInPicture()
      session.sceneChanged(.background)
      session.didStartPictureInPicture()
      XCTAssertTrue(session.keepsPlayingInBackground)
      XCTAssertTrue(model.isActive)
      XCTAssertEqual(session.isExpanded, !minimized)
      session.sceneChanged(.active)
      try await waitUntil { session.pictureInPictureState == .restoring }
      XCTAssertEqual(session.pictureInPictureState, .restoring)
      session.restorePictureInPicture { _ in }
      session.playerDidAppear()
      session.didStopPictureInPicture()
      XCTAssertEqual(session.pictureInPictureState, .inline)
      XCTAssertEqual(session.isExpanded, !minimized)
      XCTAssertTrue(session.model === model)
      XCTAssertTrue(session.videoController === surface)
      XCTAssertTrue(model.isActive)
      session.close()
    }
  }

  func testQuickForegroundReturnDuringNativeStartStopsPiPAfterStart() async throws {
    let session = makeSession()
    session.select(channel("first"))
    session.collapse()
    session.willStartPictureInPicture()
    session.sceneChanged(.background)
    session.sceneChanged(.active)
    session.didStartPictureInPicture()
    try await waitUntil { session.pictureInPictureState == .restoring }
    XCTAssertEqual(session.pictureInPictureState, .restoring)
    session.didStopPictureInPicture()
    XCTAssertFalse(session.isExpanded)
    XCTAssertTrue(session.model.isActive)
    session.close()
  }

  func testSystemRestoreExpandsTheSamePlayer() {
    let session = makeSession()
    session.select(channel("first"))
    let model = session.model
    session.collapse()
    session.didStartPictureInPicture()
    var restored: Bool?
    session.restorePictureInPicture { restored = $0 }
    XCTAssertTrue(session.isExpanded)
    XCTAssertNil(restored, "An unmounted source must wait before completing AVKit restoration")
    session.playerDidAppear()
    XCTAssertNil(restored, "Mounting the compact source is not enough to restore full screen")
    session.playerDidLayoutExpandedSurface()
    XCTAssertEqual(restored, true)
    session.didStopPictureInPicture()
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(model.isActive)
    session.close()
  }

  func testSystemRestoreRequestWinsOverForegroundAutoReturn() async throws {
    let session = makeSession()
    session.select(channel("first"))
    session.collapse()
    session.didStartPictureInPicture()
    session.sceneChanged(.background)
    session.sceneChanged(.active)
    XCTAssertEqual(session.pictureInPictureState, .active)
    var restored = false
    session.restorePictureInPicture { restored = $0 }
    XCTAssertTrue(session.isExpanded)
    session.playerDidLayoutExpandedSurface()
    XCTAssertTrue(restored)
    session.didStopPictureInPicture()
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(session.isExpanded)
    XCTAssertEqual(session.pictureInPictureState, .inline)
    XCTAssertTrue(session.model.isActive)
    session.close()
  }

  func testReturningToBackgroundCancelsPendingInlineReturn() async throws {
    let session = makeSession()
    session.select(channel("first"))
    session.collapse()
    session.didStartPictureInPicture()
    session.sceneChanged(.background)
    session.sceneChanged(.active)
    session.sceneChanged(.background)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(session.pictureInPictureState, .active)
    XCTAssertFalse(session.isExpanded)
    session.close()
    session.didStopPictureInPicture()
  }

  func testSystemRestoreCompletesOnlyAfterTheExpandedSurfaceIsLaidOut() async throws {
    let session = makeSession()
    let channel = channel("fixture")
    session.select(channel)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIHostingController(rootView: MobilePlayerView(channel: channel, session: session)
      .environment(TwitchAuthSession()))
    window.rootViewController = host
    defer { session.close(); window.rootViewController = previous }
    let surface = session.videoController
    try await waitUntil { surface.view.bounds.width > 320 }
    let expandedFrame = surface.playerLayer.convert(surface.playerLayer.bounds, to: window.layer)
    session.collapse()
    let compactWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 240 : 320
    try await waitUntil { abs(surface.view.bounds.width - compactWidth) < 1 }
    session.didStartPictureInPicture()
    var restoredFrame: CGRect?
    var renderedFrame: CGRect?
    session.restorePictureInPicture { restored in
      XCTAssertTrue(restored)
      restoredFrame = surface.playerLayer.convert(surface.playerLayer.bounds, to: window.layer)
      if let layer = surface.playerLayer.presentation(), let windowLayer = window.layer.presentation() {
        renderedFrame = layer.convert(layer.bounds, to: windowLayer)
      }
    }
    try await waitUntil { restoredFrame != nil }
    let destination = try XCTUnwrap(restoredFrame)
    XCTAssertEqual(destination.width, expandedFrame.width, accuracy: 1,
                   "AVKit must never receive the mini-player as its restore destination")
    XCTAssertEqual(destination.height, expandedFrame.height, accuracy: 1)
    XCTAssertEqual(destination.minX, expandedFrame.minX, accuracy: 1)
    XCTAssertEqual(destination.minY, expandedFrame.minY, accuracy: 1,
                   "The restoration destination must already be at the top, not centered")
    let renderedDestination = try XCTUnwrap(renderedFrame)
    XCTAssertEqual(renderedDestination.minY, expandedFrame.minY, accuracy: 1,
                   "The displayed layer tree must have committed the top-aligned destination")
    XCTAssertEqual(renderedDestination.width, expandedFrame.width, accuracy: 1)
    session.didStopPictureInPicture()
  }

  func testSelectingAnotherStreamStopsOldPlaybackBeforeReplacingNativePiP() {
    let session = makeSession()
    session.select(channel("first"))
    let old = session.model
    session.didStartPictureInPicture()
    session.select(channel("second"))
    XCTAssertFalse(old.isActive)
    XCTAssertEqual(session.channel?.login, "first")
    XCTAssertEqual(session.pictureInPictureState, .stopping)
    session.select(channel("third"))
    session.didStopPictureInPicture()
    XCTAssertEqual(session.channel?.login, "third", "The newest selection wins")
    XCTAssertTrue(session.isExpanded)
    XCTAssertFalse(session.model === old)
    XCTAssertTrue(session.model.isActive)
    session.close()
  }

  func testSelectingTheMinimizedStreamRestoresWithoutRestarting() {
    let session = makeSession()
    let channel = channel("first")
    session.select(channel)
    let model = session.model
    session.collapse()
    session.select(channel)
    XCTAssertTrue(session.isExpanded)
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(model.isActive)
    session.collapse()
    session.select(self.channel("second"))
    XCTAssertFalse(model.isActive)
    XCTAssertTrue(session.isExpanded)
    XCTAssertEqual(session.channel?.login, "second")
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
      XCTAssertFalse(session.isExpanded)
      XCTAssertFalse(old.isActive)
      XCTAssertNil(session.videoController.player)
    }
  }

  func testCloseDuringStartCannotResurrectPlayback() {
    let session = makeSession()
    session.select(channel("first"))
    session.willStartPictureInPicture()
    session.close()
    XCTAssertFalse(session.model.isActive)
    session.didStartPictureInPicture()
    XCTAssertEqual(session.pictureInPictureState, .stopping)
    session.didStopPictureInPicture()
    XCTAssertNil(session.channel)
    XCTAssertFalse(session.isExpanded)
  }

  func testStartFailureKeepsMiniPlayerAndReportsError() {
    let session = makeSession()
    session.select(channel("first"))
    session.collapse()
    session.willStartPictureInPicture()
    session.sceneChanged(.background)
    session.failedToStartPictureInPicture(URLError(.notConnectedToInternet))
    XCTAssertEqual(session.pictureInPictureState, .inline)
    XCTAssertFalse(session.isExpanded)
    XCTAssertTrue(session.model.isActive)
    XCTAssertNotNil(session.errorMessage)
    session.sceneChanged(.active)
    session.close()
  }

  func testReplacementDuringFailedStartStillStartsSelectedStream() {
    let session = makeSession()
    session.select(channel("first"))
    session.willStartPictureInPicture()
    session.select(channel("second"))
    session.failedToStartPictureInPicture(URLError(.cancelled))
    XCTAssertEqual(session.channel?.login, "second")
    XCTAssertTrue(session.isExpanded)
    session.close()
  }

  func testBackgroundAudioIsDeclaredForNativePiP() {
    XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
  }

  func testOptInMiniPlayerAndNativeHandoffKeepOnePlayingSurface() async throws {
    guard ProcessInfo.processInfo.environment["STROZZ_MOBILE_PIP_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Set STROZZ_MOBILE_PIP_LIVE_TESTS=1 on a PiP-capable device.")
    }
    XCTAssertTrue(AVPictureInPictureController.isPictureInPictureSupported())
    let browse = BrowseService()
    await browse.loadCategories()
    await browse.loadStreams(for: try XCTUnwrap(browse.categories.first))
    let first = try XCTUnwrap(browse.categoryStreams.first)
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
      .environment(TwitchAccountSync()).environment(\.scenePhase, .active))
    window.rootViewController = root
    defer { session.close(); window.rootViewController = previous }
    root.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    session.select(first)
    try await waitUntil { session.model.isReadyForDisplay && !session.model.isLoading }
    let model = session.model
    let surface = session.videoController
    let expandedWidth = surface.view.bounds.width
    session.collapse()
    try await waitUntil { surface.view.bounds.width < expandedWidth - 100 }
    XCTAssertEqual(session.pictureInPictureState, .inline)
    XCTAssertNotNil(surface.view.window)
    XCTAssertNil(root.presentedViewController)
    let start = model.player.currentTime().seconds
    try await Task.sleep(for: .seconds(3))
    XCTAssertGreaterThan(model.player.currentTime().seconds - start, 1)
    session.sceneChanged(.background)
    try await waitUntil { session.pictureInPictureState == .active || session.errorMessage != nil }
    XCTAssertNil(session.errorMessage)
    XCTAssertEqual(session.pictureInPictureState, .active)
    let nativeStart = model.player.currentTime().seconds
    try await Task.sleep(for: .seconds(8))
    XCTAssertGreaterThan(model.player.currentTime().seconds - nativeStart, 5)
    session.sceneChanged(.active)
    try await waitUntil { session.pictureInPictureState == .inline }
    XCTAssertFalse(session.isExpanded)
    XCTAssertTrue(session.model === model)
    XCTAssertTrue(session.videoController === surface)
    XCTAssertNotNil(surface.view.window)
    session.expand()
    try await waitUntil { abs(surface.view.bounds.width - expandedWidth) < 1 }
    XCTAssertTrue(model.isReadyForDisplay)
    XCTAssertTrue(model.requestsNativePlayback)
    XCTAssertNil(model.errorMessage)
  }

  private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<450 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Timed out waiting for playback/PiP transition", file: file, line: line)
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
