import SwiftUI

struct MobileChatView: View {
  let service: ChatService
  let channel: String
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(TwitchAuthSession.self) private var auth
  @State private var followChat = true
  @State private var showAccount = false
  @ScaledMetric(relativeTo: .body) private var textSize = 16
  @ScaledMetric(relativeTo: .body) private var emoteSize = 26

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Stream chat").font(.subheadline.bold())
        Spacer()
        if !service.isConnected { Text("Connecting...").font(.caption).foregroundStyle(.secondary) }
      }
      .padding(12)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(service.messages) { message in
              VStack(alignment: .leading, spacing: 4) {
                if let notice = message.systemMessage {
                  Text(notice).font(.caption.bold()).foregroundStyle(.secondary)
                }
                RichChatLineView(
                  message: message,
                  nameColor: (message.colorHex.flatMap { Color(twitchHex: $0) } ?? palette.chatSidePrimaryText)
                    .chatReadable(onSurface: palette.chatSideSurface, minRatio: 4.5),
                  globalEmoteURLs: service.emoteURLs, badgeURLs: service.badgeURLs,
                  cheermotes: service.cheermotes, textSize: textSize, emoteSize: emoteSize,
                  animatedEmotes: !reduceMotion, bodyColorOverride: palette.chatSidePrimaryText)
              }
              .id(message.id)
            }
            Color.clear.frame(height: 1).id("chat-bottom")
              .onScrollVisibilityChange { visible in if visible { followChat = true } }
          }
          .padding(.horizontal, 12)
        }
        .defaultScrollAnchor(.bottom)
        .onScrollPhaseChange { _, phase in
          if phase == .interacting { followChat = false }
        }
        .onChange(of: service.messages.last?.id) { _, _ in
          if followChat { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        }
        .overlay(alignment: .bottom) {
          if !followChat {
            Button("Latest messages") {
              followChat = true
              proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .buttonStyle(.borderedProminent).padding(8)
          }
        }
      }
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
