#if DEBUG
import SwiftUI

/// Deterministic UI-test surface; never connects to Twitch or starts playback.
struct MobileChatLayoutFixture: View {
  @State private var compact = false
  @State private var draft = ""
  private let messages = (0..<200).compactMap { index in
    ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :Message \(index) "
      + (index.isMultiple(of: 7) ? String(repeating: "unbroken-link-", count: 25) : "reading chat"))
  }

  var body: some View {
    VStack(spacing: 0) {
      Button("Resize chat") { compact.toggle() }.frame(minHeight: 44)
      MobileChatTimeline(messages: messages)
        .frame(maxHeight: compact ? 240 : .infinity)
      TextField("Send a message", text: $draft).textFieldStyle(.roundedBorder).padding()
    }
    .environment(\.themePalette, .light)
    .preferredColorScheme(.light)
  }
}
#endif
