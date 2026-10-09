import AVKit
import SwiftUI

enum MobilePlayerLayout: Equatable {
  case portrait, sideBySide, videoOnly

  static func resolve(size: CGSize, isPhone: Bool, hideChat: Bool, phoneLandscape: Bool = false) -> Self {
    if hideChat || (isPhone && phoneLandscape) { return .videoOnly }
    return size.width >= 800 && size.width > size.height ? .sideBySide : .portrait
  }
}

enum MobileMiniPlayerLayout {
  static func frame(in size: CGSize, isPhone: Bool) -> CGRect {
    let width = min(isPhone ? 240 : 320, max(0, size.width - 24))
    let height = min(width * 9 / 16, max(0, size.height - 24))
    let bottom: CGFloat = isPhone && size.height > size.width ? 64 : 12
    return CGRect(x: max(12, size.width - width - 12),
                  y: max(12, size.height - height - bottom), width: width, height: height)
  }

  static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
    let progress = min(1, max(0, progress))
    return CGRect(x: start.minX + (end.minX - start.minX) * progress,
                  y: start.minY + (end.minY - start.minY) * progress,
                  width: start.width + (end.width - start.width) * progress,
                  height: start.height + (end.height - start.height) * progress)
  }
}

struct MobilePlayerView: View {
  let channel: FollowedChannel
  let session: MobilePlaybackSession
  @State private var hideChat = false
  @State private var fullscreen = false
  @State private var windowScene: UIWindowScene?
  @State private var rotationError: String?
  @State private var collapseProgress: CGFloat = 0
  @Environment(\.themePalette) private var palette
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let model = session.model
    GeometryReader { geometry in
      let isPhone = UIDevice.current.userInterfaceIdiom == .phone
      let layout = MobilePlayerLayout.resolve(
        size: CGSize(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom),
        isPhone: isPhone, hideChat: hideChat || fullscreen,
        phoneLandscape: verticalSizeClass == .compact)
      let chatWidth = layout == .sideBySide ? min(380, geometry.size.width * 0.36) : 0
      let videoWidth = geometry.size.width - chatWidth
      let videoHeight = layout == .videoOnly ? geometry.size.height
        : min(videoWidth * 9 / 16, geometry.size.height * (layout == .sideBySide ? 0.75 : 0.42))
      let expanded = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
      let expandedWindowFrame = expanded.offsetBy(
        dx: geometry.frame(in: .global).minX, dy: geometry.frame(in: .global).minY)
      let compact = MobileMiniPlayerLayout.frame(in: geometry.size, isPhone: isPhone)
      let progress = session.isExpanded ? collapseProgress : 1
      let videoFrame = MobileMiniPlayerLayout.interpolate(from: expanded, to: compact, progress: progress)
      ZStack(alignment: .topLeading) {
        palette.chatSideSurface
          .background(palette.playerBackdrop)
          .ignoresSafeArea()
          .opacity(1 - progress)
          .allowsHitTesting(session.isExpanded)
        VStack(spacing: 0) {
          MobileStreamDetails(channel: channel, model: model)
          MobileWatchRewardsStatus(tracker: session.watchTracker)
          if layout == .portrait {
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
          } else {
            Spacer(minLength: 0)
          }
        }
        .frame(width: videoWidth, height: max(0, geometry.size.height - videoHeight))
        .offset(y: videoHeight + progress * 80)
        .opacity(layout == .videoOnly ? 0 : 1 - progress)
        .allowsHitTesting(session.isExpanded && layout != .videoOnly)
        .accessibilityHidden(!session.isExpanded || layout == .videoOnly)
        if layout == .sideBySide {
          HStack(spacing: 0) {
            Divider()
            MobileChatView(service: model.chat, channel: channel.login)
          }
          .frame(width: chatWidth, height: geometry.size.height)
          .offset(x: videoWidth + progress * chatWidth)
          .opacity(1 - progress)
          .allowsHitTesting(session.isExpanded)
          .accessibilityHidden(!session.isExpanded)
        }
        // One mounted AVPlayerLayer changes geometry; neither animation nor native
        // background PiP reparents or replaces the playing surface.
        MobileVideoView(
          model: model, channel: channel, hideChat: $hideChat, isFullscreen: layout == .videoOnly,
          isMinimized: !session.isExpanded, videoController: session.videoController,
          onCollapse: session.collapse, onClose: session.close, onExpand: session.expand,
          onCollapseDragChanged: { updateCollapseDrag($0, distance: max(120, min(360, compact.midY))) },
          onCollapseDragEnded: endCollapseDrag,
          onFullscreen: { toggleFullscreen(exiting: layout == .videoOnly) },
          onScene: { windowScene = $0 },
          onLayout: { [weak session] frame in
            guard let session else { return }
            if session.isExpanded,
              abs(frame.minX - expandedWindowFrame.minX) < 1,
              abs(frame.minY - expandedWindowFrame.minY) < 1,
              abs(frame.width - expandedWindowFrame.width) < 1,
              abs(frame.height - expandedWindowFrame.height) < 1 {
              session.playerDidLayoutExpandedSurface()
            }
          })
          .frame(width: videoFrame.width, height: videoFrame.height)
          .clipShape(RoundedRectangle(cornerRadius: progress * 14))
          .overlay {
            RoundedRectangle(cornerRadius: progress * 14)
              .strokeBorder(palette.chromeOnOpaque.opacity(progress * 0.2), lineWidth: 1)
              .allowsHitTesting(false)
          }
          .position(x: videoFrame.midX, y: videoFrame.midY)
      }
      .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: session.isExpanded)
      .onChange(of: session.isExpanded) { _, _ in collapseProgress = 0 }
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

  private func updateCollapseDrag(_ translation: CGSize, distance: CGFloat) {
    guard session.isExpanded else { return }
    if translation.height > abs(translation.width) {
      collapseProgress = min(1, max(0, translation.height / distance))
    }
  }

  private func endCollapseDrag(_ translation: CGSize) {
    guard session.isExpanded else { return }
    if MobilePlayerCollapseGesture.shouldCollapse(translation: translation) {
      session.collapse()
    }
    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
      collapseProgress = 0
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
  let isMinimized: Bool
  let videoController: MobileVideoController
  let onCollapse: () -> Void
  let onClose: () -> Void
  let onExpand: () -> Void
  let onCollapseDragChanged: (CGSize) -> Void
  let onCollapseDragEnded: (CGSize) -> Void
  let onFullscreen: () -> Void
  let onScene: (UIWindowScene) -> Void
  let onLayout: (CGRect) -> Void
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
      MobilePlayerSurface(controller: videoController, onScene: onScene, onLayout: onLayout)
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
          if isMinimized { onExpand() }
          else { controlsVisible.toggle(); interaction += 1 }
        }
        .accessibilityLabel(isMinimized ? "Expand player"
          : controlsVisible ? "Hide playback controls" : "Show playback controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityHidden(voiceOver && !isMinimized)
        .accessibilityIdentifier(isMinimized ? "mobile-expand-player" : "mobile-controls-toggle")
      if model.presentationState == .loading {
        if isMinimized {
          ProgressView().accessibilityLabel("Loading stream").allowsHitTesting(false)
        } else {
          StreamLoadingView(posterURL: channel.thumbnailURL, avatarURL: channel.profileImageURL,
            title: channel.displayName)
            .accessibilityIdentifier("mobile-video-loading")
        }
      }
      if let error = model.errorMessage, !isMinimized {
        MobileStatusView(message: error) { model.retry() }
          .background(palette.chromeOpaqueSurface)
      }
      if isMinimized {
        VStack {
          HStack {
            Button(action: onClose) { Icon(glyph: .x, size: 18).frame(width: 44, height: 44) }
              .accessibilityLabel("Close player")
              .modifier(MobileControlSurface())
            Spacer(minLength: 0)
            Button(action: model.togglePlayPause) {
              Icon(glyph: model.isPaused ? .playerPlayFilled : .playerPauseFilled, size: 18)
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isPaused ? "Play" : "Pause")
            .accessibilityIdentifier("mobile-mini-play-pause")
            .disabled(model.isLoading || model.errorMessage != nil)
            .modifier(MobileControlSurface())
          }
          Spacer(minLength: 0)
          if let error = model.errorMessage {
            Text(error).font(.caption).lineLimit(2).padding(4)
              .modifier(MobileControlSurface())
              .allowsHitTesting(false)
          }
        }
        .padding(6)
        .buttonStyle(.plain)
      } else if controlsVisible || held {
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
    .onChange(of: isMinimized) { _, _ in
      controlsVisible = true
      interaction += 1
    }
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
  let onLayout: (CGRect) -> Void

  func makeUIViewController(context: Context) -> MobileVideoController {
    controller.onScene = onScene
    controller.onLayout = onLayout
    return controller
  }

  func updateUIViewController(_ controller: MobileVideoController, context: Context) {
    controller.onScene = onScene
    controller.onLayout = onLayout
  }
}

final class MobileVideoController: UIViewController {
  // Share one layer between the animated in-app player and AVKit's native PiP.
  let playerLayer = AVPlayerLayer()
  var onScene: ((UIWindowScene) -> Void)?
  var onLayout: ((CGRect) -> Void)?
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
    // SwiftUI positions ancestors after this layout callback. AVKit needs the
    // committed window-relative destination, not just the layer's new bounds.
    CATransaction.setCompletionBlock { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let window = self.viewIfLoaded?.window else { return }
        self.onLayout?(self.playerLayer.convert(self.playerLayer.bounds, to: window.layer))
      }
    }
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
