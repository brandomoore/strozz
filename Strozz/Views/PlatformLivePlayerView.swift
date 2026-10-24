import AVKit
import SwiftUI

struct PlatformLivePlayerView: View {
  @State private var model: PlatformLivePlayback
  @State private var showsSources = false
  @State private var showsChat = true
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.themePalette) private var palette

  init(target: PlatformLiveTarget, sources: [PlatformLiveTarget] = []) {
    _model = State(initialValue: PlatformLivePlayback(target: target, sources: sources))
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        PlatformLiveControls(model: model, showsChat: $showsChat, showsSources: $showsSources)
        let sideChat = geometry.size.width > geometry.size.height
        let layout =
          sideChat ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
          ZStack {
            PlatformVideoSurface(player: model.player)
              .accessibilityIdentifier("platform-live-video")
            if model.isLoading {
              ProgressView("Loading stream")
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = model.errorMessage {
              VStack(spacing: 16) {
                Text(error).multilineTextAlignment(.center)
                Button("Try again") { model.retry() }
                Button("Change source") { showsSources = true }
              }
              .padding()
              .background(palette.cardOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          if showsChat {
            PlatformLiveChat(chat: model.chat)
              .frame(
                width: sideChat ? max(260, geometry.size.width * 0.26) : nil,
                height: sideChat ? nil : geometry.size.height * 0.35)
          }
        }
      }
      .background(palette.cardOpaqueSurface)
    }
    .environment(\.colorScheme, palette == .light ? .light : .dark)
    .task { model.start() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        model.sceneActive(false)
      } else if phase == .active {
        model.sceneActive(true)
      }
    }
    .onDisappear { model.stop() }
    .sheet(isPresented: $showsSources) { PlatformLiveSourceEditor(model: model) }
    #if os(tvOS)
      .onExitCommand { dismiss() }
    #endif
  }

  // Own transport intent so a decoder pause cannot be mistaken for the viewer's
  // pause, while retaining AVKit's native video rendering and display behavior.
  private struct PlatformVideoSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
      let controller = AVPlayerViewController()
      controller.player = player
      controller.showsPlaybackControls = false
      controller.allowsPictureInPicturePlayback = false
      controller.view.isUserInteractionEnabled = false
      #if os(tvOS)
        controller.appliesPreferredDisplayCriteriaAutomatically = false
      #endif
      return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
      if controller.player !== player { controller.player = player }
    }
  }
}

private struct PlatformLiveControls: View {
  let model: PlatformLivePlayback
  @Binding var showsChat: Bool
  @Binding var showsSources: Bool
  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 16) {
        Button("Close") { dismiss() }.accessibilityIdentifier("platform-live-close")
        VStack(alignment: .leading, spacing: 2) {
          Text(model.title.isEmpty ? model.target.channel : model.title).font(.headline).lineLimit(
            1)
          Text("\(model.target.platform.title) · \(model.sourceStatus)")
            .font(.caption).foregroundStyle(palette.chromeOnOpaque.opacity(0.7))
            .accessibilityIdentifier("platform-live-source-status")
        }
        Spacer(minLength: 0)
        if let latency = model.latencySeconds {
          Text("\(latency, specifier: "%.1f")s").font(.caption.monospacedDigit())
            .accessibilityLabel("\(latency, specifier: "%.1f") seconds behind broadcast time")
        }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 16) {
          Button(model.isPaused ? "Play" : "Pause") { model.togglePause() }
            .accessibilityIdentifier("platform-live-pause")
          Button("Go live") { model.goLive() }
          Button {
            showsSources = true
          } label: {
            Label {
              Text("Source")
            } icon: {
              Icon(glyph: .brandKick, size: 20)
            }
          }
          .accessibilityIdentifier("platform-live-source")
          Menu {
            Button(model.target.platform == .youtube ? "Auto" : "Auto · Native low latency") {
              model.selectQuality(nil)
            }
            ForEach(model.qualities) { quality in
              Button(quality.name) { model.selectQuality(quality.id) }
            }
          } label: {
            Text(model.qualities.first { $0.id == model.qualityID }?.name ?? "Auto")
          }
          .disabled(model.isLoading)
          .accessibilityIdentifier("platform-live-quality")
          Button(showsChat ? "Hide chat" : "Show chat") { showsChat.toggle() }
        }
      }
      #if os(tvOS)
        .frame(height: 90)
      #else
        .frame(height: 52)
      #endif
    }
    .padding()
    .background(palette.chromeOpaqueSurface)
  }

}

private struct PlatformLiveChat: View {
  let chat: ChatService
  @Environment(\.themePalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Live chat").font(.headline)
      Text("Read-only").font(.caption).foregroundStyle(palette.chromeOnOpaque.opacity(0.7))
      if let status = chat.kickStatusMessage ?? chat.youtubeStatusMessage {
        Text(status).font(.caption).foregroundStyle(palette.chromeOnOpaque.opacity(0.7))
      }
      ScrollViewReader { scroll in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(chat.messages.suffix(100)) { message in
              RichChatLineView(
                message: message, nameColor: palette.chromeOnOpaque,
                globalEmoteURLs: chat.emoteURLs, badgeURLs: chat.badgeURLs,
                bodyColorOverride: palette.chromeOnOpaque, wrapsOversizedTokens: true
              )
              .id(message.id)
            }
          }
        }
        .onChange(of: chat.messages.last?.id) { _, id in
          if let id { scroll.scrollTo(id, anchor: .bottom) }
        }
      }
    }
    .padding()
    .foregroundStyle(palette.chromeOnOpaque)
    .background(palette.chromeOpaqueSurface)
    .accessibilityIdentifier("platform-live-chat")
  }
}

private struct PlatformLiveSourceEditor: View {
  let model: PlatformLivePlayback
  @State private var draftPlatform: LivePlatform
  @State private var draftTarget: String
  @State private var inputError: String?
  @Environment(\.dismiss) private var dismiss

  init(model: PlatformLivePlayback) {
    self.model = model
    _draftPlatform = State(initialValue: model.target.platform)
    _draftTarget = State(initialValue: model.target.channel)
  }

  var body: some View {
    NavigationStack {
      Form {
        if model.sources.count > 1 {
          Section("Known sources") {
            ForEach(model.sources) { source in
              Button("\(source.platform.title): \(source.channel)") {
                model.switchSource(source)
                dismiss()
              }
            }
          }
        }
        Picker("Platform", selection: $draftPlatform) {
          ForEach(LivePlatform.allCases, id: \.self) { platform in
            Text(platform.title).tag(platform)
          }
          .accessibilityIdentifier("platform-source-platform")
        }
        TextField("Channel name or URL", text: $draftTarget)
          .autocorrectionDisabled()
          .accessibilityIdentifier("platform-source-target")
        if let inputError { Text(inputError).foregroundStyle(.secondary) }
        Button("Switch stream") {
          do {
            let target = try PlatformLiveTarget.validated(
              platform: draftPlatform, input: draftTarget)
            model.switchSource(target)
            dismiss()
          } catch { inputError = error.localizedDescription }
        }
        .accessibilityIdentifier("platform-source-switch")
        Button("Cancel") { dismiss() }
      }
      .navigationTitle("Stream source")
    }
  }

}

struct KickDirectoryView: View {
  @State private var query: String
  @State private var channel: KickChannel?
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var playback: PlatformLiveTarget?
  @AppStorage("kickRecentChannels") private var recent = ""

  init(initialQuery: String = "") {
    _query = State(initialValue: initialQuery)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Watch Kick channels").font(.title2.bold())
          Text(
            "Find a creator by their Kick channel name or channel URL, including creators who don't stream on Twitch."
          )
          .foregroundStyle(.secondary)
          TextField("Kick channel or URL", text: $query)
            .autocorrectionDisabled()
            .accessibilityIdentifier("kick-channel-input")
          Button("Find channel") { Task { await lookup() } }
            .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("kick-find-channel")
          if isLoading { ProgressView("Finding channel") }
          if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
          if let channel {
            VStack(alignment: .leading, spacing: 8) {
              Text(channel.displayName).font(.headline)
              Text(channel.title).foregroundStyle(.secondary)
              if channel.isLive {
                Button("Watch live") { open(channel.slug) }
                  .accessibilityIdentifier("kick-watch-live")
              } else {
                Text("Offline").foregroundStyle(.secondary)
              }
            }
          }
          if !recent.isEmpty {
            Text("Recent Kick channels").font(.headline)
            ForEach(recent.split(separator: ",").map(String.init), id: \.self) { slug in
              Button(slug) { open(slug) }
            }
          }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle("Kick")
      .fullScreenCover(item: $playback) { target in PlatformLivePlayerView(target: target) }
    }
  }

  private func lookup() async {
    let requested = query
    isLoading = true
    errorMessage = nil
    channel = nil
    defer { isLoading = false }
    do {
      let found = try await KickPlaybackService.channel(requested)
      guard !Task.isCancelled, query == requested else { return }
      channel = found
    } catch {
      guard !Task.isCancelled, query == requested else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func open(_ slug: String) {
    var slugs = recent.split(separator: ",").map(String.init).filter { $0 != slug }
    slugs.insert(slug, at: 0)
    recent = slugs.prefix(12).joined(separator: ",")
    playback = PlatformLiveTarget(platform: .kick, channel: slug)
  }
}
