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
    .task {
      do {
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
        player.model.chat.channel = channel.login
        player.model.chat.isConnected = true
        player.model.chat.messages = (0..<100).compactMap {
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
