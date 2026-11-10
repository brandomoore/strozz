import SwiftUI
import OSLog

struct TwitchCollaborationNames: View {
  let channelID: String
  @Environment(\.scenePhase) private var scenePhase
  @State private var participants: [TwitchCollaborationParticipant] = []
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !participants.isEmpty {
        Text("Streaming together").font(.caption).foregroundStyle(.secondary)
        Text(participants.map(\.name).joined(separator: " + "))
          .font(.headline)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      } else if failed {
        Text("Couldn't load streaming partners.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("streaming-together")
    .task(id: "\(channelID)/\(scenePhase == .active)") {
      participants = []
      failed = false
      guard scenePhase == .active else { return }
      do {
        while !Task.isCancelled {
          do {
            let loaded = try await TwitchCollaborationService().fetch(channelID: channelID)
            try Task.checkCancellation()
            participants = loaded
            failed = false
          } catch {
            guard !Task.isCancelled else { return }
            // Stale names must not imply a collaboration is still live.
            participants = []
            failed = true
            Logger(subsystem: "com.thatcube.Strozz", category: "collaboration")
              .error("Could not refresh streaming partners: \(error.localizedDescription, privacy: .public)")
          }
          try await Task.sleep(for: .seconds(60))
        }
      } catch is CancellationError {
        // The page or foreground lifecycle ended.
      } catch {
        Logger(subsystem: "com.thatcube.Strozz", category: "collaboration")
          .error("Streaming partner refresh stopped: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
