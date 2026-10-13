import SDWebImage
import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileEmoteMenuTests: XCTestCase {
  func testCopyWritesTheExactAliasNotTheImageURL() throws {
    let name = UIPasteboard.Name("StrozzEmoteTest-\(UUID())")
    let pasteboard = try XCTUnwrap(UIPasteboard(name: name, create: true))
    defer { UIPasteboard.remove(withName: name) }
    let emote = MobileChatEmote(name: "xdd", url: URL(string: "https://cdn.7tv.app/emote/xdd666/2x.webp")!)
    MobileEmoteClipboard.copy(emote, to: pasteboard)
    XCTAssertEqual(pasteboard.string, "xdd")
    XCTAssertNil(pasteboard.image)
    XCTAssertEqual(pasteboard.numberOfItems, 1)
  }

  func testMenuLoadsAndAnimatesOnlyViewportThumbnails() async throws {
    let frames = [UIColor.systemGreen, .systemBlue].map { color in
      SDImageFrame(image: UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image {
        color.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      }, duration: 0.1)
    }
    let image = try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames))
    let data = try XCTUnwrap(SDImageGIFCoder.shared.encodedData(with: image, format: .GIF, options: nil))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID()).gif")
    try data.write(to: url)
    defer {
      do { try FileManager.default.removeItem(at: url) }
      catch { XCTFail("Could not remove owned emote fixture: \(error)") }
    }
    let suite = "EmoteMenu-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: PersistenceKey.chatAnimatedEmotes)
    defer { defaults.removePersistentDomain(forName: suite) }
    let urls = Dictionary(uniqueKeysWithValues: (0..<1000).map { ("Emote\($0)", url) })
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previous = scene.keyWindow
    let menu = MobileEmoteMenu(channel: "fixture", urls: urls,
      isLoading: false, needsRetry: false, onRetry: {})
      .frame(width: 390, height: 600).defaultAppStorage(defaults)
    let host = UIHostingController(rootView: menu.environment(\.scenePhase, .active))
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
      previous?.makeKey()
    }
    host.view.layoutIfNeeded()
    for _ in 0..<100 {
      if imageViews(in: host.view).contains(where: \.isAnimating) { break }
      try await Task.sleep(for: .milliseconds(30))
    }
    let views = imageViews(in: host.view)
    XCTAssertGreaterThan(views.filter(\.isAnimating).count, 0)
    XCTAssertLessThanOrEqual(views.count, 32, "Do not request the entire provider catalog")
    host.rootView = menu.environment(\.scenePhase, .background)
    for _ in 0..<100 {
      if views.allSatisfy({ !$0.isAnimating }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(views.allSatisfy { !$0.isAnimating })
  }

  private func imageViews(in view: UIView) -> [SDAnimatedImageView] {
    (view as? SDAnimatedImageView).map { [$0] } ?? view.subviews.flatMap { imageViews(in: $0) }
  }

  func testCatalogFiltersProvidersAndSearchWithoutChangingChannelAliases() {
    let urls = [
      "xdd": URL(string: "https://cdn.7tv.app/emote/xdd666/2x.webp")!,
      "CAUGHT": URL(string: "https://cdn.7tv.app/emote/caught/2x.webp")!,
      "Kappa": URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/2.0")!,
      "FeelsGoodMan": URL(string: "https://cdn.betterttv.net/emote/f/2x")!,
      "FrankerZ": URL(string: "https://cdn.frankerfacez.com/emote/1/4")!,
    ]
    let emotes = MobileEmoteCatalog.emotes(from: urls)
    XCTAssertEqual(emotes.map(\.name), ["CAUGHT", "FeelsGoodMan", "FrankerZ", "Kappa", "xdd"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: .sevenTV, search: "").map(\.name), ["CAUGHT", "xdd"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: .sevenTV, search: "  XDD \n").map(\.name), ["xdd"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: nil, search: "good").map(\.name), ["FeelsGoodMan"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: .twitch, search: "").map(\.name), ["Kappa"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: .ffz, search: "").map(\.name), ["FrankerZ"])
    XCTAssertEqual(MobileEmoteCatalog.filter(emotes, provider: .bttv, search: "").map(\.name), ["FeelsGoodMan"])
    XCTAssertTrue(MobileEmoteCatalog.filter(emotes, provider: .twitch, search: "xdd").isEmpty)
    XCTAssertEqual(MobileEmoteCatalog.emotes(from: urls).map(\.id), emotes.map(\.id))
  }

  func testInsertEmotesAtCursorOrSelectionWithWhitespaceAndUnicode() {
    for (draft, selection, expected) in [
      ("", nil, "xdd "),
      ("Hello", nil, "Hello xdd "),
      ("Hello ", nil, "Hello xdd "),
      ("Hello world", NSRange(location: 6, length: 5), "Hello xdd "),
      ("Hello world", NSRange(location: 5, length: 0), "Hello xdd world"),
      ("HelloWorld", NSRange(location: 5, length: 0), "Hello xdd World"),
      ("First\n", nil, "First\nxdd "),
      ("👨‍👩‍👧‍👦 hi", NSRange(location: 11, length: 0), "👨‍👩‍👧‍👦 xdd hi"),
      ("Short", NSRange(location: 100, length: 0), "Short xdd "),
    ] as [(String, NSRange?, String)] {
      let state = MobileChatComposerState()
      state.text = draft
      state.selection = selection
      XCTAssertTrue(state.insertEmote("xdd"))
      XCTAssertEqual(state.text, expected)
      XCTAssertNotNil(state.selection.flatMap { Range($0, in: state.text) })
    }
    let state = MobileChatComposerState()
    XCTAssertTrue(state.insertEmote("xdd"))
    XCTAssertTrue(state.insertEmote("CAUGHT"))
    XCTAssertEqual(state.text, "xdd CAUGHT ")
    XCTAssertEqual(state.selection, NSRange(location: 11, length: 0))
  }

  func testInsertionRejectsOversizedMessagesAndInFlightSends() async {
    let state = MobileChatComposerState()
    state.text = String(repeating: "a", count: 496)
    XCTAssertFalse(state.insertEmote("xdd"))
    XCTAssertEqual(state.text.count, 496)
    XCTAssertNotNil(state.errorMessage)
    state.text = String(repeating: "a", count: 495)
    XCTAssertTrue(state.insertEmote("xdd"))
    XCTAssertEqual(state.text.count, 500)
    XCTAssertNil(state.errorMessage)
    await state.send { text in
      XCTAssertFalse(state.insertEmote("CAUGHT"))
      XCTAssertEqual(state.text, text)
    }
    XCTAssertEqual(state.text, "")
    XCTAssertNil(state.selection)
  }

  func testTextInputTracksSelectionWithoutProgrammaticUpdateFeedback() {
    let state = MobileChatComposerState()
    state.text = "Hello world"
    let input = MobileChatTextInput(text: Binding(get: { state.text }, set: { state.text = $0 }),
      sending: false, onSend: {},
      selection: Binding(get: { state.selection }, set: { state.selection = $0 }))
    let coordinator = input.makeCoordinator()
    let view = UITextView()
    view.text = state.text
    view.selectedRange = NSRange(location: 6, length: 5)
    coordinator.textViewDidChangeSelection(view)
    XCTAssertEqual(state.selection, view.selectedRange)
    coordinator.updating = true
    view.selectedRange = NSRange(location: 0, length: 0)
    coordinator.textViewDidChangeSelection(view)
    XCTAssertEqual(state.selection, NSRange(location: 6, length: 5))
    coordinator.updating = false
    XCTAssertTrue(state.insertEmote("CAUGHT"))
    XCTAssertEqual(state.text, "Hello CAUGHT ")
  }

  func testEmoteButtonKeepsComposerCompactAcrossThemesAndWidths() {
    for theme in AppTheme.allCases {
      for opaque in [false, true] {
        for width in [250.0, 320, 700] {
          let host = UIHostingController(rootView: MobileChatComposerInput(
            text: .constant("Hi"), sending: false, onSend: {}, onSettings: {},
            reduceTransparency: opaque, onEmotes: {})
            .environment(\.themePalette, theme.palette(systemColorScheme: .light))
            .environment(\.dynamicTypeSize, .large))
          let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
          XCTAssertEqual(size.width, width, accuracy: 1)
          XCTAssertEqual(size.height, 44, accuracy: 0.5)
        }
      }
    }
  }
}
