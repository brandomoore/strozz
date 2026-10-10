import ImageIO
import SDWebImage
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileChatPerformanceTests: XCTestCase {
  func testOnlyViewportEmotesAnimateWithLongHistory() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-performance-\(UUID()).gif")
    try makeAnimation(at: url)
    defer { removeFixture(url) }
    let state = PerformanceChatState()
    state.messages = (0..<500).map { index in
      var message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
        text: "Message \(index) Wave", twitchEmoteURLs: ["Wave": url])
      message.segments = [.text("Message \(index) "), .emote(name: "Wave", url: url)]
      return message
    }
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let host = UIHostingController(rootView: PerformanceChatHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .seconds(3))
    let views = animatedViews(in: host.view)
    XCTAssertEqual(views.count, 500, "Keep the exact-height scrollback mounted")
    let playing = views.filter(\.isAnimating).count
    let before = cpuSeconds()
    try await Task.sleep(for: .seconds(2))
    let visible = views.filter { $0.convert($0.bounds, to: host.view).intersects(host.view.bounds) }.count
    let measurement = "mounted=\(views.count), playing=\(playing), inWindow=\(visible), cpuSecondsOverTwoSeconds=\(cpuSeconds() - before)"
    let attachment = XCTAttachment(string: measurement)
    attachment.name = "Long-history chat animation work"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertGreaterThan(playing, 0, "Visible emotes remain animated")
    XCTAssertLessThanOrEqual(playing, 24, "Offscreen history must not run display links")

    let scroll = try XCTUnwrap(scrollView(in: host.view))
    scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertGreaterThan(views.filter(\.isAnimating).count, 0)
    XCTAssertLessThanOrEqual(views.filter(\.isAnimating).count, 24)
    state.animationsActive = false
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(views.filter(\.isAnimating).count, 0, "Minimization and hidden chat suspend all emotes")
    state.animationsActive = true
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertGreaterThan(views.filter(\.isAnimating).count, 0)
    state.phase = .background
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(views.filter(\.isAnimating).count, 0, "Background PiP must not animate invisible chat")
    state.phase = .active
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertGreaterThan(views.filter(\.isAnimating).count, 0)
    XCTAssertEqual(animatedViews(in: host.view).map(ObjectIdentifier.init),
      views.map(ObjectIdentifier.init), "Visibility changes must not recreate emote views")

    scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
    for batch in 0..<30 {
      let incoming = (0..<10).map { index in
        var message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
          text: "New \(batch)-\(index) Wave", twitchEmoteURLs: ["Wave": url])
        message.segments = [.text("New \(batch)-\(index) "), .emote(name: "Wave", url: url)]
        return message
      }
      state.messages = Array(state.messages.suffix(490)) + incoming
      try await Task.sleep(for: .milliseconds(100))
    }
    try await waitUntil {
      let current = self.animatedViews(in: host.view)
      return current.count == 500 && current.filter(\.isAnimating).count > 0
        && current.filter(\.isAnimating).count <= 24
    }
    let afterChurn = animatedViews(in: host.view)
    XCTAssertEqual(afterChurn.count, 500)
    XCTAssertLessThanOrEqual(afterChurn.filter(\.isAnimating).count, 24,
      "Replacing hundreds of history rows must not accumulate running animators")
  }

  func testHiddenOrManipulatedChatDefersNewRowWorkUntilVisible() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-gate-\(UUID()).gif")
    try makeAnimation(at: url)
    defer { removeFixture(url) }
    let state = PerformanceChatGateState()
    func messages(_ range: Range<Int>) -> [ChatMessage] {
      range.map { index in
        var message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
          text: "Message \(index) Wave", twitchEmoteURLs: ["Wave": url])
        message.segments = [.text("Message \(index) "), .emote(name: "Wave", url: url)]
        return message
      }
    }
    state.service.messages = messages(0..<500)
    state.service.isConnected = true
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let host = UIHostingController(rootView: PerformanceChatGateHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    try await Task.sleep(for: .seconds(2))
    for minimized in [false, true] {
      let beforeHiding = animatedViews(in: host.view).map(ObjectIdentifier.init)
      if minimized { state.active = false } else { state.manipulating = true }
      try await Task.sleep(for: .milliseconds(300))
      let mounted = animatedViews(in: host.view)
      XCTAssertEqual(mounted.count, 500)
      XCTAssertEqual(mounted.map(ObjectIdentifier.init), beforeHiding,
        "Starting a minimize gesture must not briefly empty or rebuild the timeline")
      XCTAssertEqual(mounted.filter(\.isAnimating).count, 0)
      for batch in 0..<10 {
        state.service.messages = messages((batch * 20)..<(batch * 20 + 500))
        state.offset = CGFloat(batch)
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTAssertEqual(animatedViews(in: host.view).map(ObjectIdentifier.init), mounted.map(ObjectIdentifier.init),
        "Hidden chat and gesture-time updates must not recreate rows for incoming messages")
      state.active = true
      state.manipulating = false
      try await waitUntil {
        let current = self.animatedViews(in: host.view)
        return current.count == 500 && current.filter(\.isAnimating).count > 0
          && current.map(ObjectIdentifier.init) != mounted.map(ObjectIdentifier.init)
      }
      let resumed = animatedViews(in: host.view)
      XCTAssertEqual(resumed.count, 500)
      XCTAssertNotEqual(resumed.map(ObjectIdentifier.init), mounted.map(ObjectIdentifier.init))
      XCTAssertGreaterThan(resumed.filter(\.isAnimating).count, 0)
      XCTAssertLessThanOrEqual(resumed.filter(\.isAnimating).count, 24)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Chat rendering did not settle within five seconds")
  }

  private func removeFixture(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) }
    catch { XCTFail("Could not remove owned animation fixture: \(error)") }
  }

  private func scrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
  }

  private func animatedViews(in view: UIView) -> [SDAnimatedImageView] {
    (view as? SDAnimatedImageView).map { [$0] } ?? view.subviews.flatMap { animatedViews(in: $0) }
  }

  private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  private func makeAnimation(at url: URL) throws {
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for color in [UIColor.systemBlue, .systemGreen] {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
      }
      CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage),
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}

@MainActor
@Observable
private final class PerformanceChatState {
  var messages: [ChatMessage] = []
  var animationsActive = true
  var phase = ScenePhase.active
}

private struct PerformanceChatHarness: View {
  let state: PerformanceChatState

  var body: some View {
    MobileChatTimeline(messages: state.messages, animationsActive: state.animationsActive)
      .frame(width: 390, height: 600)
      .environment(\.themePalette, .dark)
      .environment(\.scenePhase, state.phase)
  }
}

@MainActor
@Observable
private final class PerformanceChatGateState {
  let service = ChatService()
  let composer = MobileChatComposerState()
  let scroll = MobileChatScrollState()
  let auth = TwitchAuthSession()
  var active = true
  var manipulating = false
  var offset: CGFloat = 0
}

private struct PerformanceChatGateHarness: View {
  let state: PerformanceChatGateState

  var body: some View {
    MobileChatView(service: state.service, channel: "fixture", composer: state.composer,
      scroll: state.scroll, isActive: state.active, isManipulating: state.manipulating)
      .equatable()
      .frame(width: 390, height: 600)
      .offset(y: state.offset)
      .environment(state.auth)
      .environment(\.themePalette, .dark)
      .environment(\.scenePhase, .active)
  }
}
