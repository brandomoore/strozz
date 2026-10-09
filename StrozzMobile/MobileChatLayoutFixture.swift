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

struct MobileEmoteInspectionFixture: View {
  @State private var messages: [ChatMessage] = []
  @State private var imageURL: URL?
  @State private var failure: String?

  var body: some View {
    VStack {
      Text("Emote inspection fixture").font(.headline)
      if let failure { Text(failure) }
      MobileChatTimeline(messages: messages)
    }
    .environment(\.themePalette, .light)
    .preferredColorScheme(.light)
    .task {
      do {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("emote-\(UUID()).png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
          UIColor.systemGreen.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
          UIColor.systemBlue.setFill()
          context.fill(CGRect(x: 8, y: 8, width: 24, height: 48))
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        imageURL = url
        messages = [ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
          text: "FixtureWave FixtureBroken", twitchEmoteURLs: [
            "FixtureWave": url,
            "FixtureBroken": url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID()).png")
          ])]
      } catch {
        failure = "Fixture setup failed: \((error as NSError).code)"
      }
    }
    .onDisappear {
      guard let imageURL else { return }
      do { try FileManager.default.removeItem(at: imageURL) }
      catch { print("Emote fixture cleanup failed: \((error as NSError).code)") }
    }
  }
}
#endif
