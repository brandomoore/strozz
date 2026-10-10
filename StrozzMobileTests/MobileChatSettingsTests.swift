import SwiftUI
import XCTest
@testable import StrozzMobile

@MainActor
final class MobileChatSettingsTests: XCTestCase {
  func testMobileDefaultsPreserveExistingChatSizes() {
    XCTAssertEqual(MobileChatAppearance.textSize, 16)
    XCTAssertEqual(MobileChatAppearance.autoEmoteSize(text: 16), 26)
    XCTAssertEqual(MobileChatAppearance.messageSpacing, 8)
    XCTAssertEqual(MobileChatAppearance.preset(text: 16, line: -1, spacing: 8, autoEmotes: true), .normal)
    XCTAssertNil(MobileChatAppearance.preset(text: 17, line: -1, spacing: 8, autoEmotes: true))
    XCTAssertNil(MobileChatAppearance.preset(text: 16, line: -1, spacing: 8, autoEmotes: false))
  }

  func testHighlightRulesMatchMentionsRepliesAndNormalizedKeywords() {
    func message(_ text: String) -> ChatMessage {
      ChatMessage(username: "Other", colorHex: nil, badgeKeys: [], text: text, twitchEmoteURLs: [:])
    }
    let words = ChatHighlightRules.keywords(from: " Giveaway, game\nGAME, , ")
    XCTAssertEqual(words, ["giveaway", "game"])
    XCTAssertTrue(ChatHighlightRules.matches(message("Hi @SAM!"), viewerLogin: "sam", viewerDisplayName: nil, keywords: []))
    XCTAssertFalse(ChatHighlightRules.matches(message("same sam_alt"), viewerLogin: "sam", viewerDisplayName: nil, keywords: []))
    XCTAssertTrue(ChatHighlightRules.matches(message("GIVEAWAY soon"), viewerLogin: nil, viewerDisplayName: nil, keywords: words))
    var reply = message("A reply without the username in its text")
    reply.replyParentLogin = "sam"
    XCTAssertTrue(ChatHighlightRules.matches(reply, viewerLogin: "SAM", viewerDisplayName: nil, keywords: []))
  }

  func testSourcePreferencesAreOptInAndDoNotRestartOrReplaceManualTargets() throws {
    let suite = "MobileChatSources.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let chat = ChatService()
    chat.channel = "example"
    defer { chat.disconnect(); defaults.removePersistentDomain(forName: suite) }
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertFalse(chat.youtubeMergeEnabled)
    XCTAssertFalse(chat.kickMergeEnabled)
    XCTAssertNil(chat.youtubeReceiveTask)
    XCTAssertNil(chat.kickReceiveTask)
    defaults.set(true, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    defaults.set(true, forKey: PersistenceKey.experimentalKickMergeEnabled)
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertEqual(chat.youtubeChannelOrURL, "@example")
    XCTAssertEqual(chat.kickChannelOrURL, "example")
    chat.youtubeChannelOrURL = "@manual"
    chat.kickChannelOrURL = "manual"
    chat.youtubeStatusMessage = "Unchanged"
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertEqual(chat.youtubeChannelOrURL, "@manual")
    XCTAssertEqual(chat.kickChannelOrURL, "manual")
    XCTAssertEqual(chat.youtubeStatusMessage, "Unchanged")
    chat.configureExperimentalYouTubeMerge(enabled: true, channelOrURL: "")
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertEqual(chat.youtubeChannelOrURL, "")
    XCTAssertEqual(chat.youtubeStatusMessage, "Enter a YouTube handle, URL, or video ID.")
    XCTAssertNil(chat.youtubeReceiveTask, "An empty manual target must not be silently replaced or repeatedly restarted")
    defaults.set(false, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    defaults.set(false, forKey: PersistenceKey.experimentalKickMergeEnabled)
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertNil(chat.youtubeReceiveTask)
    XCTAssertNil(chat.kickReceiveTask)
  }

  func testSourcePreferencesIgnoreInactiveChannels() throws {
    let suite = "MobileChatSources.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    let chat = ChatService()
    chat.channel = "another"
    MobileChatSourcePreferences.apply(to: chat, channel: "example", defaults: defaults)
    XCTAssertFalse(chat.youtubeMergeEnabled)
    XCTAssertNil(chat.youtubeReceiveTask)
  }

  func testRoundedComposerFitsPhoneTabletAndDynamicType() {
    for width in [280.0, 390, 700] {
      for size in [DynamicTypeSize.large, .accessibility3] {
        for theme in AppTheme.allCases {
          for opaque in [false, true] {
            let palette = theme.palette(systemColorScheme: .light)
            let host = UIHostingController(rootView: MobileChatComposerInput(
              text: .constant("A message that wraps naturally in the rounded composer"), sending: false,
              onSend: {}, onSettings: {}, reduceTransparency: opaque)
              .environment(\.themePalette, palette)
              .environment(\.dynamicTypeSize, size))
            let actual = host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
            XCTAssertEqual(actual.width, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(actual.height, 52)
            XCTAssertLessThan(actual.height, 300)
          }

        }
      }
    }
  }

  func testKeyboardReturnSubmitsButPastedMultilineTextAndIMECompositionDoNot() {
    var draft = "Hello"
    var submissions = 0
    let input = MobileChatTextInput(
      text: Binding(get: { draft }, set: { draft = $0 }),
      sending: false, onSend: { submissions += 1 })
    let coordinator = input.makeCoordinator()
    let view = UITextView()
    view.text = draft
    XCTAssertFalse(
      coordinator.textView(
        view, shouldChangeTextIn: NSRange(location: 5, length: 0),
        replacementText: "\n"))
    XCTAssertEqual(submissions, 1)
    XCTAssertTrue(
      coordinator.textView(
        view, shouldChangeTextIn: NSRange(location: 5, length: 0),
        replacementText: "First line\nSecond line"))
    XCTAssertEqual(submissions, 1)
    view.text = "   "
    XCTAssertFalse(
      coordinator.textView(
        view, shouldChangeTextIn: NSRange(location: 3, length: 0),
        replacementText: "\n"))
    XCTAssertEqual(submissions, 1)
    view.text = "First line\nSecond line"
    coordinator.textViewDidChange(view)
    XCTAssertEqual(draft, view.text)
    view.setMarkedText("Composing", selectedRange: NSRange(location: 9, length: 0))
    XCTAssertNotNil(view.markedTextRange)
    XCTAssertTrue(
      coordinator.textView(
        view, shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementText: "\n"))
    XCTAssertEqual(submissions, 1)
    coordinator.parent = MobileChatTextInput(
      text: .constant("Sending"), sending: true,
      onSend: { submissions += 1 })
    XCTAssertFalse(
      coordinator.textView(
        view, shouldChangeTextIn: NSRange(location: 0, length: 0),
        replacementText: "\n"))
    XCTAssertEqual(submissions, 1)
  }

  func testComposerGrowthStopsAtFourLines() {
    for width in [280.0, 390, 700] {
      let host = UIHostingController(
        rootView: MobileChatComposerInput(
          text: .constant(String(repeating: "A long draft that will need scrolling. ", count: 40)),
          sending: false, onSend: {}, onSettings: {}, reduceTransparency: true
        )
        .environment(\.dynamicTypeSize, .large))
      let actual = host.sizeThatFits(
        in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
      let expected = ceil(UIFont.systemFont(ofSize: 17).lineHeight * 4 + 20) + 8
      XCTAssertEqual(actual.height, expected, accuracy: 1)
    }
  }
}
