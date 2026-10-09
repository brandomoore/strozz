import SwiftUI
import XCTest

@testable import StrozzMobile

@MainActor
final class MobileLoadingPresentationTests: XCTestCase {
  func testLoadingReadyAndErrorRenderAcrossThemes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    defer { window.rootViewController = previous }
    let channel = FollowedChannel(
      id: "fixture", login: "fixture", displayName: "Live channel",
      title: "Fixture stream", gameName: "", viewerCount: 1200,
      thumbnailURL: nil, profileImageURL: nil, isLive: true)
    for theme in AppTheme.allCases {
      let model = MobilePlaybackModel(muted: true)
      defer { model.stop() }
      let palette = theme.palette(systemColorScheme: .light)
      let content = MobileVideoView(
        model: model, channel: channel, hideChat: .constant(false),
        isFullscreen: false, videoController: MobileVideoController(), onCollapse: {},
        onClose: {}, onCollapseDragChanged: { _ in }, onCollapseDragEnded: { _ in },
        onFullscreen: {}, onScene: { _ in }
      )
      .frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 500 : 220)
      .environment(\.themePalette, palette)
      .preferredColorScheme(theme.preferredColorScheme)
      let host = UIHostingController(rootView: content)
      window.rootViewController = host
      await layout(host)
      XCTAssertEqual(model.presentationState, .loading)
      capture(host, name: "loading-\(theme.rawValue)")

      model.displayReady(true, for: model.player)
      await layout(host)
      XCTAssertEqual(model.presentationState, .ready)
      capture(host, name: "ready-\(theme.rawValue)")

      model.displayReady(false, for: model.player)
      await layout(host)
      XCTAssertEqual(model.presentationState, .loading)

      model.activateAudioSession = { throw NSError(domain: "AudioFixture", code: 1) }
      model.start(channel: "fixture")
      await layout(host)
      XCTAssertEqual(model.presentationState, .unavailable)
      capture(host, name: "error-\(theme.rawValue)")
    }
  }

  private func layout(_ host: UIViewController) async {
    host.view.layoutIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    host.view.layoutIfNeeded()
  }

  private func capture(_ host: UIViewController, name: String) {
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
