import SwiftUI

struct MobileChatView: View {
  let service: ChatService
  let channel: String
  @Environment(\.themePalette) private var palette
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchAccountSync.self) private var sync: TwitchAccountSync?
  @State private var showAccount = false
  @State private var showSettings = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Stream chat").font(.subheadline.bold())
        Spacer()
        if !service.isConnected { Text("Connecting...").font(.caption).foregroundStyle(.secondary) }
      }
      .padding(12)
      MobileChatTimeline(messages: service.messages, emoteURLs: service.emoteURLs,
                         badgeURLs: service.badgeURLs, cheermotes: service.cheermotes,
                         viewerLogin: auth.userLogin, viewerDisplayName: auth.userDisplayName)
      Divider()
      if auth.isAuthenticated, sync?.isRestoringAccount != true {
        MobileChatComposer(channel: channel, onSettings: { showSettings = true })
      } else {
        HStack {
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
        .padding(.horizontal, 12)
      }
    }
    .accessibilityIdentifier("mobile-chat-panel")
    .background(palette.chatSideSurface)
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
  @State private var inspectedEmote: MobileChatEmote?
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
          VStack(alignment: .leading, spacing: 4) {
            if let notice = message.systemMessage {
              Text(notice).font(.caption.bold()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            RichChatLineView(
              message: message,
              nameColor: (message.colorHex.flatMap { Color(twitchHex: $0) } ?? palette.chatSidePrimaryText)
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
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.chatMentionBorder, lineWidth: 1) }
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(message.id == messages.last?.id ? "mobile-chat-latest-message" : "mobile-chat-message")
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
      scroll.geometryChanged(distanceFromBottom: new.distanceFromBottom,
        sizeChanged: old.contentSize != new.contentSize || old.viewportSize != new.viewportSize
          || old.bottomInset != new.bottomInset)
    }
    .onChange(of: messages.last?.id) { _, _ in scroll.messagesChanged() }
    .accessibilityIdentifier("mobile-chat-timeline")
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
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @State private var text = ""
  @State private var sending = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
      MobileChatComposerInput(text: $text, sending: sending,
        onSend: { Task { await send() } }, onSettings: onSettings, reduceTransparency: reduceTransparency)
      if text.count > 500 { Text("Messages can contain up to 500 characters.").font(.caption) }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func send() async {
    guard !sending else { return }
    guard text.count <= 500 else {
      errorMessage = "Messages can contain up to 500 characters."
      return
    }
    sending = true
    errorMessage = nil
    defer { sending = false }
    do {
      try await auth.sendChatMessage(text, toChannel: channel)
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
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let canSend = !sending && hasDraft
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
