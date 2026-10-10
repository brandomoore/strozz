import XCTest
import ImageIO
import SDWebImage
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

@MainActor
final class TwitchGIFTests: XCTestCase {
    func testNativeScrollVisibilityLoadsAndPausesGIFWithoutMobileEnvironment() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-gif-\(UUID()).gif")
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(output,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [UIColor.systemTeal, .systemOrange] {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image {
                color.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            CGImageDestinationAddImage(output, try XCTUnwrap(image.cgImage),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(output))
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { XCTFail("Could not remove native GIF fixture: \(error)") }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let state = GIFAnimationPreference()
        let host = UIHostingController(rootView: GIFScrollHarness(state: state, url: url))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(descendants(SDAnimatedImageView.self, in: host.view).isEmpty)
        let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: host.view).first)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        for _ in 0..<100 {
            if descendants(SDAnimatedImageView.self, in: host.view).contains(where: \.isAnimating) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let image = try XCTUnwrap(descendants(SDAnimatedImageView.self, in: host.view).first)
        XCTAssertTrue(image.isAnimating)
        XCTAssertEqual(image.maxBufferSize, 2 * 1024 * 1024)
        let contentSize = scroll.contentSize
        state.animated = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(descendants(SDAnimatedImageView.self, in: host.view).contains(where: \.isAnimating))
        XCTAssertEqual(scroll.contentSize, contentSize)
        state.animated = true
        for _ in 0..<100 {
            if descendants(SDAnimatedImageView.self, in: host.view).contains(where: \.isAnimating) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(descendants(SDAnimatedImageView.self, in: host.view).contains(where: \.isAnimating))
        scroll.setContentOffset(.zero, animated: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(descendants(SDAnimatedImageView.self, in: host.view).contains(where: \.isAnimating))
    }

    func testUnloadedPreviewFitsNarrowChatAtEverySize() {
        for width in [100.0, 160, 250, 400] {
            for height in [72.0, 120] {
                let host = UIHostingController(rootView: ChatGIFView(name: "[A long GIF description]",
                    url: URL(fileURLWithPath: "/missing-gif.gif"), foreground: .primary,
                    height: height, animated: false)
                    .environment(\.chatAnimationsActive, false))
                let fitted = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                XCTAssertLessThanOrEqual(fitted.width, width)
                XCTAssertEqual(fitted.height, height)
            }

        }
    }

    func testNativeGIFUsesSmallCanonicalImageAndPreservesItsLabel() throws {
        let text = "[Dancing cat GIF]"
        let message = try message(text, tag: entry(text))
        let gif = try XCTUnwrap(message.gifs.first)
        XCTAssertEqual(gif.name, text)
        XCTAssertEqual(gif.range, 0..<text.unicodeScalars.count)
        XCTAssertEqual(gif.url.absoluteString, "https://media.giphy.com/media/Example123/200w.gif")
        XCTAssertEqual(message.text, text)
        XCTAssertEqual(ChatService().computeSegments(for: message), [.gif(name: text, url: gif.url)])
    }

    func testOnlyTheTaggedOccurrenceBecomesAnImage() async throws {
        let label = "[Wave GIF]"
        let messages = await ChatIngestPipeline().parseAndTokenize([line("\(label) \(label)", tag: entry(label))])
        let message = try XCTUnwrap(messages.first)
        let segments = try XCTUnwrap(message.segments)
        XCTAssertEqual(segments.filter { if case .gif = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(segments.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(),
                       " \(label)")
    }

    func testRangesUseUnicodeScalarsNotGraphemesOrUTF16() throws {
        let prefix = "👨‍👩‍👧‍👦 e\u{301} "
        let label = "[Wave GIF]"
        let message = try message(prefix + label, tag: entry(label, start: prefix.unicodeScalars.count))
        let gif = try XCTUnwrap(message.gifs.first)
        XCTAssertEqual(gif.name, label)
        let segments = ChatService().computeSegments(for: message)
        XCTAssertEqual(segments.last, .gif(name: label, url: gif.url))
        XCTAssertEqual(segments.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(), prefix)
    }

    func testMultipleGIFsAndCatalogRefreshKeepTextAndEmotesInOrder() async throws {
        let first = "[One GIF]"
        let second = "[Two GIF]"
        let text = "\(first) Wave \(second)"
        let tag = "\(entry(second, start: (first + " Wave ").unicodeScalars.count, id: "Second2")),\(entry(first))"
        let pipeline = ChatIngestPipeline()
        let parsed = await pipeline.parseAndTokenize([line(text, tag: tag)])
        let message = try XCTUnwrap(parsed.first)
        let emote = try XCTUnwrap(URL(string: "https://example.invalid/emote"))
        await pipeline.updateSnapshot(ChatCatalogSnapshot(globalEmoteURLs: ["Wave": emote], cheermotes: []))
        let changed = await pipeline.retokenize([message])
        let segments = try XCTUnwrap(changed.first?.segments)
        XCTAssertEqual(segments, [
            .gif(name: first, url: message.gifs[0].url), .text(" "),
            .emote(name: "Wave", url: emote), .text(" "),
            .gif(name: second, url: message.gifs[1].url),
        ])
        let service = ChatService()
        XCTAssertEqual(service.computeSegments(for: message), message.segments)
    }

    func testMalformedMetadataRetainsTextInsteadOfLoadingArbitraryURLs() throws {
        let text = "[GIF]"
        for tag in [
            "missing", "0-4||https://example.invalid/a.gif",
            "0-4|../escape|https://example.invalid/a.gif",
            "0-4|bad%2Fid|https://example.invalid/a.gif",
            "-1-4|Valid1|https://example.invalid/a.gif",
            "3-2|Valid1|https://example.invalid/a.gif",
            "0-500|Valid1|https://example.invalid/a.gif",
            "0-\(Int.max)|Valid1|https://example.invalid/a.gif",
            "0-4|Valid1|", "0-4|\(String(repeating: "a", count: 129))|url",
        ] {
            let message = try message(text, tag: tag)
            XCTAssertTrue(message.gifs.isEmpty, tag)
            XCTAssertEqual(message.text, text)
        }
        let valid = try message(text, tag: entry(text, url: "https://example.invalid/tracking.gif"))
        XCTAssertEqual(valid.gifs.first?.url.host, "media.giphy.com")
        XCTAssertNil(valid.gifs.first?.url.query)
    }

    func testOverlappingRangesDoNotDuplicateImages() throws {
        let text = "[GIF]"
        let message = try message(text, tag: "\(entry(text)),\(entry(text))")
        XCTAssertEqual(message.gifs.count, 1)
        XCTAssertEqual(ChatService().computeSegments(for: message).count, 1)
    }

    func testActionOffsetsAndUserNoticeAttachments() throws {
        let label = "[Wave GIF]"
        let action = try message("\u{1}ACTION \(label)\u{1}", tag: entry(label, start: 8))
        XCTAssertTrue(action.isAction)
        XCTAssertEqual(action.gifs.first?.name, label)
        XCTAssertEqual(action.gifs.first?.range, 0..<label.unicodeScalars.count)
        let notice = try XCTUnwrap(ChatMessage(highlightedUSERNOTICE:
            "@msg-id=resub;system-msg=Subscribed;gifs=\(entry(label)) :viewer!v@h USERNOTICE #fixture :\(label)"))
        XCTAssertEqual(notice.gifs.first?.name, label)
    }

    func testOrdinaryGIFLinksAreNotAutomaticallyFetched() throws {
        let message = try XCTUnwrap(ChatMessage(ircLine:
            ":viewer!v@h PRIVMSG #fixture :https://example.invalid/image.gif"))
        XCTAssertTrue(message.gifs.isEmpty)
        XCTAssertEqual(ChatService().computeSegments(for: message),
                       [.text("https://example.invalid/image.gif")])
    }

    private func entry(_ label: String, start: Int = 0, id: String = "Example123",
                       url: String = "https://media.giphy.com/media/Example123/giphy.gif?tracking=1") -> String {
        "\(start)-\(start + label.unicodeScalars.count - 1)|\(id)|\(url)"
    }

    private func line(_ text: String, tag: String) -> String {
        "@gifs=\(tag);display-name=Viewer;emotes= :viewer!v@h PRIVMSG #fixture :\(text)"
    }

    private func message(_ text: String, tag: String) throws -> ChatMessage {
        try XCTUnwrap(ChatMessage(ircLine: line(text, tag: tag)))
    }

    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
}

@MainActor
@Observable
private final class GIFAnimationPreference {
    var animated = true
}

private struct GIFScrollHarness: View {
    let state: GIFAnimationPreference
    let url: URL

    var body: some View {
        ScrollView {
            VStack {
                Color.clear.frame(height: 1000)
                ChatGIFView(name: "[Fixture GIF]", url: url, foreground: .primary,
                            height: 100, animated: state.animated)
            }
        }
        .frame(width: 400, height: 300)
        .environment(\.scenePhase, .active)
    }
}
