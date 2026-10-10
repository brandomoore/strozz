import AVKit
import SwiftUI

enum MobilePlayerLayout: Equatable {
  case portrait, sideBySide, videoOnly

  static func resolve(size: CGSize, isPhone: Bool, hideChat: Bool, phoneLandscape: Bool = false,
                      showPhoneLandscapeChat: Bool = false) -> Self {
    if isPhone && phoneLandscape { return showPhoneLandscapeChat ? .sideBySide : .videoOnly }
    if hideChat { return .videoOnly }
    return size.width >= 800 && size.width > size.height ? .sideBySide : .portrait
  }
}

enum MobileMiniPlayerLayout {
  struct Placement {
    var width: CGFloat?
    var horizontal: CGFloat = 1
    var vertical: CGFloat = 1
  }

  struct Manipulation {
    var startFrame: CGRect?
    var translation: CGSize = .zero
    var magnification: CGFloat = 1
    var anchor: UnitPoint?

    mutating func update(translation: CGSize?, magnification: CGFloat?, anchor: UnitPoint?) {
      if let translation { self.translation = translation }
      if let magnification { self.magnification = magnification }
      // SwiftUI reprojects startAnchor as the view moves; retain its initial position.
      if self.anchor == nil { self.anchor = anchor }
    }
  }

  static func bounds(in size: CGSize, isPhone: Bool) -> CGRect {
    let bottom: CGFloat = isPhone && size.height > size.width ? 64 : 12
    return CGRect(x: min(12, size.width / 2), y: min(12, size.height / 2),
                  width: max(0, size.width - 24), height: max(0, size.height - bottom - 12))
  }

  static func frame(in size: CGSize, isPhone: Bool, placement: Placement = .init()) -> CGRect {
    let bounds = bounds(in: size, isPhone: isPhone)
    let width = fittedWidth(placement.width ?? (isPhone ? 240 : 320), in: bounds)
    let height = width * 9 / 16
    return CGRect(x: bounds.minX + (bounds.width - width) * placement.horizontal,
                  y: bounds.minY + (bounds.height - height) * placement.vertical,
                  width: width, height: height)
  }

  static let settlingAnimation = Animation.interpolatingSpring(
    mass: 1, stiffness: 180, damping: 28, initialVelocity: 6)

  static func applying(_ manipulation: Manipulation, to frame: CGRect, in size: CGSize, isPhone: Bool,
                       elastic: Bool = false) -> CGRect {
    let bounds = bounds(in: size, isPhone: isPhone)
    let requestedWidth = frame.width * manipulation.magnification
    let clampedWidth = fittedWidth(requestedWidth, in: bounds)
    let width = clampedWidth + resistance(requestedWidth - clampedWidth, limit: elastic ? min(12, clampedWidth / 10) : 0)
    let height = width * 9 / 16
    let anchor = manipulation.anchor ?? .center
    let x = frame.minX + manipulation.translation.width + (frame.width - width) * anchor.x
    let y = frame.minY + manipulation.translation.height + (frame.height - height) * anchor.y
    let minX = min(bounds.minX, bounds.midX - width / 2)
    let maxX = max(bounds.maxX - width, bounds.midX - width / 2)
    let minY = min(bounds.minY, bounds.midY - height / 2)
    let maxY = max(bounds.maxY - height, bounds.midY - height / 2)
    let clampedX = min(max(x, minX), maxX)
    let clampedY = min(max(y, minY), maxY)
    return CGRect(
      x: clampedX + resistance(x - clampedX, limit: elastic ? min(8, max(0, minX)) : 0),
      y: clampedY + resistance(y - clampedY, limit: elastic ? min(8, max(0, minY)) : 0),
      width: width, height: height)
  }

  static func released(_ manipulation: Manipulation, from frame: CGRect, velocity: CGSize,
                       in size: CGSize, isPhone: Bool, reduceMotion: Bool) -> CGRect {
    let speed = hypot(velocity.width, velocity.height)
    guard !reduceMotion, manipulation.anchor == nil, speed > 120 else {
      return applying(manipulation, to: frame, in: size, isPhone: isPhone)
    }
    var release = manipulation
    let distance = min((speed - 120) * 0.12, min(140, min(size.width, size.height) * 0.24))
    release.translation.width += velocity.width / speed * distance
    release.translation.height += velocity.height / speed * distance
    var settled = applying(release, to: frame, in: size, isPhone: isPhone)
    let travel = manipulation.translation
    if abs(velocity.height) >= 1000, abs(velocity.height) >= abs(velocity.width) * 1.5,
       abs(travel.height) >= 40, abs(travel.height) > abs(travel.width),
       travel.height * velocity.height > 0 {
      let bounds = bounds(in: size, isPhone: isPhone)
      settled.origin.y = velocity.height < 0 ? bounds.minY : bounds.maxY - settled.height
    }
    return settled
  }

  private static func resistance(_ excess: CGFloat, limit: CGFloat) -> CGFloat {
    guard limit > 0 else { return 0 }
    let distance = abs(excess) * 0.35
    return (excess < 0 ? -1 : 1) * limit * distance / (limit + distance)
  }

  static func placement(for frame: CGRect, in size: CGSize, isPhone: Bool, previous: Placement) -> Placement {
    let bounds = bounds(in: size, isPhone: isPhone)
    return Placement(
      width: frame.width,
      horizontal: bounds.width > frame.width
        ? min(1, max(0, (frame.minX - bounds.minX) / (bounds.width - frame.width))) : previous.horizontal,
      vertical: bounds.height > frame.height
        ? min(1, max(0, (frame.minY - bounds.minY) / (bounds.height - frame.height))) : previous.vertical)
  }

  private static func fittedWidth(_ width: CGFloat, in bounds: CGRect) -> CGFloat {
    let maximum = min(bounds.width, bounds.height * 16 / 9)
    return min(maximum, max(min(160, maximum), width))
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
  @State private var landscapeChatVisible = false
  @State private var chatComposer = MobileChatComposerState()
  @State private var chatScroll = MobileChatScrollState()
  @State private var windowScene: UIWindowScene?
  @State private var rotationError: String?
  @State private var streamDetailsVisible = true
  @State private var collapseProgress: CGFloat = 0
  @State private var miniPlayerPlacement = MobileMiniPlayerLayout.Placement()
  @GestureState private var miniPlayerManipulation = MobileMiniPlayerLayout.Manipulation()
  @Environment(\.themePalette) private var palette
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let model = session.model
    GeometryReader { geometry in
      let isPhone = UIDevice.current.userInterfaceIdiom == .phone
      let phoneLandscape = isPhone && verticalSizeClass == .compact
      let canToggleChat = phoneLandscape || (!isPhone && geometry.size.width >= 800 && geometry.size.width > geometry.size.height)
      let chatHidden = Binding(
        get: { isPhone ? !landscapeChatVisible : hideChat || fullscreen },
        set: { hidden in
          if isPhone { landscapeChatVisible = !hidden }
          else { hideChat = hidden; if !hidden { fullscreen = false } }
        })
      let layout = MobilePlayerLayout.resolve(
        size: CGSize(width: geometry.size.width, height: geometry.size.height + geometry.safeAreaInsets.bottom),
        isPhone: isPhone, hideChat: !isPhone && (hideChat || fullscreen),
        phoneLandscape: phoneLandscape, showPhoneLandscapeChat: landscapeChatVisible)
      let sideChatWidth = min(380, geometry.size.width * (isPhone ? 0.4 : 0.36))
      let chatWidth = layout == .sideBySide ? sideChatWidth : 0
      let videoWidth = geometry.size.width - chatWidth
      let videoHeight = layout == .videoOnly ? geometry.size.height
        : min(videoWidth * 9 / 16, geometry.size.height * (layout == .sideBySide ? 0.75 : 0.42))
      let expanded = CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
      let expandedWindowFrame = expanded.offsetBy(
        dx: geometry.frame(in: .global).minX, dy: geometry.frame(in: .global).minY)
      let restingCompact = MobileMiniPlayerLayout.frame(
        in: geometry.size, isPhone: isPhone, placement: miniPlayerPlacement)
      let compact = MobileMiniPlayerLayout.applying(
        miniPlayerManipulation, to: miniPlayerManipulation.startFrame ?? restingCompact,
        in: geometry.size, isPhone: isPhone,
        elastic: miniPlayerManipulation.startFrame != nil && !reduceMotion)
      let progress = session.isExpanded ? collapseProgress : 1
      let videoFrame = MobileMiniPlayerLayout.interpolate(from: expanded, to: compact, progress: progress)
      ZStack(alignment: .topLeading) {
        palette.chatSideSurface
          .background(palette.playerBackdrop)
          .ignoresSafeArea()
          .opacity(1 - progress)
          .allowsHitTesting(session.isExpanded)
        VStack(spacing: 0) {
          if streamDetailsVisible && session.isExpanded && layout != .videoOnly {
            MobileStreamDetails(channel: channel, model: model)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
          }
          if layout == .portrait {
            Divider()
            MobileChatView(service: model.chat, channel: channel.login,
              composer: chatComposer, scroll: chatScroll, rewards: MobileChatRewardsSummary.snapshot(of: session.watchTracker))
          } else {
            Spacer(minLength: 0)
          }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: streamDetailsVisible)
        .frame(width: videoWidth, height: max(0, geometry.size.height - videoHeight))
        .offset(y: videoHeight + progress * 80)
        .opacity(layout == .videoOnly ? 0 : 1 - progress)
        .allowsHitTesting(session.isExpanded && layout != .videoOnly)
        .accessibilityHidden(!session.isExpanded || layout == .videoOnly)
        if canToggleChat {
          HStack(spacing: 0) {
            Divider()
            MobileChatView(service: model.chat, channel: channel.login,
              composer: chatComposer, scroll: chatScroll, rewards: MobileChatRewardsSummary.snapshot(of: session.watchTracker))
          }
          .frame(width: sideChatWidth, height: geometry.size.height)
          .offset(x: videoWidth + progress * sideChatWidth)
          .opacity(layout == .sideBySide ? 1 - progress : 0)
          .allowsHitTesting(session.isExpanded && layout == .sideBySide)
          .accessibilityHidden(!session.isExpanded || layout != .sideBySide)
        }
        // One mounted AVPlayerLayer changes geometry; neither animation nor native
        // background PiP reparents or replaces the playing surface.
        MobileVideoView(
          model: model, channel: channel, hideChat: chatHidden,
          isFullscreen: isPhone ? phoneLandscape : layout == .videoOnly,
          isMinimized: !session.isExpanded, isManipulating: miniPlayerManipulation.startFrame != nil,
          videoController: session.videoController,
          onCollapse: session.collapse, onClose: session.close, onExpand: session.expand,
          onCollapseDragChanged: { updateCollapseDrag($0, distance: max(120, min(360, compact.midY))) },
          onCollapseDragEnded: endCollapseDrag,
          onFullscreen: { toggleFullscreen(exiting: isPhone ? phoneLandscape : layout == .videoOnly) },
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
          },
          onControlsVisibilityChange: { streamDetailsVisible = $0 },
          showsChatToggle: canToggleChat)
          .frame(width: videoFrame.width, height: videoFrame.height)
          .clipShape(RoundedRectangle(cornerRadius: progress * 14))
          .overlay {
            RoundedRectangle(cornerRadius: progress * 14)
              .strokeBorder(palette.chromeOnOpaque.opacity(
                progress * (miniPlayerManipulation.startFrame == nil ? 0.2 : 0.32)), lineWidth: 1)
              .allowsHitTesting(false)
          }
          .background {
            RoundedRectangle(cornerRadius: progress * 14)
              .fill(palette.playerBackdrop)
              .shadow(color: palette.playerBackdrop.opacity(0.28),
                      radius: miniPlayerManipulation.startFrame == nil ? 8 : 18,
                      y: miniPlayerManipulation.startFrame == nil ? 3 : 8)
              .opacity(progress)
              .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: miniPlayerManipulation.startFrame == nil)
          }
          .simultaneousGesture(
            miniPlayerGesture(from: restingCompact, in: geometry.size, isPhone: isPhone,
                              origin: geometry.frame(in: .global).origin),
            including: session.isExpanded ? .subviews : .all)
          .position(x: videoFrame.midX, y: videoFrame.midY)
          .animation(
            reduceMotion || miniPlayerManipulation.startFrame != nil ? nil : MobileMiniPlayerLayout.settlingAnimation,
            value: miniPlayerManipulation.startFrame == nil)
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

  private func miniPlayerGesture(from frame: CGRect, in size: CGSize, isPhone: Bool, origin: CGPoint) -> some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .simultaneously(with: MagnifyGesture())
      .updating($miniPlayerManipulation) { value, state, _ in
        if state.startFrame == nil {
          // Catch a gliding player where it is displayed, not at its animation's destination.
          state.startFrame = session.videoController.presentedFrame?.offsetBy(dx: -origin.x, dy: -origin.y) ?? frame
        }
        state.update(translation: value.first?.translation, magnification: value.second?.magnification,
                     anchor: value.second?.startAnchor)
      }
      .onEnded { value in
        var manipulation = miniPlayerManipulation
        manipulation.update(translation: value.first?.translation, magnification: value.second?.magnification,
                            anchor: value.second?.startAnchor)
        let moved = MobileMiniPlayerLayout.released(
          manipulation, from: manipulation.startFrame ?? frame, velocity: value.first?.velocity ?? .zero,
          in: size, isPhone: isPhone, reduceMotion: reduceMotion)
        miniPlayerPlacement = MobileMiniPlayerLayout.placement(
          for: moved, in: size, isPhone: isPhone, previous: miniPlayerPlacement)
      }
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
    landscapeChatVisible = false
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

struct MobileVideoView: View {
  let model: MobilePlaybackModel
  let channel: FollowedChannel
  @Binding var hideChat: Bool
  let isFullscreen: Bool
  let isMinimized: Bool
  let isManipulating: Bool
  let videoController: MobileVideoController
  let onCollapse: () -> Void
  let onClose: () -> Void
  let onExpand: () -> Void
  let onCollapseDragChanged: (CGSize) -> Void
  let onCollapseDragEnded: (CGSize) -> Void
  let onFullscreen: () -> Void
  let onScene: (UIWindowScene) -> Void
  let onLayout: (CGRect) -> Void
  var onControlsVisibilityChange: ((Bool) -> Void)? = nil
  var showsChatToggle = false
  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
      || voiceOver || showQuality || showShare || showRoutes || (isMinimized && isManipulating)
    let showsControls = controlsVisible || held
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
          if isMinimized && showsControls { onExpand() }
          else { controlsVisible.toggle(); interaction += 1 }
        }
        .accessibilityLabel(isMinimized && showsControls ? "Expand player"
          : showsControls ? "Hide playback controls" : "Show playback controls")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isMinimized ? Text("Drag to move. Pinch to resize.") : Text(""))
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
      if isMinimized && showsControls {
        VStack {
          HStack {
            Button(action: onClose) { Icon(glyph: .x, size: 18).frame(width: 44, height: 44) }
              .accessibilityLabel("Close player")
              .modifier(MobileControlSurface(isVideoOverlay: true))
            Spacer(minLength: 0)
            Button {
              controlsVisible = true
              interaction += 1
              model.togglePlayPause()
            } label: {
              Icon(glyph: model.isPaused ? .playerPlayFilled : .playerPauseFilled, size: 18)
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.isPaused ? "Play" : "Pause")
            .accessibilityIdentifier("mobile-mini-play-pause")
            .disabled(model.isLoading || model.errorMessage != nil)
            .modifier(MobileControlSurface(isVideoOverlay: true))
          }
          Spacer(minLength: 0)
          if let error = model.errorMessage {
            Text(error).font(.caption).lineLimit(2).padding(4)
              .modifier(MobileControlSurface(isVideoOverlay: true))
              .allowsHitTesting(false)
          }
        }
        .padding(6)
        .buttonStyle(.plain)
        .background {
          MobileMiniPlayerControlScrim(hasError: model.errorMessage != nil,
                                       reduceTransparency: reduceTransparency)
        }
      } else if !isMinimized && showsControls {
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
          },
          showsChatToggle: showsChatToggle)
      }
    }
    .simultaneousGesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
      .onChanged { onCollapseDragChanged($0.translation) }
      .onEnded { onCollapseDragEnded($0.translation) },
      including: isMinimized ? .subviews : .all)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controlsVisible)
    .onChange(of: showsControls, initial: true) { _, visible in
      onControlsVisibilityChange?(visible)
    }
    .onChange(of: isMinimized) { _, _ in
      controlsVisible = true
      interaction += 1
    }
    .onChange(of: isManipulating) { _, _ in
      guard isMinimized else { return }
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

  var presentedFrame: CGRect? {
    guard let window = viewIfLoaded?.window else { return nil }
    if let layer = playerLayer.presentation(), let windowLayer = window.layer.presentation() {
      return layer.convert(layer.bounds, to: windowLayer)
    }
    return playerLayer.convert(playerLayer.bounds, to: window.layer)
  }

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

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      CachedAsyncImage(url: channel.profileImageURL) { image in
        image.resizable().scaledToFill()
      } placeholder: { Circle().fill(.quaternary) }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(channel.displayName).font(.headline)
        Text(channel.title).font(.subheadline).lineLimit(2)
        if !channel.gameName.isEmpty {
          Text(channel.gameName).font(.caption).foregroundStyle(.secondary)
        }
        if let notice = model.recoveryNotice {
          Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else if let failure = model.nativeFailure {
          Text("Using standard playback: \(failure)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mobile-stream-details")
  }
}
