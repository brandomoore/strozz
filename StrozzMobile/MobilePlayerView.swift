import AVKit
import SwiftUI

enum MobilePlayerLayout: Equatable {
  case portrait, sideBySide, videoOnly

  static func resolve(size: CGSize, isPhone: Bool, hideChat: Bool, phoneLandscape: Bool = false) -> Self {
    if hideChat || (isPhone && phoneLandscape) { return .videoOnly }
    return size.width >= 800 && size.width > size.height ? .sideBySide : .portrait
  }
}

struct MobilePlayerView: View {
  let channel: FollowedChannel
  @State private var model: MobilePlaybackModel
  @State private var hideChat = false
  @State private var fullscreen = false
  @State private var windowScene: UIWindowScene?
  @State private var rotationError: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.themePalette) private var palette
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(TwitchAuthSession.self) private var auth
  @Environment(TwitchWatchRewardsSession.self) private var rewards
  @State private var watchTracker = TwitchWatchTracker()

  init(channel: FollowedChannel, model: MobilePlaybackModel = MobilePlaybackModel()) {
    self.channel = channel
    _model = State(initialValue: model)
  }

  var body: some View {
    GeometryReader { geometry in
      let layout = MobilePlayerLayout.resolve(
        size: CGSize(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom),
        isPhone: UIDevice.current.userInterfaceIdiom == .phone, hideChat: hideChat || fullscreen,
        phoneLandscape: verticalSizeClass == .compact)
      let video = MobileVideoView(
        model: model, channel: channel, hideChat: $hideChat, isFullscreen: layout == .videoOnly,
        onClose: { dismiss() }, onFullscreen: { toggleFullscreen(exiting: layout == .videoOnly) },
        onScene: { windowScene = $0 })
      VStack(spacing: 0) {
        if layout == .sideBySide {
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              video
              MobileStreamDetails(channel: channel, model: model)
              MobileWatchRewardsStatus(tracker: watchTracker)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
              .frame(width: min(380, geometry.size.width * 0.36))
          }
        } else {
          video
            .frame(maxHeight: layout == .videoOnly ? .infinity
                   : min(geometry.size.width * 9 / 16, geometry.size.height * 0.42))
          if layout == .portrait {
            MobileStreamDetails(channel: channel, model: model)
            MobileWatchRewardsStatus(tracker: watchTracker)
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
          }
        }
      }
    }
    .background(palette.chatSideSurface)
    .task { model.start(channel: channel.login) }
    .task {
      while !Task.isCancelled {
        if auth.isAuthenticated, let userID = auth.userID, let item = model.player.currentItem {
          watchTracker.update(.init(
            target: .init(channel: channel.login, userID: userID, itemID: ObjectIdentifier(item)),
            uptime: ProcessInfo.processInfo.systemUptime, playhead: item.currentTime().seconds,
            rate: Double(model.player.rate),
            ready: item.status == .readyToPlay && !model.isLoading && model.errorMessage == nil,
            playing: model.player.timeControlStatus == .playing,
            foreground: scenePhase == .active, visible: model.isActive,
            userPaused: model.isPaused, muted: model.player.isMuted || model.player.volume == 0),
            session: rewards)
        } else { watchTracker.stop() }
        do { try await Task.sleep(for: .seconds(1)) } catch { break }
      }
      watchTracker.stop()
    }
    .onDisappear { model.stop() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { model.suspend() }
      else if phase == .active { model.resume() }
    }

    .alert("Display rotation", isPresented: Binding(
      get: { rotationError != nil }, set: { if !$0 { rotationError = nil } }
    )) {
      Button("OK") { rotationError = nil }
    } message: { Text(rotationError ?? "") }
  }

  private func toggleFullscreen(exiting: Bool) {
    fullscreen = !exiting
    hideChat = false
    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
    guard let windowScene else {
      rotationError = "Could not rotate this window. You can still rotate your device."
      return
    }
    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: exiting ? .portrait : .landscapeRight)) { error in
      Task { @MainActor in rotationError = error.localizedDescription }
    }
  }
}

struct MobileWatchRewardsStatus: View {
  let tracker: TwitchWatchTracker

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let error = tracker.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
      HStack(spacing: 16) {
        if let points = tracker.channelRewards.points {
          Text("\(points.balance.formatted()) points").font(.caption)
        }
        if let streak = tracker.streak { Text("\(streak)-stream watch streak").font(.caption) }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
  }
}

struct MobileVideoView: View {
  let model: MobilePlaybackModel
  let channel: FollowedChannel
  @Binding var hideChat: Bool
  let isFullscreen: Bool
  let onClose: () -> Void
  let onFullscreen: () -> Void
  let onScene: (UIWindowScene) -> Void
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var controlsVisible = true
  @State private var interaction = 0
  @State private var showQuality = false
  @State private var showShare = false
  @State private var showRoutes = false

  private struct HideState: Equatable {
    let interaction: Int
    let held: Bool
  }

  var body: some View {
    let held = model.isPaused || model.presentationState != .ready
      || voiceOver || showQuality || showShare || showRoutes
    ZStack {
      palette.playerBackdrop
      MobilePlayerSurface(player: model.player, onScene: onScene) { ready, player in
        model.displayReady(ready, for: player)
      }
        .id(ObjectIdentifier(model.player))
        .opacity(model.isLoading ? 0 : 1)
        .accessibilityIdentifier("mobile-video-surface")
        .allowsHitTesting(false)
      if (model.isAudioOnly || model.isExternalPlayback) && !model.isLoading {
        Label {
          Text(model.isExternalPlayback ? "Playing with AirPlay" : "Audio only")
        } icon: { Icon(glyph: .volume, size: 24) }
          .padding().background(palette.chromeOpaqueSurface, in: RoundedRectangle(cornerRadius: 12))
          .allowsHitTesting(false)
      }
      Color.clear.contentShape(Rectangle())
        .onTapGesture {
          controlsVisible.toggle()
          interaction += 1
        }
        .accessibilityLabel(controlsVisible ? "Hide playback controls" : "Show playback controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(voiceOver)
        .accessibilityIdentifier("mobile-controls-toggle")
      if model.presentationState == .loading {
        StreamLoadingView(posterURL: channel.thumbnailURL, avatarURL: channel.profileImageURL,
          title: channel.displayName)
          .accessibilityIdentifier("mobile-video-loading")
      }
      if let error = model.errorMessage {
        MobileStatusView(message: error) { model.retry() }
          .background(palette.chromeOpaqueSurface)
      }
      if controlsVisible || held {
        MobilePlayerControls(
          model: model, viewerCount: channel.viewerCount, hideChat: $hideChat, isFullscreen: isFullscreen,
          onClose: onClose,
          onFullscreen: { interaction += 1; onFullscreen() },
          onQuality: { showQuality = true },
          onShare: { showShare = true },
          onInteraction: {
            controlsVisible = true
            interaction += 1
          },
          onRoutes: { presenting in
            showRoutes = presenting
            if presenting { model.prepareForAirPlay() }
          })
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controlsVisible)
    .task(id: HideState(interaction: interaction, held: held)) {
      guard !held else { return }
      do { try await Task.sleep(for: .seconds(4)) } catch { return }
      controlsVisible = false
    }
    .sheet(isPresented: $showQuality) {
      MobileQualitySheet(model: model)
        .presentationDetents([.medium, .large])
    }
    .sheet(isPresented: $showShare) {
      MobileShareSheet(url: URL(string: "https://www.twitch.tv/")!.appendingPathComponent(channel.login))
        .presentationDetents([.medium, .large])
    }
  }
}

struct MobilePlayerSurface: UIViewControllerRepresentable {
  let player: AVPlayer
  let onScene: (UIWindowScene) -> Void
  let onReady: (Bool, AVPlayer) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

  func makeUIViewController(context: Context) -> MobileVideoController {
    let controller = MobileVideoController()
    controller.onScene = onScene
    controller.player = player
    // Keep AVKit rendering, but use the same dedicated-control approach as tvOS.
    controller.showsPlaybackControls = false
    controller.view.isUserInteractionEnabled = false
    controller.allowsPictureInPicturePlayback = false
    context.coordinator.observe(controller)
    return controller
  }

  func updateUIViewController(_ controller: MobileVideoController, context: Context) {
    context.coordinator.onReady = onReady
    controller.onScene = onScene
    if controller.player !== player { controller.player = player }
  }

  static func dismantleUIViewController(_ controller: MobileVideoController, coordinator: Coordinator) {
    // Layout transitions can replace the surface without ending the stream.
    coordinator.observation = nil
    controller.player = nil
  }

  final class MobileVideoController: AVPlayerViewController {
    var onScene: ((UIWindowScene) -> Void)?

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      if let scene = view.window?.windowScene { onScene?(scene) }
    }
  }

  @MainActor
  final class Coordinator {
    var onReady: (Bool, AVPlayer) -> Void
    var observation: NSKeyValueObservation?

    init(onReady: @escaping (Bool, AVPlayer) -> Void) { self.onReady = onReady }

    func observe(_ controller: AVPlayerViewController) {
      observation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] controller, _ in
        Task { @MainActor [weak self, weak controller] in
          guard let controller, let player = controller.player else { return }
          self?.onReady(controller.isReadyForDisplay, player)
        }
      }
    }
  }
}

struct MobileStreamDetails: View {
  let channel: FollowedChannel
  let model: MobilePlaybackModel
  @AppStorage(PersistenceKey.showStreamDuration) private var showStreamDuration = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(channel.displayName).font(.headline)
      Text(channel.title).font(.subheadline).lineLimit(2)
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(model.qualityLabel)
        if showStreamDuration {
          BroadcastUptimeView(startedAt: model.streamStartedAt)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let notice = model.recoveryNotice {
        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      } else if let failure = model.nativeFailure {
        Text("Using standard playback: \(failure)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
