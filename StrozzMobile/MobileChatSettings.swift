import SwiftUI

enum MobileChatAppearance {
  static let textSize = 16.0
  static let emoteSize = 26.0
  static let messageSpacing = 8.0

  static func autoEmoteSize(text: Double) -> Double { (text * emoteSize / textSize).rounded() }

  static func values(for preset: ChatAppearancePreset) -> (text: Double, line: Double, spacing: Double) {
    switch preset {
    case .small: (14, -1, 6)
    case .normal: (16, -1, 8)
    case .large: (20, 0, 10)
    }
  }

  static func preset(text: Double, line: Double, spacing: Double, autoEmotes: Bool) -> ChatAppearancePreset? {
    guard autoEmotes else { return nil }
    return ChatAppearancePreset.allCases.first {
      let values = values(for: $0)
      return values.text == text && values.line == line && values.spacing == spacing
    }
  }
}

@MainActor
enum MobileChatSourcePreferences {
  static func apply(to chat: ChatService, channel: String, defaults: UserDefaults = .standard) {
    guard !channel.isEmpty, chat.channel == channel.lowercased() else { return }
    let youtube = defaults.object(forKey: PersistenceKey.experimentalYouTubeMergeEnabled) as? Bool ?? false
    let kick = defaults.object(forKey: PersistenceKey.experimentalKickMergeEnabled) as? Bool ?? false
    if chat.youtubeMergeEnabled != youtube {
      chat.configureExperimentalYouTubeMerge(enabled: youtube,
        channelOrURL: chat.youtubeChannelOrURL.isEmpty ? "@\(channel)" : chat.youtubeChannelOrURL)
    }
    if chat.kickMergeEnabled != kick {
      chat.configureExperimentalKickMerge(enabled: kick,
        channelOrURL: chat.kickChannelOrURL.isEmpty ? channel : chat.kickChannelOrURL)
    }
  }
}

struct MobileChatSettingsView: View {
  var channel: String? = nil
  var service: ChatService? = nil
  @Environment(\.themePalette) private var palette
  @AppStorage(PersistenceKey.chatTextSizeValue) private var textSize = MobileChatAppearance.textSize
  @AppStorage(PersistenceKey.chatLineHeightValue) private var lineHeight = Double(ChatAppearance.defaultLineHeight)
  @AppStorage(PersistenceKey.chatLetterSpacingValue) private var letterSpacing = 0.0
  @AppStorage(PersistenceKey.chatMessageSpacingValue) private var messageSpacing = MobileChatAppearance.messageSpacing
  @AppStorage(PersistenceKey.chatFontStyle) private var fontStyle = ChatFontStyle.standard.rawValue
  @AppStorage(PersistenceKey.chatEmoteAuto) private var emoteAuto = true
  @AppStorage(PersistenceKey.chatEmoteSizeValue) private var emoteSize = MobileChatAppearance.emoteSize
  @AppStorage(PersistenceKey.chatAnimatedEmotes) private var animatedEmotes = true
  @AppStorage(PersistenceKey.chatShowBadges) private var showBadges = true
  @AppStorage(PersistenceKey.chatShowPlatformBadges) private var showPlatforms = true
  @AppStorage(PersistenceKey.chatHighlightMentionsEnabled) private var highlights = true
  @AppStorage(PersistenceKey.chatHighlightKeywords) private var keywords = ""
  @AppStorage(PersistenceKey.chatSyncToStream) private var sync = true

  private var preset: Binding<ChatAppearancePreset?> {
    Binding {
      MobileChatAppearance.preset(text: textSize, line: lineHeight, spacing: messageSpacing, autoEmotes: emoteAuto)
    } set: { preset in
      if let preset {
        let values = MobileChatAppearance.values(for: preset)
        textSize = values.text
        lineHeight = values.line
        messageSpacing = values.spacing
        emoteAuto = true
      }
    }
  }

  var body: some View {
    Form {
      MobileChatReadabilitySettings(preset: preset, textSize: $textSize, lineHeight: $lineHeight,
        letterSpacing: $letterSpacing, messageSpacing: $messageSpacing, fontStyle: $fontStyle)
      MobileChatEmoteSettings(automatic: $emoteAuto, size: $emoteSize, animated: $animatedEmotes)
      MobileChatBadgeSettings(showBadges: $showBadges, showPlatforms: $showPlatforms)
      MobileChatHighlightSettings(enabled: $highlights, keywords: $keywords)
      Section {
        Toggle("Sync chat to extra delay", isOn: $sync)
      } header: {
        Text("Stream timing")
      } footer: {
        Text("Chat stays live normally. If video falls behind, incoming chat waits to match it. Sending is immediate.")
      }
      MobileChatSourceSettings(channel: channel, service: service)
      Section {
        Button("Reset appearance") {
          textSize = MobileChatAppearance.textSize
          lineHeight = Double(ChatAppearance.defaultLineHeight)
          letterSpacing = 0
          messageSpacing = MobileChatAppearance.messageSpacing
          fontStyle = ChatFontStyle.standard.rawValue
          emoteAuto = true
          emoteSize = MobileChatAppearance.emoteSize
          animatedEmotes = true
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(palette.chatSideSurface)
    .navigationTitle("Chat settings")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("mobile-chat-settings-form")
  }
}

private struct MobileChatReadabilitySettings: View {
  @Binding var preset: ChatAppearancePreset?
  @Binding var textSize: Double
  @Binding var lineHeight: Double
  @Binding var letterSpacing: Double
  @Binding var messageSpacing: Double
  @Binding var fontStyle: String

  var body: some View {
    Section("Appearance") {
      Picker("Size preset", selection: $preset) {
        ForEach(ChatAppearancePreset.allCases) { preset in Text(preset.title).tag(Optional(preset)) }
        Text("Custom").tag(ChatAppearancePreset?.none).disabled(true)
      }
      Stepper("Text size: \(Int(textSize))", value: $textSize, in: 12...32)
        .accessibilityIdentifier("chat-setting-text-size")
      Picker("Font", selection: $fontStyle) {
        ForEach(ChatFontStyle.allCases) { style in Text(style.title).tag(style.rawValue) }
      }
      Stepper("Line spacing: \(Int(lineHeight))", value: $lineHeight, in: -4...16)
      Stepper("Letter spacing: \(Int(letterSpacing))", value: $letterSpacing, in: -2...6)
      Stepper("Message spacing: \(Int(messageSpacing))", value: $messageSpacing, in: 0...32, step: 2)
    }
  }
}

private struct MobileChatEmoteSettings: View {
  @Binding var automatic: Bool
  @Binding var size: Double
  @Binding var animated: Bool

  var body: some View {
    Section {
      Toggle("Automatic emote size", isOn: $automatic)
      if !automatic { Stepper("Emote size: \(Int(size))", value: $size, in: 18...96, step: 2) }
      Toggle("Animated emotes", isOn: $animated)
        .accessibilityIdentifier("chat-setting-animated-emotes")
    } header: {
      Text("Emotes")
    } footer: {
      Text("Automatic sizing keeps emotes proportional to text. Reduce Motion always turns animation off.")
    }
  }
}

private struct MobileChatBadgeSettings: View {
  @Binding var showBadges: Bool
  @Binding var showPlatforms: Bool

  var body: some View {
    Section("Badges") {
      Toggle("User badges", isOn: $showBadges)
      Toggle("Platform badges", isOn: $showPlatforms)
    }
  }
}

private struct MobileChatHighlightSettings: View {
  @Binding var enabled: Bool
  @Binding var keywords: String

  var body: some View {
    Section {
      Toggle("Highlight mentions and keywords", isOn: $enabled)
      if enabled {
        TextField("Keywords, separated by commas", text: $keywords, axis: .vertical)
          .lineLimit(1...3)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .accessibilityIdentifier("chat-setting-keywords")
      }
    } header: {
      Text("Highlights")
    } footer: {
      Text("Highlight messages that mention or reply to you, or contain your keywords.")
    }
  }
}

private struct MobileChatSourceSettings: View {
  let channel: String?
  let service: ChatService?
  @AppStorage(PersistenceKey.experimentalYouTubeMergeEnabled) private var youtube = false
  @AppStorage(PersistenceKey.experimentalKickMergeEnabled) private var kick = false
  @State private var youtubeTarget: String
  @State private var kickTarget: String

  init(channel: String?, service: ChatService?) {
    self.channel = channel
    self.service = service
    _youtubeTarget = State(initialValue: service?.youtubeChannelOrURL.isEmpty == false
      ? service?.youtubeChannelOrURL ?? "" : channel.map { "@\($0)" } ?? "")
    _kickTarget = State(initialValue: service?.kickChannelOrURL.isEmpty == false
      ? service?.kickChannelOrURL ?? "" : channel ?? "")
  }

  var body: some View {
    Section {
      Toggle("YouTube chat", isOn: $youtube)
        .onChange(of: youtube) { _, _ in applyTargets() }
      if let service, channel != nil {
        TextField("YouTube handle or URL", text: $youtubeTarget)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .submitLabel(.done).onSubmit(applyTargets)
        if youtube, let status = service.youtubeStatusMessage {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
      Toggle("Kick chat", isOn: $kick)
        .onChange(of: kick) { _, _ in applyTargets() }
      if let service, channel != nil {
        TextField("Kick handle or URL", text: $kickTarget)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .submitLabel(.done).onSubmit(applyTargets)
        if kick, let status = service.kickStatusMessage {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
        Button("Apply channel targets", action: applyTargets)
      }
    } header: {
      Text("Chat sources")
    } footer: {
      if channel == nil {
        Text("Open a stream to edit its other channel targets. Extra chat sources are off until enabled.")
      } else {
        Text("Targets default to this streamer's Twitch handle. Edit them if the other channel differs, then tap Apply. Your messages still go to Twitch.")
      }
    }
  }

  private func applyTargets() {
    guard let service, let channel, service.channel == channel.lowercased() else { return }
    if service.youtubeMergeEnabled != youtube || service.youtubeChannelOrURL != youtubeTarget.trimmingCharacters(in: .whitespacesAndNewlines) {
      service.configureExperimentalYouTubeMerge(enabled: youtube, channelOrURL: youtubeTarget)
    }
    if service.kickMergeEnabled != kick || service.kickChannelOrURL != kickTarget.trimmingCharacters(in: .whitespacesAndNewlines) {
      service.configureExperimentalKickMerge(enabled: kick, channelOrURL: kickTarget)
    }
  }
}
