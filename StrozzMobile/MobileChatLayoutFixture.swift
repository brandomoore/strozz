#if DEBUG
import ImageIO
import SDWebImage
import SwiftUI
import UniformTypeIdentifiers

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
        .padding(.vertical, 4)
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
      }, onSettings: { showSettings = true }, reduceTransparency: opaque,
        rewards: ProcessInfo.processInfo.environment["STROZZ_REWARDS_FIXTURE"] == "1"
          ? MobileChatRewardsSummary(balance: 57990, name: "Delibird's", imageURL: nil,
              streak: 10, errorMessage: nil) : nil)
      .padding(.leading, ProcessInfo.processInfo.environment["STROZZ_REWARDS_FIXTURE"] == "1" ? 8 : 12)
      .padding(.trailing, 12)
      .padding(.vertical, 4)
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
  @State private var gifCacheKey: String?
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
        if ProcessInfo.processInfo.environment["STROZZ_GIF_FIXTURE"] == "1" {
          messages = [try nativeGIFMessage()]
          return
        }
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
      if let gifCacheKey { SDImageCache.shared.removeImage(forKey: gifCacheKey) }
      guard let imageURL else { return }
      do { try FileManager.default.removeItem(at: imageURL) }
      catch { print("Emote fixture cleanup failed: \((error as NSError).code)") }
    }
  }

  private func nativeGIFMessage() throws -> ChatMessage {
    let data = NSMutableData()
    guard let output = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationSetProperties(output,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for color in [UIColor.systemGreen, .systemBlue] {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 140), format: format).image {
        color.setFill()
        $0.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
        UIColor.white.setFill()
        $0.fill(CGRect(x: 60, y: 35, width: 80, height: 70))
      }
      guard let cgImage = image.cgImage else { throw CocoaError(.fileWriteUnknown) }
      CGImageDestinationAddImage(output, cgImage,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.3]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    let id = "StrozzFixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let label = "[Fixture Wave GIF]"
    guard let message = ChatMessage(ircLine:
      "@gifs=0-\(label.unicodeScalars.count - 1)|\(id)|https://media.giphy.com/media/\(id)/giphy.gif :viewer!v@h PRIVMSG #fixture :\(label)"),
      let gif = message.gifs.first else { throw CocoaError(.coderInvalidValue) }
    gifCacheKey = gif.url.absoluteString
    SDImageCache.shared.storeImageData(toDisk: data as Data, forKey: gif.url.absoluteString)
    return message
  }
}
struct MobileEmoteMenuFixture: View {
  @State private var composer = MobileChatComposerState()
  @State private var urls: [String: URL] = [:]
  @State private var showEmotes = false
  @State private var theme = AppTheme.light
  @State private var opaque = false
  @State private var submitted = ""
  @State private var failure: String?
  @State private var cacheKeys: [String] = []
  private var readOnly: Bool { ProcessInfo.processInfo.environment["STROZZ_EMOTE_MENU_READ_ONLY"] == "1" }
  private var insert: ((String) -> Bool)? {
    guard !readOnly else { return nil }
    return { composer.insertEmote($0) }
  }

  var body: some View {
    @Bindable var composer = composer
    let palette = theme.palette(systemColorScheme: .light)
    VStack {
      HStack {
        Button("Change appearance") { theme = theme == .light ? .oled : .light }
        Button("Reduce transparency") { opaque.toggle() }
      }
      if let failure { Text(failure) }
      Text(submitted).accessibilityIdentifier("composer-submitted")
      Text("\(urls.count)").accessibilityIdentifier("emote-fixture-ready")
      Spacer()
      MobileChatComposerInput(text: $composer.text, sending: false,
        onSend: { submitted = composer.text; composer.text = ""; composer.selection = nil },
        onSettings: {}, reduceTransparency: opaque,
        selection: $composer.selection, onEmotes: { showEmotes = true })
        .padding(12)
    }
    .background(palette.chatSideSurface)
    .environment(\.themePalette, palette)
    .preferredColorScheme(theme.preferredColorScheme)
    .sheet(isPresented: $showEmotes) {
      MobileEmoteMenu(channel: ProcessInfo.processInfo.environment["STROZZ_EMOTE_MENU_LIVE"] == "1" ? "burn" : "fixture",
        urls: urls, isLoading: false,
        needsRetry: ProcessInfo.processInfo.environment["STROZZ_EMOTE_MENU_PARTIAL"] == "1",
        insertionError: composer.errorMessage,
        onInsert: insert, onRetry: {})
        .environment(\.themePalette, palette)
    }
    .task {
      do {
        if ProcessInfo.processInfo.environment["STROZZ_EMOTE_MENU_LIVE"] == "1" {
          let catalog = await EmoteCatalogService.shared.snapshot(for: "burn", refreshChannelEmotes: true)
          urls = catalog.urls
          if catalog.needsRetry { failure = "A live emote provider is unavailable." }
          return
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image {
          UIColor.systemGreen.setFill()
          $0.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
          UIColor.systemBlue.setFill()
          $0.fill(CGRect(x: 20, y: 8, width: 56, height: 48))
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        for (name, host) in [
          ("Kappa", "static-cdn.jtvnw.net"), ("xdd", "cdn.7tv.app"),
          ("CAUGHT", "cdn.7tv.app"), ("FeelsGoodMan", "cdn.betterttv.net"),
          ("FrankerZ", "cdn.frankerfacez.com"),
        ] {
          let url = URL(string: "https://\(host)/strozz-fixture/\(UUID()).png")!
          urls[name] = url
          for prefix in ["", "chat-emote:animated:", "chat-emote:static:"] {
            let key = prefix + url.absoluteString
            cacheKeys.append(key)
            SDImageCache.shared.storeImageData(toDisk: data, forKey: key)
          }
        }
        for index in 0..<200 { urls["Extra\(index)"] = urls["xdd"] }
      } catch {
        failure = "Fixture setup failed: \((error as NSError).code)"
      }
    }
    .onDisappear {
      for key in cacheKeys { SDImageCache.shared.removeImage(forKey: key) }
    }
  }
}
#endif
