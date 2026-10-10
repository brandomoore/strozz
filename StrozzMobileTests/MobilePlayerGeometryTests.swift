import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobilePlayerGeometryTests: XCTestCase {
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
  }

  func testLandscapeControlsFitTheVideoAtLargeTextSizes() {
    let state = RotationMountState()
    defer { state.session.close() }
    for width in [380.0, 500] {
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
    for landscape in [true, false, true, false] {
      state.landscape = landscape
      try await Task.sleep(for: .milliseconds(300))
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
  let auth = TwitchAuthSession()
  let channel = FollowedChannel(id: "fixture", login: "fixture", displayName: "Sample streamer",
    title: "A stream description that appears with the controls", gameName: "Game",
    viewerCount: 100, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  let session: MobilePlaybackSession

  init() {
    session = .layoutFixture(channel: channel)
    session.model.chat.isConnected = true
  }
}

private struct RotationMountHarness: View {
  let state: RotationMountState

  var body: some View {
    MobilePlayerView(channel: state.channel, session: state.session)
      .environment(state.auth)
      .environment(\.verticalSizeClass, state.landscape ? .compact : .regular)
      .frame(width: state.landscape ? 750 : 390, height: state.landscape ? 380 : 750)
  }
}
