import SwiftUI
import XCTest

@testable import Strozz

@MainActor
final class ChatScrollRenderingTests: XCTestCase {
  func testLiveEdgeSurvivesBufferRotationAndResumingFromOldSnapshot() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let state = ChatRenderState()
    state.messages = try messages(0..<200)
    let host = UIHostingController(rootView: ChatRenderHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    await layout(host)
    var scroll = try XCTUnwrap(findScrollView(in: host.view))
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)

    for batch in 1...12 {
      state.messages.removeFirst(20)
      state.messages.append(contentsOf: try messages((200 + batch * 20)..<(220 + batch * 20)))
      await layout(host)
      assertAtLiveEdge(scroll)
      try assertMessagesRendered(in: scroll, host: host)
    }

    state.autoScroll = false
    await layout(host)
    scroll = try XCTUnwrap(findScrollView(in: host.view))
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
    state.scrollTarget = ChatScrollTarget(id: state.messages[80].id, anchor: .bottom, nonce: 1, animated: false)
    await layout(host)
    XCTAssertLessThan(scroll.contentOffset.y, bottomOffset(scroll) - 100)
    try assertMessagesRendered(in: scroll, host: host)

    // A busy channel has trimmed every frozen row by the time reading ends.
    state.messages = try messages(1_000..<1_200)
    state.scrollTarget = nil
    state.autoScroll = true
    await layout(host)
    scroll = try XCTUnwrap(findScrollView(in: host.view))
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)

    state.width = 680
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
    state.messages = try messages(2_000..<2_003)
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
  }

  func testPassiveChatStaysVisibleThroughVariableHeightBurstsAndAdaptiveTrimming() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let state = ChatRenderState()
    let host = UIHostingController(rootView: ChatRenderHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    await layout(host)
    let scroll = try XCTUnwrap(findScrollView(in: host.view))
    var nextMessage = 0
    for tick in 0..<180 {
      let count = tick < 60 ? 1 : (tick < 120 ? 24 : 8)
      let incoming = try (nextMessage..<(nextMessage + count)).map { index in
        let text = String(repeating: "Visible message \(index) ", count: tick.isMultiple(of: 7) ? 28 : 1)
        return try XCTUnwrap(ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :\(text)"))
      }
      nextMessage += count
      let cap = tick < 60 ? 500 : (tick < 120 ? 200 : 400)
      state.messages = Array((state.messages + incoming).suffix(cap))
      try await Task.sleep(for: .milliseconds(35))
      host.view.layoutIfNeeded()
      if tick.isMultiple(of: 6) {
        await layout(host)
        assertAtLiveEdge(scroll)
        try assertMessagesRendered(in: scroll, host: host)
      }
    }
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
  }

  func testLiveTailSizingCoversViewportWithoutRenderingWholeHistory() {
    for textSize in [16.0, 26, 44] {
      let view = ChatView(channel: "example", messages: [], textSize: textSize)
      for height in [0.0, 400, 600, 1_080, 2_160] {
        let limit = view.liveMessageLimit(viewportHeight: height)
        XCTAssertGreaterThanOrEqual(CGFloat(limit) * textSize, height)
        XCTAssertLessThanOrEqual(limit, Int(ceil(height / textSize)) + 2)
      }
    }
  }

  func testLiveTailRetainsFullHistoryAcrossPauseResizeAndLayoutChanges() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let state = ChatRenderState()
    state.messages = try messages(0..<500)
    let host = UIHostingController(rootView: ChatRenderHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    await layout(host)
    var scroll = try XCTUnwrap(findScrollView(in: host.view))
    let liveHeight = scroll.contentSize.height
    XCTAssertEqual(state.messages.count, 500)
    state.autoScroll = false
    await layout(host)
    scroll = try XCTUnwrap(findScrollView(in: host.view))
    XCTAssertGreaterThan(scroll.contentSize.height, liveHeight * 5)
    assertAtLiveEdge(scroll)
    state.scrollTarget = ChatScrollTarget(id: state.messages[5].id, anchor: .top, nonce: 1, animated: false)
    await layout(host)
    XCTAssertLessThan(scroll.contentOffset.y, bottomOffset(scroll) - 1_000)
    try assertMessagesRendered(in: scroll, host: host)
    state.autoScroll = true
    state.scrollTarget = nil
    await layout(host)
    scroll = try XCTUnwrap(findScrollView(in: host.view))
    assertAtLiveEdge(scroll)
    XCTAssertLessThan(scroll.contentSize.height, liveHeight * 1.1)
    for mode in ChatLayoutMode.allCases {
      state.layoutMode = mode
      state.width = 300
      state.textSize = 16
      state.height = 900
      await layout(host)
      // A layout switch may replace the native scroll view.
      let currentScroll = try XCTUnwrap(findScrollView(in: host.view))
      assertAtLiveEdge(currentScroll)
      try assertMessagesRendered(in: currentScroll, host: host)
      state.width = 820
      state.textSize = 44
      state.height = 400
      await layout(host)
      assertAtLiveEdge(currentScroll)
      try assertMessagesRendered(in: currentScroll, host: host)
    }
  }

  func testChatStaysVisibleWhenEmotesAndHighlightsChangeRowSizes() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let emotes = try (1...4).map { width in
      let url = directory.appendingPathComponent("emote-\(width).png")
      let image = UIGraphicsImageRenderer(size: CGSize(width: width * 40, height: 40)).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width * 40, height: 40))
      }
      try XCTUnwrap(image.pngData()).write(to: url)
      return url
    }
    let state = ChatRenderState()
    state.messages = try messages(0..<500)
    let host = UIHostingController(rootView: ChatRenderHarness(state: state))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
    }
    await layout(host)
    let scroll = try XCTUnwrap(findScrollView(in: host.view))
    for batch in 0..<36 {
      var updated = Array(state.messages.dropFirst(12))
      let incoming = try (0..<12).map { index in
        let tags = index.isMultiple(of: 3) ? "@first-msg=1 " : ""
        var message = try XCTUnwrap(ChatMessage(
          ircLine: "\(tags):viewer!viewer@host PRIVMSG #example :Visible new message \(batch)-\(index)"))
        message.segments = [.text("Visible emotes ")] + (0..<(index + 1)).map {
          .emote(name: "fixture", url: emotes[$0 % emotes.count])
        }
        return message
      }
      updated.append(contentsOf: incoming)
      state.messages = updated
      await layout(host)
      assertAtLiveEdge(scroll)
      try assertMessagesRendered(in: scroll, host: host)
      if batch.isMultiple(of: 4) {
        // Catalog tokenization changes existing rows without changing their IDs.
        for index in state.messages.indices.suffix(18) {
          state.messages[index].segments = Array(repeating: .text("Retokenized "), count: 18)
        }
        await layout(host)
        assertAtLiveEdge(scroll)
        try assertMessagesRendered(in: scroll, host: host)
      }
    }
    // A loaded catalog can also shrink rows (text tokens become short emotes).
    // The live edge must remain real rendered content, not a stale lazy estimate.
    for index in state.messages.indices {
      state.messages[index].segments = [.text("Short")]
    }
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
    for index in state.messages.indices {
      state.messages[index].segments = Array(repeating: .text("Tall text "), count: 100)
    }
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
    state.messages = Array(state.messages.suffix(200))
    await layout(host)
    assertAtLiveEdge(scroll)
    try assertMessagesRendered(in: scroll, host: host)
  }

  private func assertMessagesRendered(
    in scroll: UIScrollView, host: UIViewController,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: host.view.bounds.size, format: format).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let rect = scroll.convert(scroll.bounds, to: host.view).intersection(host.view.bounds)
    let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect), file: file, line: line)
    var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
        bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ), file: file, line: line)
      context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    }
    let brightPixels = stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, offset in
      count + (pixels[offset] > 160 && pixels[offset + 1] > 160 && pixels[offset + 2] > 160 ? 1 : 0)
    }
    if brightPixels <= 200 {
      let attachment = XCTAttachment(image: image)
      attachment.name = "Blank synthetic chat, offset \(scroll.contentOffset.y), height \(scroll.contentSize.height)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertGreaterThan(brightPixels, 200, "Chat has rows but renders no visible text", file: file, line: line)
  }

  private func messages(_ range: Range<Int>) throws -> [ChatMessage] {
    try range.map { index in
      let text = String(repeating: "Message \(index) ", count: index.isMultiple(of: 3) ? 10 : 2)
      return try XCTUnwrap(ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :\(text)"))
    }
  }

  private func layout(_ host: UIViewController) async {
    try? await Task.sleep(for: .milliseconds(250))
    host.view.layoutIfNeeded()
  }

  private func findScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
  }

  private func bottomOffset(_ scroll: UIScrollView) -> CGFloat {
    max(-scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
  }

  private func assertAtLiveEdge(_ scroll: UIScrollView, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThan(scroll.bounds.height, 0, file: file, line: line)
    XCTAssertEqual(scroll.contentOffset.y, bottomOffset(scroll), accuracy: 3, file: file, line: line)
  }
}

@MainActor
@Observable
private final class ChatRenderState {
  var messages: [ChatMessage] = []
  var autoScroll = true
  var scrollTarget: ChatScrollTarget?
  var width: CGFloat = 460
  var height: CGFloat = 600
  var textSize: CGFloat = ChatAppearance.defaultTextSize
  var layoutMode: ChatLayoutMode = .side
}

private struct ChatRenderHarness: View {
  let state: ChatRenderState

  var body: some View {
    ChatView(
      channel: "example", messages: state.messages, textSize: state.textSize, isConnected: true,
      useGlassBackground: state.layoutMode == .glass,
      useLighterOverlayBackground: state.layoutMode == .overlay,
      autoScroll: state.autoScroll, scrollTarget: state.scrollTarget
    )
    .environment(\.themePalette, .dark)
    .environment(\.colorScheme, .dark)
    .modifier(GlassChatPaneStyle(enabled: state.layoutMode == .glass))
    .frame(width: state.width, height: state.height)
  }
}
