#if DEBUG
import SwiftUI

/// Exercises the real player layout without connecting to chat or resolving a stream.
struct MobilePlayerLayoutFixture: View {
  @State private var session: MobilePlaybackSession?
  @State private var auth = TwitchAuthSession()
  @State private var imageURL: URL?
  @State private var failure: String?

  var body: some View {
    ZStack {
      if let session, let channel = session.channel {
        MobilePlayerView(channel: channel, session: session)
      } else if let failure {
        Text(failure)
      } else {
        ProgressView()
      }
    }
    .environment(auth)
    .environment(\.themePalette, .dark)
    .preferredColorScheme(.dark)
    .overlay {
      GeometryReader { geometry in
        Color.clear
          .accessibilityElement()
          .accessibilityIdentifier("fixture-player-viewport")
          .accessibilityValue("\(geometry.frame(in: .global).minY) \(geometry.size.height)")
          .allowsHitTesting(false)
      }
    }
    .task {
      do {
        if ProcessInfo.processInfo.environment["STROZZ_CHAT_WIDTH_FIXTURE_RESET"] == "1" {
          UserDefaults.standard.removeObject(forKey: PersistenceKey.mobileChatWidthValue)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-avatar-\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
          UIColor.systemTeal.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
          ("S" as NSString).draw(at: CGPoint(x: 13, y: 4),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.label])
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        imageURL = url
        let channel = FollowedChannel(id: "fixture", login: "fixture", displayName: "Sample streamer",
          title: "A stream description that appears with the controls", gameName: "Just Chatting",
          viewerCount: 1200, thumbnailURL: nil, profileImageURL: url, isLive: true)
        let player = MobilePlaybackSession.layoutFixture(channel: channel)
        if ProcessInfo.processInfo.environment["STROZZ_PLAYER_DRAFT_FIXTURE"] == "1" {
          auth.isAuthenticated = true
          auth.userID = "fixture"
        }
        player.model.chat.channel = channel.login
        player.model.chat.isConnected = true
        let historySize = ProcessInfo.processInfo.environment["STROZZ_LONG_CHAT_FIXTURE"] == "1" ? 500 : 100
        player.model.chat.messages = (0..<historySize).compactMap {
          ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #fixture :Message \($0) in the live chat")
        }
        session = player
      } catch {
        failure = "Player fixture setup failed: \((error as NSError).code)"
      }
    }
    .onDisappear {
      session?.close()
      guard let imageURL else { return }
      do { try FileManager.default.removeItem(at: imageURL) }
      catch { print("Player fixture cleanup failed: \((error as NSError).code)") }
    }
  }
}
#endif
