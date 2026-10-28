import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MultiviewChrome {
  static let idleDelay: Duration = .seconds(10)
  private(set) var isVisible = true
  private let delay: Duration
  private let sleep: @MainActor (Duration) async throws -> Void
  @ObservationIgnored private var hideTask: Task<Void, Never>?

  init(delay: Duration = idleDelay,
       sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.delay = delay
    self.sleep = sleep
  }

  func reveal() {
    hideTask?.cancel()
    isVisible = true
    let delay = delay
    let sleep = sleep
    hideTask = Task { [weak self] in
      do {
        try await sleep(delay)
        try Task.checkCancellation()
      } catch { return }
      guard let self else { return }
      withAnimation(.easeOut(duration: 0.4)) { self.isVisible = false }
    }
  }

  func cancel() {
    hideTask?.cancel()
    hideTask = nil
  }
}

/// Plays up to six live channels at once. The tvOS focus engine selects one
/// pane as "active": that pane is unmuted and highlighted while every other pane
/// runs muted. Featured and Spotlight pin a primary independently of audio;
/// Equal gives the pictures equal height. Play/Pause reveals bottom controls.
/// Changing the layout or primary retains every mounted player.
struct MultiviewPlayerView: View {
  let channels: [FollowedChannel]
  /// All currently-live channels, used to offer additions while watching.
  let availableChannels: [FollowedChannel]
  /// Shared account context for each retained normal-player instance.
  let auth: TwitchAuthSession
  let goLive: GoLiveWatcher?
  /// Called when a pane is escalated to the full player, so the host can record
  /// it in watch history. Expansion resizes the existing player in place.
  var onWatch: (FollowedChannel) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.multiviewLineup) private var lineup
  @State private var watchTracker = TwitchWatchTracker()
  @State private var controller: MultiviewController
  @FocusState private var focus: MultiviewFocusTarget?
  @Namespace private var paneFocusScope
  /// Drives the auto-hiding focused-pane metadata: true right after any focus
  /// change or remote interaction, then fades out so the video wall stays clean.
  @State private var chrome = MultiviewChrome()
  @State private var showingAddPicker = false
  @State private var profilePane: MultiviewPane?
  @State private var profileAudioState: MultiviewController.AudioState?
  @State private var profileWatchRequest: (pane: MultiviewPane, channel: FollowedChannel)?
  @State private var showingControls = false
  @State private var showingLayoutPicker = false
  @State private var controlsHeight: CGFloat = 0
  /// Last pane that held focus, so dismissing the HUD restores focus to it.
  @State private var lastPaneID: String?
  /// A brief on-appear coach hint explaining the hidden controls.
  @State private var hintVisible = true
  @State private var hintHideTask: Task<Void, Never>?

  init(
    channels: [FollowedChannel],
    availableChannels: [FollowedChannel],
    auth: TwitchAuthSession,
    goLive: GoLiveWatcher?,
    onWatch: @escaping (FollowedChannel) -> Void,
    controller: MultiviewController? = nil
  ) {
    self.channels = channels
    self.availableChannels = availableChannels
    self.auth = auth
    self.goLive = goLive
    self.onWatch = onWatch
    _controller = State(initialValue: controller ?? MultiviewController(channels: channels,
      muted: ProcessInfo.processInfo.environment["STROZZ_MUTE_PLAYBACK"] == "1"))
  }

  private var focusedPaneID: String? {
    switch focus {
    case .pane(let id), .profile(let id), .remove(let id): return id
    default: return nil
    }
  }

  private var addableChannels: [FollowedChannel] {
    // Keyed on `channelKey`, not `id`: a streamer already on screen can appear
    // in the pool under a different id (see `FollowedChannel.channelKey`) and
    // would otherwise still be offered.
    let present = Set(controller.panes.map(\.channel.channelKey))
    return availableChannels.filter { $0.isLive && !present.contains($0.channelKey) }
  }

  var body: some View {
    GeometryReader { geometry in
      let bottomPadding = max(28, geometry.safeAreaInsets.bottom)
      ZStack(alignment: .bottom) {
        palette.videoControlScrim
        MultiviewVideoStage(controller: controller,
          bottomClearance: showingControls ? controlsHeight + bottomPadding + 24 : 0) { pane in
          paneView(pane, style: pane.qualityTier == .thumbnail || pane.qualityTier == .hidden ? .compact : .full)
        }
        .focusScope(paneFocusScope)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(showingControls)

        if showingControls {
          MultiviewControls(layout: controller.layout, showsLayoutPicker: showingLayoutPicker,
            canBrowse: lineup != nil || (controller.canAddPane && !addableChannels.isEmpty),
            hasLineup: lineup != nil, focus: $focus,
            onLayout: { showingLayoutPicker = true },
            onSelectLayout: { layout in
              controller.setLayout(layout)
              showingLayoutPicker = false
              bumpChrome()
            }, onBrowse: {
              if let lineup { lineup.browse() } else { showingAddPicker = true }
            }, onDone: hideControls)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
            .padding(.horizontal, max(36, max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing)))
            .padding(.bottom, bottomPadding)
            .transition(.opacity)
        } else if hintVisible && controller.expandedPaneID == nil {
          revealHint
            .padding(.bottom, bottomPadding)
            .transition(.opacity)
        }
      }
    }
    .ignoresSafeArea()
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      controller.reduceMotion = reduceMotion
      controller.start()
      if focus == nil {
        focus = controller.panes.first.map { .pane($0.id) }
      }
      bumpChrome()
      showHintBriefly()
    }
    .onChange(of: focus) { _, newValue in
      guard !controller.isBrowsing, !controller.isTransitioning, !showingControls,
        profileAudioState == nil else { return }
      if case let .pane(id) = newValue {
        if controller.audiblePaneID != id { watchTracker.stop() }
        lastPaneID = id
        controller.setAudiblePane(id)
      }
      bumpChrome()
    }
    .onPlayPauseCommand {
      guard !controller.isBrowsing else { return }
      // Play/Pause toggles the controls HUD — a single, discoverable,
      // non-directional button that never fires while navigating the grid.
      if let expanded = controller.expandedPane {
        expanded.presentation.playPauseRequests &+= 1
      } else if showingControls {
        hideControls()
      } else {
        revealControls()
      }
    }
    .onMoveCommand { direction in
      guard !controller.isBrowsing else { return }
      guard let expanded = controller.expandedPane else { bumpChrome(); return }
      expanded.presentation.moveDirection = direction
      expanded.presentation.moveRequests &+= 1
    }
    .onDisappear {
      watchTracker.stop()
      chrome.cancel()
      hintHideTask?.cancel()
      controller.teardown()
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .task {
      while !Task.isCancelled {
        updateWatchRewards()
        do { try await Task.sleep(for: .seconds(1)) }
        catch { break }
      }
      watchTracker.stop()
    }
    .onChange(of: scenePhase) { _, phase in
      updateWatchRewards()
    }
    .onChange(of: controller.expandedPaneID) { previous, current in
      watchTracker.stop()
      if current == nil {
        bumpChrome()
      } else {
        focus = nil
        showingControls = false
        showingLayoutPicker = false
      }
    }
    .onChange(of: controller.focusRestoreRequest) { _, _ in
      guard controller.expandedPaneID == nil else { return }
      focus = controller.restoredPaneID.map { .pane($0) }
    }
    .onChange(of: controller.isBrowsing) { _, browsing in
      UIApplication.shared.isIdleTimerDisabled = !browsing
      watchTracker.stop()
      if browsing {
        focus = nil
        showingControls = false
        showingLayoutPicker = false
        hintVisible = false
        chrome.cancel()
        hintHideTask?.cancel()
      } else {
        bumpChrome()
      }
    }
    .onChange(of: reduceMotion) { _, enabled in controller.reduceMotion = enabled }
    .onChange(of: controller.expandedPane?.model.isSleeping) { _, _ in
      controller.synchronizeExpandedSleep()
    }
    .onChange(of: showingAddPicker) { _, _ in
      watchTracker.stop()
    }
    .onChange(of: profilePane?.id) { _, _ in watchTracker.stop() }
    .onChange(of: lineup?.playbackRequest) { _, _ in profilePane = nil }
    .onExitCommand {
      guard !controller.isBrowsing else { return }
      if let expanded = controller.expandedPane {
        expanded.model.playbackTelemetry.recordEvent("multiview_exit_received")
        expanded.presentation.exitRequests &+= 1
      } else if showingLayoutPicker {
        showingLayoutPicker = false
      } else if showingControls {
        hideControls()
      } else {
        if let lineup { lineup.browse() } else { dismiss() }
      }
    }
    .fullScreenCover(isPresented: $showingAddPicker) {
      MultiviewAddView(
        channels: addableChannels,
        onPick: { add($0) },
        onCancel: { showingAddPicker = false }
      )
    }
    .sheet(item: $profilePane, onDismiss: finishProfile) { pane in
      ChannelPageView(target: ChannelPageTarget(channel: pane.channel)) { channel in
        profileWatchRequest = (pane, channel)
        profilePane = nil
      }
      .environment(\.themePalette, palette)
    }
  }

  // MARK: Controls

  private func updateWatchRewards() {
    guard !controller.isBrowsing, scenePhase == .active, controller.expandedPaneID == nil, !showingAddPicker, profilePane == nil,
      auth.isAuthenticated, let userID = auth.userID,
      let pane = controller.panes.first(where: { $0.id == controller.audiblePaneID }),
      pane.isTwitchLive,
      let item = pane.player.currentItem else {
      watchTracker.stop()
      return
    }
    let playback = TwitchWatchPlayback(
      target: .init(channel: pane.channel.login, userID: userID, itemID: ObjectIdentifier(item)),
      uptime: ProcessInfo.processInfo.systemUptime, playhead: item.currentTime().seconds,
      rate: Double(pane.player.rate),
      ready: item.status == .readyToPlay && !pane.isLoading && !pane.hasError,
      playing: pane.player.timeControlStatus == .playing,
      muted: pane.player.isMuted || pane.player.volume == 0)
    watchTracker.update(playback, session: environment.watchRewards)
  }

  /// A circular play/pause badge mirroring the Siri Remote's button — a play
  /// triangle and pause bars side by side inside a ring — so the hint reads as
  /// "press this physical button."
  private var playPauseBadge: some View {
    ZStack {
      Circle().fill(Color.white.opacity(0.22))
      HStack(spacing: 2.5) {
        Icon(glyph: .playerPlayFilled, size: 11)
        Icon(glyph: .playerPauseFilled, size: 11)
      }
    }
    .frame(width: 32, height: 32)
  }

  /// A slim, non-focusable coach mark shown briefly on appear so the hidden
  /// controls are discoverable. Styled as a standard tvOS material pill.
  private var revealHint: some View {
    HStack(spacing: 12) {
      playPauseBadge
      Text("Press Play/Pause for controls")
        .font(.callout.weight(.medium))
    }
    .foregroundStyle(palette.chromeOnOpaque)
    .padding(.leading, 10)
    .padding(.trailing, 22)
    .padding(.vertical, 8)
    .modifier(HUDChipGlassStyle())
    .environment(\.colorScheme, palette.chromeColorScheme)
  }

  // MARK: Pane

  private func paneView(_ pane: MultiviewPane, style: MultiviewPaneTile.Style) -> some View {
    PlayerView(channel: pane.channel.login, auth: auth, goLive: goLive,
      posterURL: pane.channel.thumbnailURL, initialPlatform: pane.channel.platform, model: pane.model)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(pane.presentation.isExpanded ? "expanded-stream-\(pane.id)" : "")
    .accessibilityValue(Text(pane.accessibilityStatus(isTransitioning: controller.isTransitioning)))
    .overlay {
      GeometryReader { geometry in
        let style = MultiviewPaneTile.Style.fitting(geometry.size, preferred: style)
        ZStack {
          MultiviewPaneTile(
            pane: pane,
            isFocused: focusedPaneID == pane.id,
            isPrimary: controller.layout.hasPrimary && controller.primaryPane?.id == pane.id,
            showsMetadata: chrome.isVisible && focusedPaneID == pane.id,
            showsChrome: chrome.isVisible,
            style: style,
            palette: palette,
            glassDisabled: glassDisabled
          )
          .opacity(pane.presentation.isExpanded ? 0 : 1)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          if controller.expandedPaneID == nil {
            MultiviewPaneButton {
              bumpChrome()
              if pane.hasError { controller.load(pane) } else { escalate(pane) }
            }
            .padding(.bottom, pane.model.isOffline ? MultiviewOfflineActions.reservedHeight(for: style) : 0)
            .focused($focus, equals: .pane(pane.id))
            // Tile buttons re-enter focus before the collapse animation completes.
            .prefersDefaultFocus(pane.id == (lastPaneID ?? controller.panes.first?.id), in: paneFocusScope)
            .contextMenu { paneMenu(pane) }
            .accessibilityIdentifier("multiview-pane-\(pane.id)")
            .accessibilityLabel(pane.channel.displayName)
            .accessibilityValue(Text(pane.accessibilityStatus(isTransitioning: controller.isTransitioning)))
            if pane.model.isOffline {
              MultiviewOfflineActions(style: style,
                onProfile: { openProfile(pane) }, onRemove: { remove(pane) },
                profileFocus: $focus, paneID: pane.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(style == .compact ? 8 : 20)
            }
          }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: pane.playbackTarget) { _, _ in
      let previousKey = pane.channel.channelKey
      pane.synchronizeChannel()
      lineup?.synchronize(pane, previousKey: previousKey)
    }
    .onChange(of: pane.model.isOffline) { _, offline in
      if offline { lineup?.observe(.offline, key: pane.channel.channelKey) }
    }
    .onChange(of: pane.isLoading) { _, loading in
      if !loading, !pane.hasError { lineup?.observe(.live, key: pane.channel.channelKey) }
    }
  }

  @ViewBuilder
  private func paneMenu(_ pane: MultiviewPane) -> some View {
    Button {
      escalate(pane)
    } label: {
      Label {
        Text("Full screen")
      } icon: {
        Icon(glyph: .arrowsMaximize)
      }
    }

    if controller.layout.hasPrimary && controller.primaryPane?.id != pane.id {
      Button {
        controller.makePrimary(pane.id)
        bumpChrome()
      } label: {
        Label { Text("Make primary") } icon: { Icon(glyph: .maximize) }
      }
      .accessibilityIdentifier("multiview-make-primary-\(pane.id)")
    }

    Button {
      lastPaneID = pane.id
      revealControls(layoutPicker: true)
    } label: {
      Label { Text("Layout…") } icon: { Icon(glyph: controller.layout.glyph) }
    }
    .accessibilityIdentifier("multiview-context-layout")

    if controller.panes.count > 1 {
      Button(role: .destructive) {
        remove(pane)
      } label: {
        Label { Text("Remove") } icon: { Icon(glyph: .trash) }
      }
    }

    if let lineup {
      Button { lineup.browse() } label: {
        Label { Text("Browse streams") } icon: { Icon(glyph: .plus) }
      }
    } else if controller.canAddPane && !addableChannels.isEmpty {
      Button {
        showingAddPicker = true
      } label: {
        Label { Text("Add stream") } icon: { Icon(glyph: .plus) }
      }
    }
  }

  // MARK: Actions

  private func openProfile(_ pane: MultiviewPane) {
    profileAudioState = controller.suspendAudio()
    profilePane = pane
  }

  private func finishProfile() {
    if let state = profileAudioState { controller.restoreAudio(state) }
    profileAudioState = nil
    if let request = profileWatchRequest,
      controller.panes.contains(where: { $0 === request.pane }) {
      request.pane.presentation.requestedChannel = request.channel
      request.pane.presentation.watchRequests &+= 1
      controller.setAudiblePane(request.pane.id)
      focus = .pane(request.pane.id)
    }
    profileWatchRequest = nil
    bumpChrome()
  }

  /// Expand the already-playing pane; no new player or modal cover is created.
  private func escalate(_ pane: MultiviewPane) {
    onWatch(pane.channel)
    controller.expand(pane.id)
  }

  private func add(_ channel: FollowedChannel) {
    if let id = controller.addPane(channel) {
      focus = .pane(id)
    }
    showingAddPicker = false
  }

  private func remove(_ pane: MultiviewPane) {
    if let lineup {
      lineup.remove(pane.channel.channelKey)
      focus = controller.panes.first.map { .pane($0.id) }
      bumpChrome()
      return
    }
    guard controller.panes.count > 1 else { dismiss(); return }
    let wasFocused = focusedPaneID == pane.id
    controller.removePane(pane.id)
    if wasFocused {
      focus = controller.panes.first.map { .pane($0.id) }
    }
    bumpChrome()
  }

  private func bumpChrome() {
    chrome.reveal()
  }

  private func revealControls(layoutPicker: Bool = false) {
    hintHideTask?.cancel()
    withAnimation(.motionAware(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) {
      hintVisible = false
      showingLayoutPicker = layoutPicker
      showingControls = true
    }
  }

  private func hideControls() {
    withAnimation(.motionAware(.easeOut(duration: 0.25), reduceMotion: reduceMotion)) {
      showingControls = false
      showingLayoutPicker = false
    }
    let returning = controller.panes.first { $0.id == lastPaneID } ?? controller.panes.first
    focus = returning.map { .pane($0.id) }
  }

  private func showHintBriefly() {
    hintVisible = true
    hintHideTask?.cancel()
    hintHideTask = Task {
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.5)) { hintVisible = false }
    }
  }
}

/// Focus targets in the multiview screen and its controls.
enum MultiviewFocusTarget: Hashable {
  case pane(String)
  case profile(String)
  case remove(String)
  case layoutButton
  case layoutChoice(MultiviewLayout)
  case addButton
  case closeButton
}

struct MultiviewOfflineActions: View {
  let style: MultiviewPaneTile.Style
  let onProfile: () -> Void
  let onRemove: () -> Void
  var profileFocus: FocusState<MultiviewFocusTarget?>.Binding
  let paneID: String

  // Keep the pane's retry focus target above, not overlapping, these controls.
  static func reservedHeight(for style: MultiviewPaneTile.Style) -> CGFloat {
    style == .compact ? 82 : 106
  }

  var body: some View {
    HStack(spacing: style == .compact ? 12 : 20) {
      Button(action: onProfile) {
        HStack {
          Icon(glyph: .user, size: style == .compact ? 18 : 22)
          if style == .full { Text("View channel") }
        }
      }
      .focused(profileFocus, equals: .profile(paneID))
      .accessibilityLabel("View channel")
      .accessibilityIdentifier("multiview-profile-\(paneID)")
      Button(action: onRemove) {
        HStack {
          Icon(glyph: .trash, size: style == .compact ? 18 : 22)
          if style == .full { Text("Remove") }
        }
      }
      .focused(profileFocus, equals: .remove(paneID))
      .accessibilityLabel("Remove")
      .accessibilityIdentifier("multiview-remove-\(paneID)")
    }
    .font(style == .compact ? .caption : .subheadline)
    .buttonStyle(.bordered)
    // The video surface stays dark even when the surrounding app uses Light.
    .environment(\.colorScheme, .dark)
  }
}

struct MultiviewPaneButton: View {
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    // tvOS's plain style still paints a focus platter over a clear label.
    // The tile supplies its own outline; this hit target must stay transparent.
    .buttonStyle(PlayerSurfaceButtonStyle())
    .focusEffectDisabled()
  }
}

/// A single video tile with focus highlight, status overlays, an auto-hiding
/// focused metadata pill, and a prominent audio cue on the audible pane.
struct MultiviewPaneTile: View {
  enum Style {
    /// A primary / grid quadrant.
    case full
    /// A filmstrip thumbnail or small pane in any layout.
    case compact

    static func fitting(_ size: CGSize, preferred: Style) -> Style {
      preferred == .full && size.width >= 420 && size.height >= 260 ? .full : .compact
    }
  }

  let pane: MultiviewPane
  let isFocused: Bool
  let isPrimary: Bool
  let showsMetadata: Bool
  var showsChrome = true
  let style: Style
  let palette: ThemePalette
  let glassDisabled: Bool

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if pane.hasError {
          statusOverlay {
            Text(pane.channel.displayName)
              .font(style == .compact ? .subheadline : .headline)
              .lineLimit(style == .compact ? 1 : 2)
            if pane.model.isOffline {
              Text("Channel offline")
                .font(style == .compact ? .caption : .subheadline)
                .foregroundStyle(palette.videoControlForeground.opacity(0.75))
            } else {
              Text("Couldn't load this stream")
                .font(style == .compact ? .caption : .subheadline)
                .foregroundStyle(palette.videoControlForeground.opacity(0.75))
            }
          }
        }

        overlays(size: geometry.size)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipped()
    }
    .overlay {
      Rectangle()
        .strokeBorder(borderColor, lineWidth: borderWidth)
        .padding(-borderWidth)
        .opacity(showsChrome ? 1 : (isFocused || pane.isAudible ? 0.35 : 0))
        // Snap the outline without changing other chrome animations or its idle fade.
        .animation(nil, value: isFocused)
        .animation(nil, value: pane.isAudible)
    }
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.2), value: pane.isAudible)
    .environment(\.themePalette, palette)
    .environment(\.glassDisabled, glassDisabled)
  }

  private var borderColor: Color {
    // The multiview wall is always a black video surface, so the native tvOS
    // focus treatment here is a white border (as on any dark screen). The
    // audible-but-unfocused pane keeps a lighter white hairline as a quiet cue.
    if isFocused { return palette.videoControlForeground }
    if pane.isAudible { return palette.videoControlForeground.opacity(0.5) }
    return palette.videoControlForeground.opacity(0.12)
  }

  private var borderWidth: CGFloat {
    if isFocused { return style == .compact ? 4 : MultiviewGeometry.maximumOutlineWidth }
    if pane.isAudible { return 3 }
    return 1
  }

  @ViewBuilder
  private func statusOverlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: style == .compact ? 6 : 12) { content() }
      .multilineTextAlignment(.center)
      .foregroundStyle(palette.videoControlForeground)
      .padding(style == .compact ? 8 : 20)
      .padding(.bottom, pane.model.isOffline ? MultiviewOfflineActions.reservedHeight(for: style) : 0)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.videoControlScrim.opacity(glassDisabled ? 1 : 0.45))
  }

  /// Focus metadata and audio ownership share the idle timeout.
  private func overlays(size: CGSize) -> some View {
    let minimal = size.width < 240 || size.height < 150
    return ZStack(alignment: .topTrailing) {
      if pane.isAudible && showsChrome && !(minimal && showsMetadata) {
        audioCue
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }

      if showsMetadata {
        MultiviewPaneMetadata(channel: pane.channel, style: style, minimal: minimal,
          includesAudio: minimal && pane.isAudible && showsChrome)
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.opacity)
      }
    }
    .opacity(pane.isLoading || pane.hasError ? 0 : 1)
  }

  private var audioCue: some View {
    Icon(glyph: .volume, size: style == .compact ? 18 : 22)
      .foregroundStyle(palette.chromeOnOpaque)
      .frame(width: style == .compact ? 36 : 44, height: style == .compact ? 36 : 44)
      .modifier(HUDChipGlassStyle(shape: Circle()))
      .accessibilityLabel("Audio")
  }
}

private struct MultiviewPaneMetadata: View {
  let channel: FollowedChannel
  let style: MultiviewPaneTile.Style
  let minimal: Bool
  let includesAudio: Bool
  @Environment(\.themePalette) private var palette

  var body: some View {
    HStack(alignment: .top, spacing: minimal ? 6 : CardMetrics.avatarTextSpacing) {
      if minimal {
        if includesAudio { Icon(glyph: .volume, size: 18) }
      } else {
        avatar
      }
      VStack(alignment: .leading, spacing: CardMetrics.captionLineSpacing) {
        Text(channel.displayName)
          .font(minimal ? .caption2 : (style == .compact ? .subheadline.weight(.semibold) : .headline))
          .foregroundStyle(palette.chromeOnOpaque)
          .lineLimit(1)

        if style == .full && !minimal {
          Text(channel.title.isEmpty ? "No title" : channel.title)
            .font(.subheadline)
            .foregroundStyle(palette.chromeOnOpaque.opacity(0.85))
            .lineLimit(1)

          if !channel.gameName.isEmpty {
            Text(channel.gameName)
              .font(.footnote)
              .foregroundStyle(palette.chromeOnOpaque.opacity(0.7))
              .lineLimit(1)
          }
        }

        if !minimal {
          LiveBadge(
            isLive: channel.isLive,
            viewerCount: channel.combinedViewerCount,
            prominent: style == .full,
            foreground: palette.chromeOnOpaque
          )
          .padding(.top, style == .compact ? 0 : 2)
        }
      }
    }
    .foregroundStyle(palette.chromeOnOpaque)
    .padding(.horizontal, minimal ? 8 : (style == .compact ? 10 : 14))
    .padding(.vertical, minimal ? 6 : (style == .compact ? 7 : 10))
    .modifier(HUDChipGlassStyle(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
    // Cap the pill so a long stream title truncates instead of stretching it
    // across the whole pane.
    .frame(maxWidth: style == .compact ? 260 : 520, alignment: .leading)
  }

  /// The channel avatar, matching the cards' circular treatment.
  private var avatar: some View {
    CachedAsyncImage(url: channel.profileImageURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(palette.chromeOnOpaque.opacity(0.18))
    }
    .frame(width: style == .compact ? 26 : 44, height: style == .compact ? 26 : 44)
    .clipShape(Circle())
  }
}

/// Live channel picker presented from inside multiview to add another pane.
/// Reuses ``StreamChannelCard`` so the add flow matches the setup screen.
private struct MultiviewAddView: View {
  let channels: [FollowedChannel]
  var onPick: (FollowedChannel) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  @FocusState private var focusedID: String?

  private let columns = [GridItem(.adaptive(minimum: 360, maximum: 480), spacing: 28)]

  var body: some View {
    ZStack {
      AppBackground(palette: palette).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        Label {
          Text("Add a channel")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .plus, size: 34)
        }
        .padding(.horizontal, AppLayout.horizontalPadding)
        .padding(.top, 48)

        if channels.isEmpty {
          Text("No other live channels to add.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(channels) { channel in
                StreamChannelCard(
                  channel: channel,
                  isFocused: focusedID == channel.id,
                  layout: .grid(),
                  showsGameName: true
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .focusable(true)
                .focused($focusedID, equals: channel.id)
                .focusEffectDisabled()
                .onTapGesture { onPick(channel) }
              }
            }
            .padding(.horizontal, AppLayout.horizontalPadding)
            .padding(.vertical, 28)
          }
        }
      }
    }
    .onExitCommand(perform: onCancel)
  }
}
