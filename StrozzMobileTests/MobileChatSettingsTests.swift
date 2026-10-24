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

  func testThreePlatformViewerReadoutsFitNarrowAndLargeTextLayouts() {
    let counts: [PlatformViewerCount] = [.init(platform: .twitch, count: 12345),
      .init(platform: .kick, count: 6789), .init(platform: .youtube, count: 2345)]
    for width in [280.0, 390, 700] {
      for size in [DynamicTypeSize.large, .accessibility3] {
        for theme in AppTheme.allCases {
          let palette = theme.palette(systemColorScheme: .light)
          let host = UIHostingController(rootView: MobileStreamReadouts(state: .paused,
            startedAt: nil, viewerCount: nil, showDuration: false, viewerCounts: counts, onGoLive: {})
            .environment(\.themePalette, palette)
            .environment(\.dynamicTypeSize, size))
          let actual = host.sizeThatFits(in: CGSize(width: width, height: 1000))
          XCTAssertLessThanOrEqual(actual.width, width + 1)
          XCTAssertGreaterThan(actual.height, 20)
          XCTAssertLessThan(actual.height, 260)
        }
      }
    }
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

  func testSourcePreferencesNeverGuessAccountsAndPreserveLinkedTargets() throws {
    let suite = "MobileChatSources.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let creator = CreatorLiveSession(resolve: { CreatorLiveSources(root: $0) },
      loadTwitch: { _ in .unknown }, defaults: nil)
    let chat = creator.chat
    defer { creator.stop(); defaults.removePersistentDomain(forName: suite) }
    creator.start(.init(platform: .twitch, channel: "example"))
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertFalse(chat.youtubeMergeEnabled)
    XCTAssertFalse(chat.kickMergeEnabled)
    XCTAssertNil(chat.youtubeReceiveTask)
    XCTAssertNil(chat.kickReceiveTask)
    defaults.set(true, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    defaults.set(true, forKey: PersistenceKey.experimentalKickMergeEnabled)
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertFalse(chat.youtubeMergeEnabled)
    XCTAssertFalse(chat.kickMergeEnabled)
    XCTAssertEqual(chat.youtubeChannelOrURL, "")
    XCTAssertEqual(chat.kickChannelOrURL, "")
    creator.updateLinks([.init(platform: .twitch, channel: "example"),
      .init(platform: .youtube, channel: "@manual"), .init(platform: .kick, channel: "manual")])
    chat.youtubeStatusMessage = "Unchanged"
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertEqual(chat.youtubeChannelOrURL, "@manual")
    XCTAssertEqual(chat.kickChannelOrURL, "manual")
    XCTAssertEqual(chat.youtubeStatusMessage, "Unchanged")
    creator.selectVideo(.init(platform: .kick, channel: "manual"))
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertEqual(chat.channel, "example")
    XCTAssertEqual(chat.youtubeStatusMessage, "Unchanged")
    defaults.set(false, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    defaults.set(false, forKey: PersistenceKey.experimentalKickMergeEnabled)
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertNil(chat.youtubeReceiveTask)
    XCTAssertNil(chat.kickReceiveTask)
  }

  func testSourcePreferencesCannotStartAnInactiveCreator() throws {
    let suite = "MobileChatSources.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: PersistenceKey.experimentalYouTubeMergeEnabled)
    let creator = CreatorLiveSession(defaults: nil)
    defer { creator.stop() }
    MobileChatSourcePreferences.apply(to: creator, defaults: defaults)
    XCTAssertFalse(creator.chat.youtubeMergeEnabled)
    XCTAssertNil(creator.chat.youtubeReceiveTask)
  }

  func testRoundedComposerFitsPhoneTabletAndDynamicType() {
    for width in [280.0, 390, 700] {
      for size in [DynamicTypeSize.large, .accessibility3] {
        for theme in AppTheme.allCases {
          for opaque in [false, true] {
            let palette = theme.palette(systemColorScheme: .light)
            let host = UIHostingController(rootView: MobileChatComposerInput(
              text: .constant("A message that wraps naturally in the rounded composer"), sending: false,
              onSend: {}, onSettings: {}, reduceTransparency: opaque, onEmotes: {})
              .environment(\.themePalette, palette)
              .environment(\.dynamicTypeSize, size))
            let actual = host.sizeThatFits(in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
            XCTAssertEqual(actual.width, width, accuracy: 1)
            XCTAssertGreaterThanOrEqual(actual.height, 44)
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
          sending: false, onSend: {}, onSettings: {}, reduceTransparency: true, onEmotes: {}
        )
        .environment(\.dynamicTypeSize, .large))
      let actual = host.sizeThatFits(
        in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height))
      let expected = ceil(UIFont.systemFont(ofSize: 17).lineHeight * 4 + 20)
      XCTAssertEqual(actual.height, expected, accuracy: 1)
    }
  }
}
