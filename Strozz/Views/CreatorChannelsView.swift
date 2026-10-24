import SwiftUI

struct CreatorChannelsView: View {
  let session: CreatorLiveSession
  @State private var twitch: String
  @State private var kick: String
  @State private var youtube: String
  @State private var errorMessage: String?
  @Environment(\.dismiss) private var dismiss

  init(session: CreatorLiveSession) {
    self.session = session
    _twitch = State(initialValue: session.sources?.twitch ?? "")
    _kick = State(initialValue: session.sources?.kick ?? "")
    _youtube = State(initialValue: session.sources?.youtube ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Twitch") {
          TextField("Twitch channel", text: $twitch)
            .disabled(session.sources?.root.platform == .twitch || session.videoTarget?.platform == .twitch)
            .accessibilityIdentifier("creator-twitch-target")
        }
        Section("Kick") {
          TextField("Kick channel", text: $kick)
            .disabled(session.sources?.root.platform == .kick || session.videoTarget?.platform == .kick)
            .accessibilityIdentifier("creator-kick-target")
        }
        Section {
          TextField("YouTube channel or URL", text: $youtube)
            .disabled(session.sources?.root.platform == .youtube || session.videoTarget?.platform == .youtube)
            .accessibilityIdentifier("creator-youtube-target")
        } header: {
          Text("YouTube")
        } footer: {
          Text("Link only this creator's accounts. Chat and live viewer counts stay shared across video sources. Sending uses Twitch.")
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
        if let error = session.identityError { Text(error).foregroundStyle(.secondary) }
        Button("Save channels") { save() }
          .accessibilityIdentifier("creator-save-channels")
        Button("Cancel") { dismiss() }
      }
      .autocorrectionDisabled()
      .navigationTitle("Channels")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
    }
  }

  private func save() {
    errorMessage = nil
    do {
      var targets: [PlatformLiveTarget] = []
      for (platform, value) in [(LivePlatform.twitch, twitch), (.kick, kick), (.youtube, youtube)] {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          targets.append(try PlatformLiveTarget.validated(platform: platform, input: value))
        }
      }
      session.updateLinks(targets)
      if session.identityError == nil { dismiss() }
    } catch { errorMessage = error.localizedDescription }
  }
}
