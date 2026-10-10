import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileEmoteTests: XCTestCase {
  func testNativeGIFPreviewIdentifiesGiphyWithoutUpsizingTheDownload() throws {
    let url = try XCTUnwrap(URL(string: "https://media.giphy.com/media/Example123/200w.gif"))
    let gif = MobileChatEmote(name: "[Wave GIF]", url: url)
    XCTAssertTrue(gif.isGIF)
    XCTAssertEqual(gif.provider, "GIPHY")
    XCTAssertEqual(gif.previewURL, url)
    XCTAssertFalse(MobileChatEmote(name: "Emote",
      url: try XCTUnwrap(URL(string: "https://files.kick.com/emote/1/fullsize"))).isGIF)
  }

  func testPreviewUsesLargerKnownProviderImagesWithoutLosingURLComponents() throws {
    for (source, preview, provider) in [
      ("https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/2.0",
       "https://static-cdn.jtvnw.net/emoticons/v2/25/default/dark/3.0", "Twitch"),
      ("https://cdn.7tv.app/emote/example/2x.webp?test=value#fragment",
       "https://cdn.7tv.app/emote/example/4x.webp?test=value#fragment", "7TV"),
      ("https://cdn.betterttv.net/emote/example/2x",
       "https://cdn.betterttv.net/emote/example/3x", "BetterTTV"),
      ("https://cdn.frankerfacez.com/emote/123/4",
       "https://cdn.frankerfacez.com/emote/123/4", "FrankerFaceZ"),
    ] {
      let emote = MobileChatEmote(name: "Example", url: try XCTUnwrap(URL(string: source)))
      XCTAssertEqual(emote.previewURL.absoluteString, preview)
      XCTAssertEqual(emote.provider, provider)
    }
  }

  func testUnknownURLsAndFormatsAreNotRewritten() throws {
    for source in [
      "https://cdn.7tv.app.example/emote/id/2x.webp",
      "https://cdn.7tv.app/emote/id/unrecognized.png",
      "https://static-cdn.jtvnw.net/unrelated/2.0",
      "https://example.test/emote/2x",
      "file:///tmp/emote.png",
    ] {
      let url = try XCTUnwrap(URL(string: source))
      XCTAssertEqual(MobileChatEmote(name: "Example", url: url).previewURL, url)
    }
    XCTAssertNil(MobileChatEmote(name: "Unknown", url: URL(string: "https://example.test/image")!).provider)
  }

  func testSameNameFromDifferentProvidersKeepsDistinctSelectionIdentity() throws {
    let first = MobileChatEmote(name: "Wave", url: try XCTUnwrap(URL(string: "https://cdn.7tv.app/emote/a/2x.webp")))
    let second = MobileChatEmote(name: "Wave", url: try XCTUnwrap(URL(string: "https://cdn.betterttv.net/emote/b/2x")))
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.id, MobileChatEmote(name: first.name, url: first.url).id)
  }

  func testInlineEmoteButtonsPreserveMessageLayoutAndNoninteractiveDefault() {
    var message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [], text: "A Kappa message",
      twitchEmoteURLs: [:])
    message.segments = [.text("A "), .emote(name: "Kappa", url: URL(fileURLWithPath: "/missing-emote.png")),
                        .text(" message")]
    for width in [180.0, 356, 700] {
      for size in [16.0, 32] {
        let line = RichChatLineView(message: message, nameColor: .primary,
          globalEmoteURLs: [:], badgeURLs: [:], textSize: size, emoteSize: size + 10,
          animatedEmotes: false, bodyColorOverride: .primary, wrapsOversizedTokens: true)
        XCTAssertNil(line.onInspectEmote)
        var interactive = line
        interactive.onInspectEmote = { _, _ in }
        let original = UIHostingController(rootView: line)
        let buttons = UIHostingController(rootView: interactive)
        let proposal = CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
        XCTAssertEqual(original.sizeThatFits(in: proposal).height, buttons.sizeThatFits(in: proposal).height, accuracy: 1)
      }
    }
  }
}
