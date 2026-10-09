#if DEBUG
import SwiftUI

/// Deterministic UI-test surface; never connects to Twitch or starts playback.
struct MobileChatLayoutFixture: View {
  @State private var compact = false
  @State private var draft = ""
  @State private var showSettings = false
  private let messages = (0..<200).compactMap { index in
    ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #example :Message \(index) "
      + (index.isMultiple(of: 7) ? String(repeating: "unbroken-link-", count: 25) : "reading chat"))
  }

  var body: some View {
    VStack(spacing: 0) {
      Button("Resize chat") { compact.toggle() }.frame(minHeight: 44)
      MobileChatTimeline(messages: messages)
        .frame(maxHeight: compact ? 240 : .infinity)
      MobileChatComposerInput(text: $draft, sending: false, onSend: { draft = "" },
        onSettings: { showSettings = true }, reduceTransparency: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .environment(\.themePalette, .light)
    .preferredColorScheme(.light)
    .sheet(isPresented: $showSettings) {
      NavigationStack {
        MobileChatSettingsView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
      }
    }
  }
}

struct MobileChatComposerFixture: View {
  @State private var draft = ""
  @State private var submitted = ""
  @State private var theme = AppTheme.light
  @State private var opaque = false
  @State private var sending = false
  @State private var showSettings = false
  @State private var initialized = false
  @State private var defaults = UserDefaults(suiteName: "StrozzMobileComposerFixture")!
  private let messages = [
    ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [], text: "A message for @viewer",
      twitchEmoteURLs: [:])
  ]

  var body: some View {
    let palette = theme.palette(systemColorScheme: .light)
    VStack(spacing: 16) {
      HStack {
        Button("Change appearance") { theme = theme == .light ? .dark : .light }
        Button("Reduce transparency") { opaque.toggle() }
        Button("Sending") { sending.toggle() }
      }
      .font(.caption)
      MobileChatTimeline(messages: messages, viewerLogin: "viewer")
      Text(submitted).accessibilityIdentifier("composer-submitted")
      MobileChatComposerInput(text: $draft, sending: sending, onSend: {
        submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
      }, onSettings: { showSettings = true }, reduceTransparency: opaque)
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
    .background(palette.chatSideSurface)
    .environment(\.themePalette, palette)
    .preferredColorScheme(theme.preferredColorScheme)
    .defaultAppStorage(defaults)
    .task {
      guard !initialized else { return }
      initialized = true
      defaults.removePersistentDomain(forName: "StrozzMobileComposerFixture")
    }
    .sheet(isPresented: $showSettings) {
      NavigationStack {
        MobileChatSettingsView()
          .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
      }
      .defaultAppStorage(defaults)
      .environment(\.themePalette, palette)
    }
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
