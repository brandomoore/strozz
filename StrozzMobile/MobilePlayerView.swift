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
  let session: MobilePlaybackSession
  @State private var hideChat = false
  @State private var fullscreen = false
  @State private var windowScene: UIWindowScene?
  @State private var rotationError: String?
  @State private var collapseOffset: CGFloat = 0
  @State private var isDeparting = false
  @Environment(\.themePalette) private var palette
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let model = session.model
    GeometryReader { geometry in
      let layout = MobilePlayerLayout.resolve(
        size: CGSize(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom),
        isPhone: UIDevice.current.userInterfaceIdiom == .phone, hideChat: hideChat || fullscreen,
        phoneLandscape: verticalSizeClass == .compact)
      let video = MobileVideoView(
        model: model, channel: channel, hideChat: $hideChat, isFullscreen: layout == .videoOnly,
        videoController: session.videoController, onCollapse: session.collapse, onClose: session.close,
        onCollapseDragChanged: updateCollapseDrag,
        onCollapseDragEnded: endCollapseDrag,
        onFullscreen: { toggleFullscreen(exiting: layout == .videoOnly) },
        onScene: { windowScene = $0 })
      VStack(spacing: 0) {
        if layout == .sideBySide {
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              video
              MobileStreamDetails(channel: channel, model: model)
              MobileWatchRewardsStatus(tracker: session.watchTracker)
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
            MobileWatchRewardsStatus(tracker: session.watchTracker)
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
          }
        }
      }
      .background(palette.chatSideSurface)
      .offset(y: collapseOffset)
      .onChange(of: session.pictureInPictureState) { _, state in
        if state == .starting || state == .active {
          guard !isDeparting else { return }
          isDeparting = true
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
            collapseOffset = reduceMotion ? 0
              : geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
          } completion: {
            if isDeparting { session.collapseAnimationCompleted() }
          }
        } else if state == .inline {
          isDeparting = false
          resetCollapseDrag()
        }
      }
    }
    .alert("Picture in Picture", isPresented: Binding(
      get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } }
    )) {
      Button("OK") { session.errorMessage = nil }
    } message: { Text(session.errorMessage ?? "") }
    .alert("Display rotation", isPresented: Binding(
      get: { rotationError != nil }, set: { if !$0 { rotationError = nil } }
    )) {
      Button("OK") { rotationError = nil }
    } message: { Text(rotationError ?? "") }
  }

  private func updateCollapseDrag(_ translation: CGSize) {
    guard session.pictureInPictureState == .inline, !isDeparting else { return }
    if translation.height > abs(translation.width) {
      collapseOffset = max(0, translation.height)
    }
  }

  private func endCollapseDrag(_ translation: CGSize) {
    if MobilePlayerCollapseGesture.shouldCollapse(translation: translation) {
      session.collapse()
    }
    if session.pictureInPictureState == .inline { resetCollapseDrag() }
  }

  private func resetCollapseDrag() {
    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
      collapseOffset = 0
    }
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
  let videoController: MobileVideoController
  let onCollapse: () -> Void
  let onClose: () -> Void
  let onCollapseDragChanged: (CGSize) -> Void
  let onCollapseDragEnded: (CGSize) -> Void
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
      MobilePlayerSurface(controller: videoController, onScene: onScene)
        .id(ObjectIdentifier(videoController))
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
          onCollapse: onCollapse,
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
    .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
      .onChanged { onCollapseDragChanged($0.translation) }
      .onEnded { onCollapseDragEnded($0.translation) })
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
  let controller: MobileVideoController
  let onScene: (UIWindowScene) -> Void

  func makeUIViewController(context: Context) -> MobileVideoController {
    controller.onScene = onScene
    return controller
  }

  func updateUIViewController(_ controller: MobileVideoController, context: Context) {
    controller.onScene = onScene
  }
}

final class MobileVideoController: UIViewController {
  // AVPlayerViewController has no public API to start PiP from a custom gesture.
  // Keep one player layer alive across presentation changes for AVKit's PiP controller.
  let playerLayer = AVPlayerLayer()
  var onScene: ((UIWindowScene) -> Void)?
  var onReady: ((Bool, AVPlayer) -> Void)?
  var onAppear: (() -> Void)?
  private var observation: NSKeyValueObservation?

  var player: AVPlayer? {
    get { playerLayer.player }
    set { playerLayer.player = newValue }
  }

  init() {
    super.init(nibName: nil, bundle: nil)
    observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self, let player = self.player else { return }
        self.onReady?(self.playerLayer.isReadyForDisplay, player)
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    view = UIView()
    view.isUserInteractionEnabled = false
    view.layer.addSublayer(playerLayer)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = view.bounds
    CATransaction.commit()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if let scene = view.window?.windowScene { onScene?(scene) }
    onAppear?()
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
