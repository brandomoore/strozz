import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobilePlayerGeometryTests: XCTestCase {
  func testSurfaceDiagnosticsDistinguishUnmountedHiddenAndDetachedVideo() throws {
    let controller = MobileVideoController()
    XCTAssertFalse(controller.diagnosticSnapshot().flags["surface_in_window"] ?? true)
    XCTAssertFalse(controller.isViewLoaded, "Collecting diagnostics must not mount a video surface")
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    controller.view.layoutIfNeeded()
    var snapshot = controller.diagnosticSnapshot()
    XCTAssertEqual(snapshot.flags["surface_in_window"], true)
    XCTAssertEqual(snapshot.flags["layer_attached"], true)
    XCTAssertEqual(snapshot.flags["surface_intersects_window"], true)
    XCTAssertEqual(snapshot.metrics["surface_opacity"], 1)
    controller.view.alpha = 0
    snapshot = controller.diagnosticSnapshot()
    XCTAssertEqual(snapshot.metrics["surface_opacity"], 0)
    controller.view.alpha = 1
    controller.playerLayer.isHidden = true
    XCTAssertEqual(controller.diagnosticSnapshot().flags["surface_hidden"], true)
    controller.playerLayer.removeFromSuperlayer()
    XCTAssertEqual(controller.diagnosticSnapshot().flags["layer_attached"], false)
  }

  func testSideVideoIsCenteredAndChatNeverExceedsOneThirdOr320Points() {
    for size in [CGSize(width: 568, height: 320), .init(width: 750, height: 380),
                 .init(width: 900, height: 400), .init(width: 1024, height: 740),
                 .init(width: 1366, height: 972)] {
      let chat = MobilePlayerLayout.sideChatWidth(in: size)
      let frame = MobilePlayerLayout.sideBySide.videoFrame(in: size)
      XCTAssertLessThanOrEqual(chat, size.width / 3)
      XCTAssertLessThanOrEqual(chat, 320)
      XCTAssertEqual(frame.midY, size.height / 2, accuracy: 0.001)
      XCTAssertEqual(frame.midX, (size.width - chat) / 2, accuracy: 0.001)
      XCTAssertEqual(frame.width / frame.height, 16 / 9, accuracy: 0.001)
      XCTAssertTrue(CGRect(x: 0, y: 0, width: size.width - chat, height: size.height).contains(frame))
    }
    XCTAssertEqual(MobilePlayerLayout.sideChatWidth(in: CGSize(width: 750, height: 380)), 250)
  }

  func testTabletLayoutRespectsTheFullAvailableWindow() {
    XCTAssertEqual(MobilePlayerLayout.resolve(size: .init(width: 834, height: 1100), isPhone: false,
      hideChat: false), .portrait)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: .init(width: 1024, height: 500), isPhone: false,
      hideChat: false), .sideBySide)
    XCTAssertEqual(MobilePlayerLayout.resolve(size: .init(width: 700, height: 500), isPhone: false,
      hideChat: false), .portrait)
    for mode in [MobilePlaybackMode.audioOnly, .chatOnly] {
      XCTAssertEqual(MobilePlayerLayout.resolve(size: .init(width: 1024, height: 500), isPhone: false,
        hideChat: true, mode: mode), .chatOnly)
      XCTAssertEqual(MobilePlayerLayout.chatOnly.videoFrame(in: .init(width: 1024, height: 500)), .zero)
    }
  }

  func testCustomChatWidthIsBoundedAndKeepsVideoCentered() {
    for size in [CGSize(width: 568, height: 320), .init(width: 750, height: 380),
                 .init(width: 1024, height: 740), .init(width: 1366, height: 972)] {
      for requested in [150.0, 200, 320, 480, 600, 1000] {
        let width = MobilePlayerLayout.sideChatWidth(in: size, preferredWidth: requested)
        let frame = MobilePlayerLayout.sideBySide.videoFrame(in: size, preferredChatWidth: requested)
        XCTAssertLessThanOrEqual(width, min(600, size.width / 2))
        XCTAssertGreaterThanOrEqual(width + 0.001, min(200, size.width / 3))
        XCTAssertGreaterThanOrEqual(frame.width + 0.001, min(380, size.width * 2 / 3, size.height * 16 / 9))
        XCTAssertEqual(frame.midX, (size.width - width) / 2, accuracy: 0.001)
        XCTAssertEqual(frame.midY, size.height / 2, accuracy: 0.001)
        XCTAssertEqual(frame.width / frame.height, 16 / 9, accuracy: 0.001)
        XCTAssertLessThanOrEqual(frame.maxX, size.width - width)
        XCTAssertEqual(MobilePlayerLayout.sideChatWidth(in: size, preferredWidth: width), width,
          "Passing a resolved width to the video must not change the pane boundary")
      }
      let automatic = MobilePlayerLayout.sideChatWidth(in: size)
      XCTAssertEqual(MobilePlayerLayout.sideChatWidth(in: size, preferredWidth: automatic), automatic, accuracy: 0.001)
    }
    XCTAssertEqual(MobilePlayerLayout.sideChatWidth(in: .init(width: 1366, height: 972), preferredWidth: 480), 480)
    XCTAssertEqual(MobilePlayerLayout.sideChatWidth(in: .init(width: 750, height: 380), preferredWidth: 480), 370)
  }

  func testDividerTracksItsInitialWidthWithoutCompoundingAndClampsBothDirections() {
    let size = CGSize(width: 1366, height: 972)
    var drag = MobileChatWidthDrag(initialWidth: 320)
    for translation in [-40.0, -80, 40, 80] {
      drag.translation = translation
      XCTAssertEqual(drag.width(in: size, preferredWidth: 500), 320 - translation)
    }
    drag.translation = -2000
    XCTAssertEqual(drag.width(in: size, preferredWidth: 320), 600)
    drag.translation = 2000
    XCTAssertEqual(drag.width(in: size, preferredWidth: 320), 200)
    XCTAssertEqual(MobileChatWidthDrag().width(in: size, preferredWidth: 0), 320,
      "Cancelling a gesture restores the saved preference")
    for layout in [MobilePlayerLayout.portrait, .videoOnly] {
      XCTAssertEqual(layout.videoFrame(in: size, preferredChatWidth: 600), layout.videoFrame(in: size))
    }
  }

  func testLandscapeControlsFitTheVideoAtLargeTextSizes() {
    let state = RotationMountState()
    defer { state.session.close() }
    for width in [568.0 * 2 / 3, 380, 500] {
      for typeSize in [DynamicTypeSize.large, .accessibility3] {
        let host = UIHostingController(rootView: MobilePlayerControls(
          model: state.session.model, viewerCount: 1200, hideChat: .constant(false), isFullscreen: true,
          onCollapse: {}, onClose: {}, onFullscreen: {}, onQuality: {}, onShare: {},
          onInteraction: {}, onRoutes: { _ in }, showsChatToggle: true, landscapeChannel: state.channel)
          .environment(\.dynamicTypeSize, typeSize))
        let videoSize = CGSize(width: width, height: width * 9 / 16)
        let fitted = host.sizeThatFits(in: videoSize)
        XCTAssertLessThanOrEqual(fitted.width, videoSize.width + 1)
        XCTAssertLessThanOrEqual(fitted.height, videoSize.height + 1, "\(typeSize), \(width)")
      }
    }
  }

  func testPortraitAndVideoOnlyKeepTheirExistingFrames() {
    let size = CGSize(width: 390, height: 750)
    XCTAssertEqual(MobilePlayerLayout.portrait.videoFrame(in: size),
      CGRect(x: 0, y: 0, width: 390, height: 390.0 * 9 / 16))
    XCTAssertEqual(MobilePlayerLayout.videoOnly.videoFrame(in: size), CGRect(origin: .zero, size: size))
  }

  func testResizingBetweenPortraitAndLandscapeKeepsTheMountedChatAndVideo() async throws {
    let state = RotationMountState()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let host = UIHostingController(rootView: RotationMountHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
      state.session.close()
    }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))
    let initialChat = try XCTUnwrap(findChat(in: host.view))
    let initialVideo = state.session.videoController.view
    let player = state.session.model.player
    defer { state.defaults.removePersistentDomain(forName: state.suite) }
    for landscape in [true, false, true, false] {
      state.landscape = landscape
      for width in [200.0, 480, 600, MobileChatWidth.automatic] {
        state.defaults.set(width, forKey: PersistenceKey.mobileChatWidthValue)
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        XCTAssertTrue(findChat(in: host.view) === initialChat)
        XCTAssertTrue(state.session.videoController.view === initialVideo)
        XCTAssertTrue(state.session.model.player === player)
      }
    }
    for mode in [MobilePlaybackMode.audioOnly, .chatOnly, .video] {
      state.session.model.selectMode(mode)
      try await Task.sleep(for: .milliseconds(150))
      host.view.layoutIfNeeded()
      XCTAssertTrue(findChat(in: host.view) === initialChat)
      XCTAssertTrue(state.session.videoController.view === initialVideo)
      XCTAssertTrue(state.session.model.player === player)
    }
  }

  private func findChat(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView, !(view is UITextView) { return scroll }
    return view.subviews.lazy.compactMap { self.findChat(in: $0) }.first
  }
}

@MainActor
@Observable
private final class RotationMountState {
  var landscape = false
  let suite = "ChatWidthMount.\(UUID())"
  let defaults: UserDefaults
  let auth = TwitchAuthSession()
  let channel = FollowedChannel(id: "fixture", login: "fixture", displayName: "Sample streamer",
    title: "A stream description that appears with the controls", gameName: "Game",
    viewerCount: 100, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  let session: MobilePlaybackSession

  init() {
    defaults = UserDefaults(suiteName: suite)!
    session = .layoutFixture(channel: channel)
    session.model.chat.isConnected = true
  }
}

private struct RotationMountHarness: View {
  let state: RotationMountState

  var body: some View {
    MobilePlayerView(channel: state.channel, session: state.session)
      .environment(state.auth)
      .defaultAppStorage(state.defaults)
      .environment(\.verticalSizeClass, state.landscape ? .compact : .regular)
      .frame(width: state.landscape ? 750 : 390, height: state.landscape ? 380 : 750)
  }
}
