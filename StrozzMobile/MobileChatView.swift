import SwiftUI

struct MobileChatView: View {
  let service: ChatService
  let channel: String
  @Environment(\.themePalette) private var palette
  @Environment(TwitchAuthSession.self) private var auth
  @State private var showAccount = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Stream chat").font(.subheadline.bold())
        Spacer()
        if !service.isConnected { Text("Connecting...").font(.caption).foregroundStyle(.secondary) }
      }
      .padding(12)
      MobileChatTimeline(messages: service.messages, emoteURLs: service.emoteURLs,
                         badgeURLs: service.badgeURLs, cheermotes: service.cheermotes)
      Divider()
      if auth.isAuthenticated {
        MobileChatComposer(channel: channel)
      } else {
        Button("Sign in to chat") { showAccount = true }.padding(12)
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
  @State var scroll = MobileChatScrollState()
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var textSize = 16
  @ScaledMetric(relativeTo: .body) private var emoteSize = 26

  private struct Geometry: Equatable {
    let contentSize: CGSize
    let viewportSize: CGSize
    let bottomInset: CGFloat
    let distanceFromBottom: CGFloat
  }

  var body: some View {
    @Bindable var scroll = scroll
    ScrollView {
      // Chat has bounded history. Exact row heights avoid lazy height estimates
      // drifting or looping when long messages wrap, emotes load, or history trims.
      VStack(alignment: .leading, spacing: 8) {
        ForEach(messages) { message in
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
              textSize: textSize, emoteSize: emoteSize, animatedEmotes: !reduceMotion,
              bodyColorOverride: palette.chatSidePrimaryText, wrapsOversizedTokens: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
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
  @Environment(TwitchAuthSession.self) private var auth
  @State private var text = ""
  @State private var sending = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
      HStack(alignment: .bottom) {
        TextField("Send a message", text: $text, axis: .vertical)
          .lineLimit(1...4).textFieldStyle(.roundedBorder)
          .disabled(sending)
        Button { Task { await send() } } label: {
          Icon(glyph: .send, size: 22).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Send message")
        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if text.count > 500 { Text("Messages can contain up to 500 characters.").font(.caption) }
    }
    .padding(8)
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
