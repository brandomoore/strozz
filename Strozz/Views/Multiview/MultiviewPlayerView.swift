import AVFoundation
import SwiftUI

/// Plays up to six live channels at once. The tvOS focus engine selects one
/// pane as "active": that pane is unmuted and highlighted while every other pane
/// runs muted. Two arrangements are offered — a symmetric **grid** and a
/// **spotlight** (one large primary pane plus a thumbnail filmstrip). Play/Pause
/// reveals the layout controls. Panes can be
/// added or removed live, any pane can be promoted to the spotlight primary via
/// its long-press menu, and clicking a pane escalates it to the full
/// single-stream player. Menu exits multiview.
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
  @State private var watchTracker = TwitchWatchTracker()
  @State private var controller: MultiviewController
  @FocusState private var focus: MultiviewFocusTarget?
  /// Drives the auto-hiding focused-pane metadata: true right after any focus
  /// change or remote interaction, then fades out so the video wall stays clean.
  @State private var chromeVisible = true
  @State private var chromeHideTask: Task<Void, Never>?
  @State private var showingAddPicker = false
  /// The reveal-on-up controls HUD. The wall is full-screen by default; pressing
  /// up from the top pane row (a focus move the engine can't satisfy) surfaces
  /// the control bar and hands focus to it. Pressing down / Menu hides it again.
  @State private var showingControls = false
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
    if case let .pane(id) = focus { return id }
    return nil
  }

  private var addableChannels: [FollowedChannel] {
    // Keyed on `channelKey`, not `id`: a streamer already on screen can appear
    // in the pool under a different id (see `FollowedChannel.channelKey`) and
    // would otherwise still be offered.
    let present = Set(controller.panes.map(\.channel.channelKey))
    return availableChannels.filter { $0.isLive && !present.contains($0.channelKey) }
  }

  var body: some View {
    ZStack(alignment: .top) {
      palette.playerBackdrop.ignoresSafeArea()

      // The video wall fills the entire screen edge-to-edge — no outer margins.
      // While the HUD is open it's disabled so the focus engine can't escape
      // down into the panes — focus stays trapped in the controls until the
      // viewer closes them (Close button or the Menu/Back button).
      MultiviewVideoStage(controller: controller) { pane in
        paneView(pane, style: pane.qualityTier == .thumbnail ? .compact : .full)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .disabled(showingControls)

      // While the HUD is open, dim the wall a touch for contrast/modality.
      if showingControls && controller.expandedPaneID == nil {
        Color.black.opacity(0.4)
          .ignoresSafeArea()
          .allowsHitTesting(false)
          .transition(.opacity)
      }

      // Top layer: either the reveal HUD (focusable) or the coach hint. Both
      // float over the wall so the streams keep the full width and height.
      VStack(spacing: 0) {
        if showingControls {
          controlsBar
            .focusSection()
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if hintVisible && controller.expandedPaneID == nil {
          revealHint
            .padding(.top, 20)
            .transition(.opacity)
        }
        Spacer(minLength: 0)
      }
    }
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
      guard !controller.isTransitioning else { return }
      if case let .pane(id) = newValue {
        if controller.audiblePaneID != id { watchTracker.stop() }
        lastPaneID = id
        controller.setAudiblePane(id)
        // If the focus engine moved back down into a pane, retire the HUD.
        if showingControls {
          withAnimation(.easeOut(duration: 0.25)) { showingControls = false }
        }
      }
      bumpChrome()
    }
    .onPlayPauseCommand {
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
      guard let expanded = controller.expandedPane else { return }
      expanded.presentation.moveDirection = direction
      expanded.presentation.moveRequests &+= 1
    }
    .onDisappear {
      watchTracker.stop()
      chromeHideTask?.cancel()
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
      }
    }
    .onChange(of: controller.focusRestoreRequest) { _, _ in
      guard controller.expandedPaneID == nil else { return }
      focus = controller.restoredPaneID.map { .pane($0) }
    }
    .onChange(of: reduceMotion) { _, enabled in controller.reduceMotion = enabled }
    .onChange(of: controller.expandedPane?.model.isSleeping) { _, _ in
      controller.synchronizeExpandedSleep()
    }
    .onChange(of: showingAddPicker) { _, _ in
      watchTracker.stop()
    }
    .onExitCommand {
      if let expanded = controller.expandedPane {
        expanded.model.playbackTelemetry.recordEvent("multiview_exit_received")
        expanded.presentation.exitRequests &+= 1
      } else if showingControls {
        hideControls()
      } else {
        dismiss()
      }
    }
    .fullScreenCover(isPresented: $showingAddPicker) {
      MultiviewAddView(
        channels: addableChannels,
        onPick: { add($0) },
        onCancel: { showingAddPicker = false }
      )
    }
  }

  // MARK: Controls

  private func updateWatchRewards() {
    guard scenePhase == .active, controller.expandedPaneID == nil, !showingAddPicker,
      auth.isAuthenticated, let userID = auth.userID,
      let pane = controller.panes.first(where: { $0.id == controller.audiblePaneID }),
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
    .foregroundStyle(.white)
    .padding(.leading, 10)
    .padding(.trailing, 22)
    .padding(.vertical, 8)
    .background(
      Capsule().fill(glassDisabled ? AnyShapeStyle(Color.black.opacity(0.72))
                                   : AnyShapeStyle(.regularMaterial))
    )
  }

  private var controlsBar: some View {
    // A compact, centered pill of native tvOS buttons — the system supplies the
    // standard focus capsule/highlight, so it matches buttons elsewhere.
    HStack(spacing: 22) {
      Button {
        controller.toggleLayout()
        bumpChrome()
      } label: {
        Label {
          Text(controller.layout == .grid ? "Spotlight" : "Grid")
        } icon: {
          Icon(glyph: controller.layout == .grid ? .layoutBottombar : .layoutGrid, size: 22)
        }
        .font(.headline)
      }
      .focused($focus, equals: .layoutButton)

      if controller.canAddPane && !addableChannels.isEmpty {
        Button {
          showingAddPicker = true
        } label: {
          Label {
            Text("Add")
          } icon: {
            Icon(glyph: .plus, size: 22)
          }
          .font(.headline)
        }
        .focused($focus, equals: .addButton)
      }

      Button {
        hideControls()
      } label: {
        Label {
          Text("Close")
        } icon: {
          Icon(glyph: .x, size: 22)
        }
        .font(.headline)
      }
      .focused($focus, equals: .closeButton)
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 14)
    .background(
      Capsule().fill(glassDisabled ? AnyShapeStyle(Color.black.opacity(0.72))
                                   : AnyShapeStyle(.regularMaterial))
    )
  }

  // MARK: Pane

  private func paneView(_ pane: MultiviewPane, style: MultiviewPaneTile.Style) -> some View {
    PlayerView(channel: pane.channel.login, auth: auth, goLive: goLive,
      posterURL: pane.channel.thumbnailURL, model: pane.model)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(pane.presentation.isExpanded ? "expanded-stream-\(pane.id)" : "")
    .accessibilityValue(controller.isTransitioning ? "Transitioning" : "Live")
    .overlay {
      ZStack {
        MultiviewPaneTile(
          pane: pane,
          isFocused: focusedPaneID == pane.id,
          isPrimary: controller.layout == .spotlight && controller.primaryPane?.id == pane.id,
          showsMetadata: chromeVisible && focusedPaneID == pane.id,
          style: style,
          palette: palette,
          glassDisabled: glassDisabled,
          onRetry: { controller.load(pane) }
        )
        .opacity(pane.presentation.isExpanded ? 0 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        if controller.expandedPaneID == nil {
          Button {
            if pane.hasError { controller.load(pane) } else { escalate(pane) }
          } label: {
            Color.clear
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .focused($focus, equals: .pane(pane.id))
          .contextMenu { paneMenu(pane) }
          .accessibilityIdentifier("multiview-pane-\(pane.id)")
          .accessibilityLabel(pane.channel.displayName)
          .accessibilityValue(pane.isLoading ? "Loading"
            : (pane.hasError ? "Unavailable" : (controller.isTransitioning ? "Transitioning" : "Live")))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: pane.model.activeChannel) { _, login in
      guard !login.isEmpty, login != pane.channel.login else { return }
      pane.channel = FollowedChannel(id: pane.id, login: login,
        displayName: pane.model.channelDisplayName, title: pane.model.streamTitle, gameName: "",
        viewerCount: nil, thumbnailURL: nil, profileImageURL: pane.model.channelAvatarURL, isLive: true)
    }
  }

  @ViewBuilder
  private func paneMenu(_ pane: MultiviewPane) -> some View {
    Button {
      escalate(pane)
    } label: {
      Label {
        Text("Watch Stream")
      } icon: {
        Icon(glyph: .arrowsMaximize)
      }
    }

    if controller.layout == .grid {
      Button {
        controller.spotlight(pane.id)
        bumpChrome()
      } label: {
        Label { Text("Spotlight") } icon: { Icon(glyph: .maximize) }
      }
    } else if controller.primaryPane?.id != pane.id {
      Button {
        controller.makePrimary(pane.id)
        bumpChrome()
      } label: {
        Label { Text("Make Primary") } icon: { Icon(glyph: .maximize) }
      }
    }

    if controller.panes.count > 1 {
      Button(role: .destructive) {
        remove(pane)
      } label: {
        Label { Text("Remove") } icon: { Icon(glyph: .trash) }
      }
    }

    if controller.canAddPane && !addableChannels.isEmpty {
      Button {
        showingAddPicker = true
      } label: {
        Label { Text("Add Channel") } icon: { Icon(glyph: .plus) }
      }
    }
  }

  // MARK: Actions

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
    let wasFocused = focusedPaneID == pane.id
    controller.removePane(pane.id)
    if wasFocused {
      focus = controller.panes.first.map { .pane($0.id) }
    }
    bumpChrome()
  }

  private func bumpChrome() {
    chromeVisible = true
    chromeHideTask?.cancel()
    chromeHideTask = Task {
      try? await Task.sleep(for: .seconds(3.5))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.4)) {
        chromeVisible = false
      }
    }
  }

  private func revealControls() {
    hintHideTask?.cancel()
    withAnimation(.easeOut(duration: 0.25)) {
      hintVisible = false
      showingControls = true
    }
    focus = .layoutButton
  }

  private func hideControls() {
    withAnimation(.easeOut(duration: 0.25)) { showingControls = false }
    focus = (lastPaneID.map { .pane($0) }) ?? controller.panes.first.map { .pane($0.id) }
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

/// Focus targets in the multiview screen: each pane plus the two control chips.
private enum MultiviewFocusTarget: Hashable {
  case pane(String)
  case layoutButton
  case addButton
  case closeButton
}

/// A single video tile with focus highlight, status overlays, an auto-hiding
/// focused metadata pill, and a prominent audio cue on the audible pane.
private struct MultiviewPaneTile: View {
  enum Style {
    /// A primary / grid quadrant.
    case full
    /// A spotlight filmstrip thumbnail.
    case compact
  }

  let pane: MultiviewPane
  let isFocused: Bool
  let isPrimary: Bool
  let showsMetadata: Bool
  let style: Style
  let palette: ThemePalette
  let glassDisabled: Bool
  var onRetry: () -> Void

  private var cornerRadius: CGFloat { style == .compact ? 12 : 16 }

  var body: some View {
    ZStack {
      if pane.hasError {
        statusOverlay {
          Text(pane.channel.displayName)
            .font(style == .compact ? .subheadline : .headline)
            .foregroundStyle(.white)
          if style == .full {
            Text("Couldn't load — click to retry")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .onTapGesture(perform: onRetry)
      }

      overlays
    }
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    }
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.2), value: pane.isAudible)
    .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 8)
  }

  private var borderColor: Color {
    // The multiview wall is always a black video surface, so the native tvOS
    // focus treatment here is a white border (as on any dark screen). The
    // audible-but-unfocused pane keeps a lighter white hairline as a quiet cue.
    if isFocused { return .white }
    if pane.isAudible { return Color.white.opacity(0.5) }
    return Color.white.opacity(0.12)
  }

  private var borderWidth: CGFloat {
    if isFocused { return style == .compact ? 4 : 5 }
    if pane.isAudible { return 3 }
    return 1
  }

  @ViewBuilder
  private func statusOverlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 12) { content() }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.45))
  }

  /// Auto-hiding metadata (focused pane only) plus the persistent audio cue.
  private var overlays: some View {
    ZStack(alignment: .topTrailing) {
      // Audio cue: a bold, always-on badge on whichever pane owns sound, so the
      // active channel is obvious even after the metadata fades.
      if pane.isAudible {
        audioCue
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }

      if showsMetadata {
        metadataPill
          .padding(style == .compact ? 8 : 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .transition(.opacity)
      }
    }
    .opacity(pane.isLoading || pane.hasError ? 0 : 1)
  }

  private var audioCue: some View {
    HStack(spacing: 6) {
      Icon(glyph: .volume, size: style == .compact ? 18 : 22)
      if style == .full {
        Text("Audio")
          .font(.subheadline.weight(.semibold))
      }
    }
    .foregroundStyle(.black)
    .padding(.horizontal, style == .compact ? 9 : 12)
    .padding(.vertical, style == .compact ? 7 : 8)
    .background(Color.white, in: Capsule())
    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
  }

  /// Focused-pane metadata. Carries the same information, in the same order, as
  /// a Home card's caption — avatar, streamer, stream title, game, and the
  /// shared live/viewer badge — so a pane reads like the card the viewer picked
  /// it from rather than a different, thinner summary. Sits over the video on a
  /// dark scrim, so white content stays legible in every theme and with Reduce
  /// Transparency on (the scrim is opaque, not theme-tinted). The filmstrip's
  /// compact tiles keep only the streamer and the badge — there is no room for
  /// the rest at that size.
  private var metadataPill: some View {
    HStack(alignment: .top, spacing: CardMetrics.avatarTextSpacing) {
      avatar

      VStack(alignment: .leading, spacing: CardMetrics.captionLineSpacing) {
        Text(pane.channel.displayName)
          .font(style == .compact ? .subheadline.weight(.semibold) : .headline)
          .foregroundStyle(.white)
          .lineLimit(1)

        if style == .full {
          Text(pane.channel.title.isEmpty ? "No title" : pane.channel.title)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)

          if !pane.channel.gameName.isEmpty {
            Text(pane.channel.gameName)
              .font(.footnote)
              .foregroundStyle(.white.opacity(0.7))
              .lineLimit(1)
          }
        }

        LiveBadge(
          isLive: pane.channel.isLive,
          viewerCount: pane.channel.combinedViewerCount,
          prominent: style == .full
        )
        .padding(.top, style == .compact ? 0 : 2)
      }
    }
    .padding(.horizontal, style == .compact ? 10 : 14)
    .padding(.vertical, style == .compact ? 7 : 10)
    .background(
      glassDisabled
        ? AnyShapeStyle(Color.black.opacity(0.62))
        : AnyShapeStyle(.regularMaterial),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    // Cap the pill so a long stream title truncates instead of stretching it
    // across the whole pane.
    .frame(maxWidth: style == .compact ? 260 : 520, alignment: .leading)
  }

  /// The channel avatar, matching the cards' circular treatment.
  private var avatar: some View {
    CachedAsyncImage(url: pane.channel.profileImageURL) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(Color.white.opacity(0.18))
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
