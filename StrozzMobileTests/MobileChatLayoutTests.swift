import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileChatLayoutTests: XCTestCase {
  func testFollowingOnlyResumesAtBottomOrAfterJump() {
    let state = MobileChatScrollState()
    state.phaseChanged(.interacting)
    state.geometryChanged(distanceFromBottom: 300, sizeChanged: false)
    state.phaseChanged(.decelerating)
    state.messagesChanged()
    XCTAssertFalse(state.followsLatest)
    state.phaseChanged(.idle)
    XCTAssertFalse(state.followsLatest)
    state.jumpToPresent()
    XCTAssertTrue(state.followsLatest)
    state.phaseChanged(.interacting)
    state.geometryChanged(distanceFromBottom: 4, sizeChanged: false)
    state.phaseChanged(.idle)
    XCTAssertTrue(state.followsLatest)
  }

  func testOversizedMobileTokensWrapWithoutChangingTVDefault() {
    let token = String(repeating: "LongUnbrokenURL", count: 12)
    for width in [180.0, 296, 356] {
      for fontSize in [16.0, 32] {
        let wrapped = UIHostingController(rootView:
          ChatFlowLayout(wrapsOversizedTokens: true) {
            Text(token).font(.system(size: fontSize))
          })
        let reference = UIHostingController(rootView:
          Text(token).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true))
        let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        let actual = wrapped.sizeThatFits(in: proposal)
        let expected = reference.sizeThatFits(in: proposal)
        XCTAssertEqual(actual.width, width, accuracy: 1)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1)
        XCTAssertGreaterThan(actual.height, fontSize * 2)
      }
    }
    XCTAssertFalse(ChatFlowLayout().wrapsOversizedTokens)
  }

  func testLiveEdgeAfterBurstsTrimmingJumpAndViewportChanges() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let state = TimelineState()
    state.messages = try messages(0..<200)
    let host = UIHostingController(rootView: TimelineHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    XCTContext.runActivity(named: "Lay out initial history") { _ in }
    await layout(host)
    let scroll = try XCTUnwrap(findScroll(in: host.view))
    assertAtBottom(scroll)
    XCTAssertEqual(scroll.adjustedContentInset.bottom, 0, accuracy: 1,
                   "Live chat must not reserve an empty footer")
    let viewport = scroll.bounds.size

    for batch in 1...5 {
      XCTContext.runActivity(named: "Rotate history batch \(batch)") { _ in }
      state.messages = try messages((batch * 40)..<(batch * 40 + 200))
      await layout(host)
      assertAtBottom(scroll)
    }
    state.scroll.phaseChanged(.interacting)
    XCTContext.runActivity(named: "Read older messages") { _ in }
    scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
    await layout(host)
    state.scroll.phaseChanged(.idle)
    XCTAssertFalse(state.scroll.followsLatest)
    XCTAssertEqual(scroll.bounds.size, viewport)
    XCTAssertEqual(scroll.adjustedContentInset.bottom, 0, accuracy: 1)
    XCTAssertLessThan(scroll.contentOffset.y, bottomOffset(scroll) - 100)
    state.messages = try messages(1000..<1200)
    await layout(host)
    XCTAssertFalse(state.scroll.followsLatest)
    state.scroll.jumpToPresent()
    XCTContext.runActivity(named: "Jump to present") { _ in }
    await layout(host)
    assertAtBottom(scroll)
    XCTAssertEqual(scroll.bounds.size, viewport)
    XCTAssertEqual(scroll.adjustedContentInset.bottom, 0, accuracy: 1)
    for size in [CGSize(width: 300, height: 240), CGSize(width: 380, height: 640),
                 CGSize(width: 700, height: 300)] {
      state.size = size
      XCTContext.runActivity(named: "Resize chat to \(size)") { _ in }
      await layout(host)
      assertAtBottom(scroll)
      XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
    }
    state.messages = try messages(2000..<2002)
    await layout(host)
    assertAtBottom(scroll)

    for index in state.messages.indices {
      state.messages[index].segments = [.text(String(repeating: "Retokenized message ", count: 60))]
    }
    await layout(host)
    assertAtBottom(scroll)
    for index in state.messages.indices { state.messages[index].segments = [.text("Short")] }
    await layout(host)
    assertAtBottom(scroll)
  }

  private func messages(_ range: Range<Int>) throws -> [ChatMessage] {
    try range.map { index in
      let text = index.isMultiple(of: 7)
        ? String(repeating: "long-unbroken-token", count: 20)
        : String(repeating: "Message \(index) ", count: index.isMultiple(of: 3) ? 12 : 2)
      return try XCTUnwrap(ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :\(text)"))
    }
  }

  private func layout(_ host: UIViewController) async {
    try? await Task.sleep(for: .milliseconds(400))
    host.view.layoutIfNeeded()
  }

  private func findScroll(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScroll(in: $0) }.first
  }

  private func bottomOffset(_ scroll: UIScrollView) -> CGFloat {
    max(-scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
  }

  private func assertAtBottom(_ scroll: UIScrollView, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(scroll.bounds.height, 0, file: file, line: line)
    XCTAssertEqual(scroll.contentOffset.y, bottomOffset(scroll), accuracy: 3, file: file, line: line)
  }
}

@MainActor
@Observable
private final class TimelineState {
  var messages: [ChatMessage] = []
  var size = CGSize(width: 356, height: 500)
  let scroll = MobileChatScrollState()
}

private struct TimelineHarness: View {
  let state: TimelineState

  var body: some View {
    MobileChatTimeline(messages: state.messages, scroll: state.scroll)
      .frame(width: state.size.width, height: state.size.height)
      .environment(\.themePalette, .light)
  }
}
