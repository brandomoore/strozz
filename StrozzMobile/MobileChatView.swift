import SwiftUI

struct MobileChatView: View, Equatable {
  let service: ChatService
  let channel: String
  let composer: MobileChatComposerState
  let scroll: MobileChatScrollState
  var rewards: MobileChatRewardsSummary? = nil
  var isActive = true
  var isManipulating = false
  @Environment(\.themePalette) private var palette
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync: TwitchAccountSync?
  @Environment(\.scenePhase) private var scenePhase
  @State private var showAccount = false
  @State private var showSettings = false
  @State private var pausedMessages: [ChatMessage]?

  private var updatesActive: Bool { isActive && !isManipulating && scenePhase == .active }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.service === rhs.service && lhs.channel == rhs.channel && lhs.composer === rhs.composer
      && lhs.scroll === rhs.scroll && lhs.rewards == rhs.rewards
      && lhs.isActive == rhs.isActive && lhs.isManipulating == rhs.isManipulating
  }

  var body: some View {
    VStack(spacing: 0) {
      if !service.isConnected {
        Text("Connecting...")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      MobileChatTimeline(messages: updatesActive ? service.messages : (pausedMessages ?? service.messages), emoteURLs: service.emoteURLs,
                         badgeURLs: service.badgeURLs, cheermotes: service.cheermotes,
                         viewerLogin: auth.userLogin, viewerDisplayName: auth.userDisplayName, scroll: scroll,
                         animationsActive: isActive && !isManipulating)
      Divider()
      if auth.isAuthenticated, sync?.isRestoringAccount != true {
        MobileChatComposer(channel: channel, onSettings: { showSettings = true }, rewards: rewards, composer: composer)
      } else {
        HStack {
          if let rewards { MobileChatRewardsButton(summary: rewards) }
          if sync?.isRestoringAccount == true {
            TwitchAccountLoadingView()
          } else {
            Button("Sign in to chat") { showAccount = true }
          }
          Spacer()
          Button { showSettings = true } label: {
            Icon(glyph: .dots, size: 22).frame(width: 44, height: 44)
          }
          .accessibilityLabel("Chat settings")
          .accessibilityIdentifier("mobile-chat-settings")
        }
        .padding(.leading, rewards == nil ? 12 : 8)
        .padding(.trailing, 12)
      }
    }
    .accessibilityIdentifier("mobile-chat-panel")
    .background(palette.chatSideSurface)
    .onChange(of: updatesActive, initial: true) { _, active in
      pausedMessages = active ? nil : service.messages
    }
    .sheet(isPresented: $showAccount) {
      NavigationStack {
        MobileAccountView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAccount = false } } }
      }
    }
    .sheet(isPresented: $showSettings) {
      NavigationStack {
        MobileChatSettingsView(channel: channel, service: service)
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
      }
      .environment(\.themePalette, palette)
    }
  }
}

@MainActor
@Observable
final class MobileChatScrollState {
  var position = ScrollPosition(edge: .bottom)
  private(set) var followsLatest = true
  private var isUserScrolling = false
  private var isAtBottom = true

  func phaseChanged(_ phase: ScrollPhase) {
    if phase == .interacting {
      isUserScrolling = true
      followsLatest = false
    } else if phase == .idle && isUserScrolling {
      isUserScrolling = false
      followsLatest = isAtBottom
    }
  }

  func geometryChanged(distanceFromBottom: CGFloat, sizeChanged: Bool) {
    isAtBottom = distanceFromBottom <= 8
    if sizeChanged && !isAtBottom && followsLatest && !isUserScrolling { jumpToPresent() }
  }

  func messagesChanged() {
    if followsLatest && !isUserScrolling { position.scrollTo(edge: .bottom) }
  }

  func jumpToPresent() {
    isUserScrolling = false
    followsLatest = true
    position.scrollTo(edge: .bottom)
  }
}

struct MobileChatTimeline: View {
  let messages: [ChatMessage]
  var emoteURLs: [String: URL] = [:]
  var badgeURLs: [String: URL] = [:]
  var cheermotes: [Cheermote] = []
  var viewerLogin: String? = nil
  var viewerDisplayName: String? = nil
  @State var scroll = MobileChatScrollState()
  var animationsActive = true
  @State private var inspectedEmote: MobileChatEmote?
  @State private var viewportHeight: CGFloat = 0
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.scenePhase) private var scenePhase
  @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1
  @AppStorage(PersistenceKey.chatTextSizeValue) private var textSize = MobileChatAppearance.textSize
  @AppStorage(PersistenceKey.chatEmoteAuto) private var emoteAuto = true
  @AppStorage(PersistenceKey.chatEmoteSizeValue) private var emoteSize = MobileChatAppearance.emoteSize
  @AppStorage(PersistenceKey.chatLineHeightValue) private var lineHeight = Double(ChatAppearance.defaultLineHeight)
  @AppStorage(PersistenceKey.chatLetterSpacingValue) private var letterSpacing = 0.0
  @AppStorage(PersistenceKey.chatMessageSpacingValue) private var messageSpacing = MobileChatAppearance.messageSpacing
  @AppStorage(PersistenceKey.chatFontStyle) private var fontStyle = ChatFontStyle.standard.rawValue
  @AppStorage(PersistenceKey.chatAnimatedEmotes) private var animatedEmotes = true
  @AppStorage(PersistenceKey.chatShowBadges) private var showBadges = true
  @AppStorage(PersistenceKey.chatShowPlatformBadges) private var showPlatforms = true
  @AppStorage(PersistenceKey.chatHighlightMentionsEnabled) private var highlights = true
  @AppStorage(PersistenceKey.chatHighlightKeywords) private var keywords = ""

  private struct Geometry: Equatable {
    let contentSize: CGSize
    let viewportSize: CGSize
    let bottomInset: CGFloat
    let distanceFromBottom: CGFloat
  }

  var body: some View {
    @Bindable var scroll = scroll
    let highlightWords = ChatHighlightRules.keywords(from: keywords)
    let resolvedEmoteSize = emoteAuto ? MobileChatAppearance.autoEmoteSize(text: textSize) : emoteSize
    ScrollView {
      // Chat has bounded history. Exact row heights avoid lazy height estimates
      // drifting or looping when long messages wrap, emotes load, or history trims.
      VStack(alignment: .leading, spacing: messageSpacing * typeScale) {
        ForEach(messages) { message in
          let highlighted = highlights && ChatHighlightRules.matches(message, viewerLogin: viewerLogin,
            viewerDisplayName: viewerDisplayName, keywords: highlightWords)
          MobileVisibleChatRow(
            animationsActive: animationsActive && scenePhase == .active,
            viewportHeight: viewportHeight
          ) {
            VStack(alignment: .leading, spacing: 4) {
              if let notice = message.systemMessage {
                Text(notice).font(.caption.bold()).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              RichChatLineView(
                message: message,
                nameColor: (message.colorHex.flatMap { Color(twitchHex: $0) }
                  ?? palette.chatSidePrimaryText)
                  .chatReadable(onSurface: palette.chatSideSurface, minRatio: 4.5),
                globalEmoteURLs: emoteURLs, badgeURLs: badgeURLs, cheermotes: cheermotes,
                textSize: textSize * typeScale, emoteSize: resolvedEmoteSize * typeScale,
                lineHeight: lineHeight * typeScale, letterSpacing: letterSpacing * typeScale,
                animatedEmotes: animatedEmotes && !reduceMotion,
                fontStyle: ChatFontStyle(rawValue: fontStyle) ?? .standard,
                showBadges: showBadges, showPlatformBadges: showPlatforms,
                bodyColorOverride: palette.chatSidePrimaryText, wrapsOversizedTokens: true,
                onInspectEmote: { name, url in
                  inspectedEmote = MobileChatEmote(name: name, url: url)
                }, scalesCustomFont: false)
            }
            .padding(.horizontal, highlighted ? 8 : 0)
            .padding(.vertical, highlighted ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
              if highlighted {
                RoundedRectangle(cornerRadius: 8).fill(palette.chatMentionSurface)
                  .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(
                      palette.chatMentionBorder, lineWidth: 1)
                  }
              }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
              message.id == messages.last?.id ? "mobile-chat-latest-message" : "mobile-chat-message"
            )
          }
        }
      }
      .padding(12)
    }
    .defaultScrollAnchor(.bottom)
    .scrollPosition($scroll.position)
    .scrollDismissesKeyboard(.interactively)
    .onScrollPhaseChange { _, phase in scroll.phaseChanged(phase) }
    .onScrollGeometryChange(for: Geometry.self) { geometry in
      Geometry(contentSize: geometry.contentSize, viewportSize: geometry.containerSize,
               bottomInset: geometry.contentInsets.bottom,
               distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom
                 - geometry.contentOffset.y - geometry.containerSize.height)
    } action: { old, new in
      if viewportHeight != new.viewportSize.height { viewportHeight = new.viewportSize.height }
      scroll.geometryChanged(distanceFromBottom: new.distanceFromBottom,
        sizeChanged: old.contentSize != new.contentSize || old.viewportSize != new.viewportSize
          || old.bottomInset != new.bottomInset)
    }
    .onChange(of: messages.last?.id) { _, _ in scroll.messagesChanged() }
    .accessibilityIdentifier("mobile-chat-timeline")
    .mask {
      MobileChatTopFade(enabled: !reduceTransparency && contrast != .increased)
    }
    .overlay(alignment: .bottom) {
      // A conditional scroll inset can reenter layout during a jump.
      MobileChatJumpButton(scroll: scroll)
        .padding(12)
    }
    .sheet(item: $inspectedEmote) { emote in
      MobileEmoteDetailView(emote: emote)
        .environment(\.themePalette, palette)
    }
  }
}

private struct MobileVisibleChatRow<Content: View>: View {
  let animationsActive: Bool
  let viewportHeight: CGFloat
  @ViewBuilder let content: Content
  @State private var visible = false

  var body: some View {
    content
      .environment(\.chatAnimationsActive, animationsActive && visible)
      .onGeometryChange(for: Bool.self) { geometry in
        let frame = geometry.frame(in: .scrollView(axis: .vertical))
        return viewportHeight > 0 && frame.maxY > 0 && frame.minY < viewportHeight
      } action: { visible = $0 }
  }
}

struct MobileChatTopFade: View {
  var enabled = true
  static let height: CGFloat = 48

  var body: some View {
    // Only alpha matters in this viewport mask; it never changes the scroll insets.
    VStack(spacing: 0) {
      LinearGradient(stops: [
        .init(color: enabled ? .clear : .black, location: 0),
        .init(color: enabled ? .clear : .black, location: 0.12),
        .init(color: .black.opacity(enabled ? 0.2 : 1), location: 0.4),
        .init(color: .black.opacity(enabled ? 0.7 : 1), location: 0.75),
        .init(color: .black, location: 1),
      ], startPoint: .top, endPoint: .bottom)
        .frame(height: Self.height)
      Rectangle().fill(.black)
    }
  }
}

private struct MobileChatJumpButton: View {
  let scroll: MobileChatScrollState

  var body: some View {
    if !scroll.followsLatest {
      Button("Jump to present", action: scroll.jumpToPresent)
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityIdentifier("mobile-chat-jump-to-present")
    }
  }
}

struct MobileChatComposer: View {
  let channel: String
  let onSettings: () -> Void
  var rewards: MobileChatRewardsSummary? = nil
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let composer: MobileChatComposerState

  var body: some View {
    @Bindable var composer = composer
    VStack(alignment: .leading, spacing: 6) {
      if let errorMessage = composer.errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
      MobileChatComposerInput(text: $composer.text, sending: composer.sending,
        onSend: { Task { await composer.send { try await auth.sendChatMessage($0, toChannel: channel) } } },
        onSettings: onSettings,
        reduceTransparency: reduceTransparency, rewards: rewards)
      if composer.text.count > 500 { Text("Messages can contain up to 500 characters.").font(.caption) }
    }
    .padding(.leading, rewards == nil ? 12 : 8)
    .padding(.trailing, 12)
    .padding(.vertical, 8)
  }
}

@MainActor
@Observable
final class MobileChatComposerState {
  var text = ""
  private(set) var sending = false
  private(set) var errorMessage: String?

  func send(_ action: (String) async throws -> Void) async {
    guard !sending else { return }
    guard text.count <= 500 else {
      errorMessage = "Messages can contain up to 500 characters."
      return
    }
    sending = true
    errorMessage = nil
    defer { sending = false }
    do {
      try await action(text)
      text = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct MobileChatComposerInput: View {
  @Binding var text: String
  let sending: Bool
  let onSend: () -> Void
  let onSettings: () -> Void
  let reduceTransparency: Bool
  var rewards: MobileChatRewardsSummary? = nil
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canSend = !sending && hasDraft
    HStack(alignment: .bottom, spacing: 8) {
      if let rewards { MobileChatRewardsButton(summary: rewards) }
      HStack(alignment: .bottom, spacing: 8) {
        MobileChatTextInput(text: $text, sending: sending, onSend: onSend)
          .overlay(alignment: .topLeading) {
            if text.isEmpty {
              Text("Send a message")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
          }
          .padding(.leading, 14)
        Button(action: hasDraft ? onSend : onSettings) {
          ZStack {
            Circle().fill(palette.chatSidePrimaryText.opacity(canSend ? 1 : 0.08))
            Icon(glyph: hasDraft ? .send : .dots, size: 20)
              .foregroundStyle(canSend ? palette.chatSideSurface : palette.chatSidePrimaryText)
              .opacity(sending ? 0 : 1)
            if sending {
              ProgressView()
                .tint(palette.chatSidePrimaryText)
                .controlSize(.small)
            }
          }
          .frame(width: 44, height: 44)
          .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasDraft ? Text("Send message") : Text("Chat settings"))
        .accessibilityValue(sending ? Text("Sending") : Text(""))
        .accessibilityIdentifier(hasDraft ? "mobile-chat-send" : "mobile-chat-settings")
        .disabled(sending)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hasDraft)
      }
      .padding(4)
      .background { MobileChatComposerSurface(reduceTransparency: reduceTransparency) }
      .overlay {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .strokeBorder(palette.chromeOpaqueBorder, lineWidth: 0.5)
          .allowsHitTesting(false)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("mobile-chat-composer")
    }
  }
}

private struct MobileChatComposerSurface: View {
  let reduceTransparency: Bool
  @Environment(\.themePalette) private var palette

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
    if reduceTransparency {
      shape.fill(palette.chromeOpaqueSurface)
    } else if #available(iOS 26.0, *) {
      shape.fill(.clear).glassEffect(.regular, in: shape)
    } else {
      shape.fill(.thinMaterial)
    }
  }
}
