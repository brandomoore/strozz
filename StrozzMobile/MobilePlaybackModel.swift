import AVFoundation
import CoreVideo
import Observation
import OSLog

enum MobilePlaybackMode: CaseIterable, Hashable {
  case video, audioOnly, chatOnly

  var title: LocalizedStringResource {
    switch self {
    case .video: "Video and chat"
    case .audioOnly: "Audio and chat"
    case .chatOnly: "Chat only"
    }
  }
}

enum MobileQuality: Hashable {
  case native
  case receiver
  case audioOnly
  case fixed(String)

  func source(in playback: StreamPlayback) -> URL? {
    switch self {
    case .native, .receiver: return playback.master
    case .audioOnly: return playback.qualities.first { $0.isAudioOnly }?.url
    case .fixed(let id): return playback.qualities.first { $0.id == id }?.url
    }
  }
}

@MainActor
@Observable
final class MobilePlaybackModel {
  private(set) var player = AVPlayer()
  let chat = ChatService()
  private(set) var qualities: [StreamQuality] = []
  private(set) var selection: MobileQuality = .native
  private(set) var mode: MobilePlaybackMode = .video {
    didSet { if mode != oldValue { onModeChanged?(mode) } }
  }
  @ObservationIgnored var onModeChanged: ((MobilePlaybackMode) -> Void)?
  @ObservationIgnored var onSourceChanged: ((PlatformLiveTarget) -> Void)?
  @ObservationIgnored private var lastVideoSelection: MobileQuality = .native
  private(set) var prefersNativePlayback = true
  private(set) var nativeFailure: String?
  private(set) var recoveryNotice: String?
  private(set) var errorMessage: String?
  private(set) var isLoading = false
  private(set) var extraChatDelay: Double?
  private(set) var isActive = false
  private(set) var isReadyForDisplay = false
  private(set) var isPaused = false
  private(set) var isMuted: Bool
  private(set) var isExternalPlayback = false
  private(set) var livePosition = LivePlaybackPosition()
  private(set) var streamStartedAt: Date?
  private(set) var source = PlatformLiveTarget(platform: .twitch, channel: "")
  private(set) var sources: [PlatformLiveTarget] = []
  private(set) var kickChannel: KickChannel?
  private var twitchMetadata: ChannelMetadata?

  func presentationChannel(fallback: FollowedChannel) -> FollowedChannel {
    if source.channel.isEmpty { return fallback }
    if source.platform == .kick, let kickChannel { return kickChannel.followedChannel }
    let matches = source.platform == fallback.platform && source.channel == fallback.login
    if source.platform == .twitch, let twitchMetadata {
      return FollowedChannel(id: source.id, login: source.channel, displayName: twitchMetadata.displayName,
        title: twitchMetadata.title, gameName: matches ? fallback.gameName : "",
        viewerCount: twitchMetadata.viewersCount, thumbnailURL: matches ? fallback.thumbnailURL : nil,
        profileImageURL: twitchMetadata.profileImageURL, isLive: true)
    }
    if matches { return fallback }
    var channel = FollowedChannel(id: source.id, login: source.channel, displayName: source.channel,
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    channel.platform = source.platform
    return channel
  }

  private var channel: String { source.channel }
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
  @ObservationIgnored private(set) var decodedVideoSize: CGSize?
  @ObservationIgnored private(set) var controlledAutoActive = false
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var metadataTask: Task<Void, Never>?
  @ObservationIgnored private var jumpObserver: NSObjectProtocol?
  @ObservationIgnored private var rateObserver: NSKeyValueObservation?
  @ObservationIgnored private var routeObserver: NSKeyValueObservation?
  @ObservationIgnored private var baseline = LiveChatSyncBaseline()
  @ObservationIgnored private var catchUp = NativeLiveCatchUp()
  @ObservationIgnored private var catchUpRateChange: (uptime: TimeInterval, clock: Double, rate: Float)?
  @ObservationIgnored private var followsLive = true
  @ObservationIgnored private var suspendedPosition: Position?
  @ObservationIgnored private var loadingPosition: Position?
  @ObservationIgnored private var audioSessionActive = false
  @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var interruptedPosition: Position?
  @ObservationIgnored private var resetPosition: Position?
  @ObservationIgnored private var mediaServicesUnavailable = false
  @ObservationIgnored private var mediaResetInProgress = false
  @ObservationIgnored private var needsFreshPlayer = false
  @ObservationIgnored var activateAudioSession: @MainActor () throws -> Void = PlaybackAudioSession.activate
  @ObservationIgnored var onPlayerChanged: ((AVPlayer) -> Void)?
  @ObservationIgnored var usesPictureInPictureControls = false
  @ObservationIgnored private var triedDecodeRecovery = false
  @ObservationIgnored private var nativeRecovery = NativePlaybackRecovery()
  @ObservationIgnored private let muteForTesting: Bool
  @ObservationIgnored private let resolve: (String) async throws -> StreamPlayback
  @ObservationIgnored private let resolveKick: (String) async throws -> KickPlaybackService.Resolved
  @ObservationIgnored var loadMetadata: (String) async -> ChannelMetadata? = {
    await PlaybackService.channelMetadata(for: $0)
  }
  @ObservationIgnored var loadKickMetadata: (String) async throws -> KickChannel = {
    try await KickPlaybackService.channel($0)
  }
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "mobile-playback")

  @ObservationIgnored let diagnostics = PlaybackTelemetryRecorder(writer: PlaybackTelemetryWriter(
    directory: URL.cachesDirectory.appendingPathComponent("MobilePlaybackDiagnostics", isDirectory: true),
    maximumFileBytes: 512 * 1024, maximumFiles: 2, maximumPending: 32, mirrorToSystemLog: false))
  #if DEBUG
  @ObservationIgnored private var isLayoutFixture = false

  func prepareLayoutFixtureMetadata(channel: FollowedChannel? = nil) {
    if let channel {
      source = .init(platform: channel.platform, channel: channel.login)
      sources = [source]
    }
    isLayoutFixture = true
    isActive = true
    streamStartedAt = Date().addingTimeInterval(-4 * 3600 - 37 * 60)
    livePosition.observe(extraDelay: 0)
  }
  #endif

  struct Position {
    var shouldPlay: Bool
    var date: Date?
  }

  init(muted: Bool = false,
       resolve: @escaping (String) async throws -> StreamPlayback = { try await PlaybackService.resolve(for: $0) },
       resolveKick: @escaping (String) async throws -> KickPlaybackService.Resolved = { try await KickPlaybackService.resolve($0) }) {
    #if targetEnvironment(simulator)
    muteForTesting = ProcessInfo.processInfo.environment["STROZZ_MUTE_PLAYBACK"] == "1"
    #else
    muteForTesting = false
    #endif
    isMuted = muted || muteForTesting
    self.resolve = resolve
    self.resolveKick = resolveKick
    player.isMuted = isMuted
  }

  var qualityLabel: String {
    switch selection {
    case .native: return source.platform == .youtube ? "Auto" : "Auto - Native Low Latency"
    case .receiver: return "AirPlay"
    case .audioOnly: return String(localized: "Audio only")
    case .fixed(let id): return qualities.first { $0.id == id }?.name ?? "Selected quality"
    }
  }

  var isAudioOnly: Bool {
    if selection == .audioOnly { return true }
    guard case .fixed(let id) = selection else { return false }
    return qualities.first { $0.id == id }?.isAudioOnly == true
  }

  var requestsNativePlayback: Bool {
    mode == .video && prefersNativePlayback && !isAudioOnly && !isExternalPlayback && source.platform != .youtube
  }

  var presentationState: PlaybackPresentationState {
    if mode == .chatOnly { return .ready }
    return .init(isLoading: isLoading,
      awaitingVideo: !isReadyForDisplay && !isAudioOnly && !isPaused && !isExternalPlayback,
      isUnavailable: errorMessage != nil)
  }

  var liveStatus: LivePlaybackPosition.State {
    guard presentationState == .ready else { return .checking }
    return isPaused ? .paused : livePosition.state
  }

  func displayReady(_ ready: Bool, for source: AVPlayer) {
    guard player === source else { return }
    isReadyForDisplay = ready
    if ready, engine != nil { player.currentItem?.automaticallyPreservesTimeOffsetFromLive = false }
  }

  func start(channel: String, platform: LivePlatform = .twitch) {
    guard !isActive else { return }
    source = PlatformLiveTarget(platform: platform, channel: channel)
    sources = [source]
    kickChannel = nil
    twitchMetadata = nil
    streamStartedAt = nil
    isActive = true
    nativeFailure = nil
    nativeRecovery = NativePlaybackRecovery()
    diagnostics.beginSession(channel: channel, playbackMode: "mobile", attributes: ["source": platform.rawValue])
    diagnostics.startSchedulerMonitoring()
    refreshStreamMetadata()
    observeAudioSession()
    connectChat()
    load(position: Position(shouldPlay: true, date: nil))
  }

  func switchSource(_ target: PlatformLiveTarget) {
    guard target != source, isActive else { return }
    let shouldPlay = !isPaused
    let nextPosition = Position(shouldPlay: shouldPlay, date: nil)
    if suspendedPosition != nil { suspendedPosition = nextPosition }
    if interruptedPosition != nil { interruptedPosition = nextPosition }
    if resetPosition != nil { resetPosition = nextPosition }
    invalidate()
    metadataTask?.cancel()
    chat.disconnect()
    source = target
    onSourceChanged?(target)
    sources.removeAll { $0.platform == target.platform }
    sources.append(target)
    kickChannel = nil
    twitchMetadata = nil
    streamStartedAt = nil
    nativeFailure = nil
    nativeRecovery = NativePlaybackRecovery()
    triedDecodeRecovery = false
    recoveryNotice = nil
    selection = mode == .audioOnly ? .audioOnly : .native
    lastVideoSelection = .native
    diagnostics.beginSession(channel: target.channel, playbackMode: "mobile",
      attributes: ["source": target.platform.rawValue])
    diagnostics.startSchedulerMonitoring()
    connectChat()
    refreshStreamMetadata()
    if mode != .chatOnly { load(position: nextPosition) }
  }

  private func connectChat() {
    chat.disconnect()
    chat.youtubeMergeEnabled = false
    chat.kickMergeEnabled = false
    switch source.platform {
    case .twitch:
      chat.connect(to: source.channel)
      MobileChatSourcePreferences.apply(to: chat, channel: source.channel)
    case .kick:
      chat.configureExperimentalKickMerge(enabled: true, channelOrURL: source.channel)
    case .youtube:
      chat.configureExperimentalYouTubeMerge(enabled: true, channelOrURL: source.channel)
    }
  }

  func select(_ quality: MobileQuality) {
    let audio = quality == .audioOnly || qualities.contains { $0.isAudioOnly && quality == .fixed($0.id) }
    if audio {
      selectMode(.audioOnly)
      return
    }
    guard quality != selection || mode != .video || nativeFailure != nil else { return }
    guard quality != .native || !isExternalPlayback else { return }
    let position = mode == .chatOnly ? Position(shouldPlay: true, date: nil) : position()
    if mode == .video { lastVideoSelection = selection }
    mode = .video
    selection = quality
    prefersNativePlayback = quality != .receiver
    nativeFailure = nil
    nativeRecovery = NativePlaybackRecovery()
    triedDecodeRecovery = false
    recoveryNotice = nil
    load(position: position)
  }

  func selectMode(_ mode: MobilePlaybackMode) {
    guard mode != self.mode else { return }
    if self.mode == .video { lastVideoSelection = selection }
    self.mode = mode
    let position = Position(shouldPlay: mode != .chatOnly, date: nil)
    if suspendedPosition != nil { suspendedPosition = position }
    if interruptedPosition != nil { interruptedPosition = position }
    if resetPosition != nil { resetPosition = position }
    recoveryNotice = nil
    errorMessage = nil
    triedDecodeRecovery = false
    switch mode {
    case .chatOnly:
      mediaResetInProgress = false
      invalidate()
      isPaused = true
      releaseAudioSession()
    case .audioOnly:
      selection = .audioOnly
      load(position: position)
    case .video:
      selection = lastVideoSelection == .receiver && !isExternalPlayback ? .native : lastVideoSelection
      prefersNativePlayback = selection != .receiver
      nativeFailure = nil
      nativeRecovery = NativePlaybackRecovery()
      load(position: position)
    }
  }

  func goLive() {
    followsLive = true
    refreshStreamMetadata()
    load(position: Position(shouldPlay: true, date: nil))
  }

  func togglePlayPause() {
    guard mode != .chatOnly else { return }
    if var interrupted = interruptedPosition {
      interrupted.shouldPlay = false
      interruptedPosition = interrupted
      isPaused = true
      return
    }
    guard !isLoading, errorMessage == nil, player.currentItem != nil else { return }
    if isPaused {
      guard prepareAudioSession() else { return }
      isPaused = false
      player.play()
    } else {
      stopFollowingLive()
      isPaused = true
      player.pause()
    }
  }

  func toggleMute() {
    isMuted.toggle()
    player.isMuted = isMuted || muteForTesting
  }

  func prepareForAirPlay() {
    // A remote AirPlay receiver cannot fetch the native engine's loopback URLs.
    if requestsNativePlayback {
      select(.receiver)
      recoveryNotice = "AirPlay uses standard playback."
    }
  }

  func retry() {
    nativeFailure = nil
    nativeRecovery = NativePlaybackRecovery()
    refreshStreamMetadata()
    load(position: Position(shouldPlay: true, date: nil))
  }

  func suspend() {
    guard isActive, suspendedPosition == nil else { return }
    diagnostics.recordEvent("app_backgrounded")
    suspendedPosition = position()
    needsFreshPlayer = true
    mediaResetInProgress = false
    invalidate()
    chat.disconnect()
    releaseAudioSession()
  }

  func resume() {
    guard isActive, let suspended = suspendedPosition else { return }
    diagnostics.recordEvent("app_foregrounded")
    // Returning is an opportunity to reactivate even if the OS never ended
    // its suspension interruption. Preserve any newer explicit pause intent.
    let position = interruptedPosition ?? suspended
    suspendedPosition = nil
    interruptedPosition = nil
    connectChat()
    refreshStreamMetadata()
    if nativeFailure == nil { load(position: position) }
  }

  func stop() {
    isActive = false
    metadataTask?.cancel()
    metadataTask = nil
    streamStartedAt = nil
    suspendedPosition = nil
    interruptedPosition = nil
    resetPosition = nil
    mediaServicesUnavailable = false
    mediaResetInProgress = false
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioObservers.removeAll()
    invalidate()
    diagnostics.endSession(reason: "stopped")
    chat.disconnect()
    releaseAudioSession()
  }

  private func position() -> Position {
    if let suspendedPosition { return suspendedPosition }
    if let resetPosition { return resetPosition }
    if let interruptedPosition { return interruptedPosition }
    if let loadingPosition { return loadingPosition }
    return Position(shouldPlay: !isPaused,
             date: followsLive && !isPaused ? nil : player.currentItem?.currentDate())
  }

  private func refreshStreamMetadata() {
    guard isActive else { return }
    metadataTask?.cancel()
    let login = channel
    let target = source
    let loadMetadata = loadMetadata
    let loadKickMetadata = loadKickMetadata
    metadataTask = Task { [weak self] in
      if target.platform != .twitch {
        if target.platform == .kick {
          do {
            let channel = try await loadKickMetadata(target.channel)
            guard let self, self.isActive, self.source == target, !Task.isCancelled else { return }
            self.kickChannel = channel
            self.streamStartedAt = channel.startedAt
          } catch {
            guard let self, self.source == target, !Task.isCancelled else { return }
            self.diagnostics.recordEvent("channel_metadata_unavailable", level: .warning,
              attributes: PlaybackTelemetryRecorder.errorAttributes(error))
          }
        }
        return
      }
      let metadata = await loadMetadata(login)
      guard let self, self.isActive, self.source == target, !Task.isCancelled else { return }
      self.streamStartedAt = metadata?.streamStartedAt
      self.twitchMetadata = metadata
      if metadata == nil { Self.logger.warning("Mobile stream metadata unavailable") }
    }
  }

  private func prepareAudioSession() -> Bool {
    guard mode != .chatOnly, isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable else { return false }
    do {
      try activateAudioSession()
      audioSessionActive = true
      return true
    } catch {
      diagnostics.recordEvent("audio_session_activation_failed", level: .error,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error))
      fail(String(localized: "Couldn't start audio playback. Please try again."))
      Self.logger.error("Could not activate mobile audio: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  private func recreatePlayer() {
    let previous = player
    previous.pause()
    previous.replaceCurrentItem(with: nil)
    let replacement = AVPlayer()
    replacement.volume = previous.volume
    replacement.isMuted = isMuted || muteForTesting
    replacement.automaticallyWaitsToMinimizeStalling = previous.automaticallyWaitsToMinimizeStalling
    replacement.allowsExternalPlayback = previous.allowsExternalPlayback
    replacement.appliesMediaSelectionCriteriaAutomatically = previous.appliesMediaSelectionCriteriaAutomatically
    replacement.actionAtItemEnd = previous.actionAtItemEnd
    player = replacement
    onPlayerChanged?(replacement)
  }

  private func observeAudioSession() {
    guard audioObservers.isEmpty else { return }
    let center = NotificationCenter.default
    audioObservers = [
      center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.handleMediaServicesLost() }
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.handleMediaServicesReset() }
      },
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
        [weak self] notification in
        let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        MainActor.assumeIsolated { self?.handleAudioInterruption(type: type, options: options) }
      },
      center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
        [weak self] notification in
        let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        MainActor.assumeIsolated { self?.handleAudioRouteChange(reason: reason) }
      },
    ]
  }

  func handleAudioRouteChange(_ notification: Notification) {
    handleAudioRouteChange(reason: notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
  }

  private func handleAudioRouteChange(reason value: UInt?) {
    if isActive {
      diagnostics.recordEvent("audio_route_changed",
        counters: value.map { ["route_change_reason": Int(clamping: $0)] } ?? [:],
        flags: ["user_paused": isPaused])
    }
    guard isActive, mode != .chatOnly, let value,
      AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable else { return }
    isPaused = true
    stopFollowingLive()
    loadingPosition?.shouldPlay = false
    suspendedPosition?.shouldPlay = false
    interruptedPosition?.shouldPlay = false
    resetPosition?.shouldPlay = false
    player.pause()
    Self.logger.info("Audio output disconnected; waiting for explicit resume")
  }

  func handleMediaServicesLost() {
    guard isActive else { return }
    diagnostics.recordEvent("audio_media_services_lost", level: .error)
    if nativeFailure != nil {
      mediaServicesUnavailable = true
      needsFreshPlayer = true
      audioSessionActive = false
      return
    }
    resetPosition = position()
    mediaServicesUnavailable = true
    mediaResetInProgress = false
    needsFreshPlayer = true
    audioSessionActive = false
    invalidate()
    isLoading = mode != .chatOnly
    Self.logger.warning("Mobile media services lost; waiting for reset")
  }

  func handleMediaServicesReset() {
    guard isActive, !mediaResetInProgress else { return }
    diagnostics.recordEvent("audio_media_services_reset", level: .warning)
    let saved = position()
    resetPosition = saved
    mediaServicesUnavailable = false
    needsFreshPlayer = true
    audioSessionActive = false
    guard nativeFailure == nil else { return }
    Self.logger.warning("Recreating mobile playback after media services reset")
    if mode == .chatOnly { return }
    if suspendedPosition != nil {
      suspendedPosition = saved
      return
    }
    if interruptedPosition != nil { return }
    mediaResetInProgress = true
    load(position: saved)
  }

  func handleAudioInterruption(_ notification: Notification) {
    handleAudioInterruption(
      type: notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      options: notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
  }

  private func handleAudioInterruption(type value: UInt?, options: UInt) {
    guard isActive, nativeFailure == nil, let value,
      let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
    diagnostics.recordEvent("audio_interruption",
      counters: ["interruption_type": Int(clamping: value), "interruption_options": Int(clamping: options)])
    switch type {
    case .began:
      guard interruptedPosition == nil else { return }
      interruptedPosition = position()
      mediaResetInProgress = false
      audioSessionActive = false
      invalidate()
      isLoading = mode != .chatOnly
      Self.logger.info("Mobile playback interrupted")
    case .ended:
      guard var saved = interruptedPosition else { return }
      interruptedPosition = nil
      let options = AVAudioSession.InterruptionOptions(rawValue: options)
      saved.shouldPlay = saved.shouldPlay && options.contains(.shouldResume)
      isPaused = !saved.shouldPlay
      if suspendedPosition != nil { suspendedPosition = saved }
      else if mediaServicesUnavailable { resetPosition = saved }
      else { load(position: saved) }
    @unknown default:
      Self.logger.warning("Unknown mobile audio interruption")
    }
  }

  private func releaseAudioSession() {
    guard audioSessionActive else { return }
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionActive = false
    } catch {
      diagnostics.recordEvent("audio_session_deactivation_failed", level: .warning,
        attributes: PlaybackTelemetryRecorder.errorAttributes(error))
      Self.logger.error("Could not deactivate mobile audio: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func invalidate() {
    generation = UUID()
    loadTask?.cancel()
    loadTask = nil
    monitorTask?.cancel()
    monitorTask = nil
    rateObserver = nil
    routeObserver = nil
    if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
    jumpObserver = nil
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    diagnostics.trackItem(nil)
    player.replaceCurrentItem(with: nil)
    videoOutput = nil
    decodedVideoSize = nil
    controlledAutoActive = false
    engine?.stop()
    engine = nil
    catchUp = NativeLiveCatchUp()
    catchUpRateChange = nil
    baseline.itemChanged()
    livePosition = LivePlaybackPosition()
    extraChatDelay = nil
    chat.configureChatSync(enabled: false, delaySeconds: 0)
    isLoading = false
    isReadyForDisplay = false
    loadingPosition = nil
  }

  private func load(position: Position) {
    guard mode != .chatOnly, isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable else { return }
    invalidate()
    #if DEBUG
    if isLayoutFixture {
      errorMessage = nil
      player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
      isPaused = !position.shouldPlay
      isReadyForDisplay = true
      return
    }
    #endif
    if needsFreshPlayer || player.status == .failed {
      recreatePlayer()
      needsFreshPlayer = false
    }
    let request = generation
    let selection = selection
    let target = source
    isLoading = true
    loadingPosition = position
    isPaused = !position.shouldPlay
    followsLive = position.shouldPlay && position.date == nil
    errorMessage = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      guard prepareAudioSession() else { return }
      diagnostics.recordEvent("load_started", flags: ["user_paused": isPaused])
      do {
        let playback: StreamPlayback
        switch target.platform {
        case .twitch: playback = try await resolve(target.channel)
        case .kick:
          let resolved = try await resolveKick(target.channel)
          guard isCurrent(request) else { return }
          kickChannel = resolved.channel
          streamStartedAt = resolved.channel.startedAt
          playback = resolved.playback
        case .youtube:
          playback = try await target.resolvePlayback()
        }
        guard isCurrent(request) else { return }
        diagnostics.recordEvent("playback_resolved", counters: ["quality_count": playback.qualities.count])
        qualities = playback.qualities
        guard let url = selection.source(in: playback)
          ?? (target.platform == .kick && selection == .audioOnly ? playback.master : nil) else {
          throw selection == .audioOnly ? MobilePlaybackError.audioUnavailable : .qualityUnavailable
        }
        let useNative = requestsNativePlayback
        if useNative {
          let recorder = diagnostics
          let sessionID = recorder.sessionID
          let trace: (@Sendable (NativeHLSPlaybackDiagnostic) -> Void)? = { [weak recorder] detail in
            let dispatchedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
              guard let recorder, recorder.sessionID == sessionID else { return }
              recorder.recordEvent(detail.event.rawValue,
                attributes: detail.attributes.merging(["native_generation": request.uuidString]) { _, new in new },
                metrics: PlaybackTelemetryRecorder.nativeDeliveryMetrics(detail.metrics, dispatchedAt: dispatchedAt),
                counters: detail.counters)
            }
          }
          let fixedID: String?
          if target.platform == .kick, case .fixed(let id) = selection { fixedID = id }
          else { fixedID = nil }
          engine = NativeLowLatencyHLS(sourceURL: target.platform == .kick ? playback.master : url, headers: target.headers,
            history: 180, fixedRenditionID: fixedID, diagnostic: { [weak recorder] detail in
              let dispatchedAt = ProcessInfo.processInfo.systemUptime
              Task { @MainActor in
                guard let recorder, recorder.sessionID == sessionID else { return }
                let retrying = detail.attributes["operation"] == "manifest_retry"
                let probing = detail.attributes["operation"] == "capacity_probe"
                recorder.recordEvent(probing ? "native_hls_capacity_probe"
                  : retrying ? "native_hls_manifest_retry" : "native_hls_failure",
                  level: retrying || probing ? .warning : .error,
                  attributes: detail.attributes.merging(["native_generation": request.uuidString]) { _, new in new },
                  metrics: PlaybackTelemetryRecorder.nativeDeliveryMetrics(detail.metrics, dispatchedAt: dispatchedAt),
                  counters: detail.counters)
              }
            }, trace: trace) { [weak self] reason in
            Task { @MainActor [weak self] in
              guard let self, self.isCurrent(request) else { return }
              self.recoverNative(reason)
            }
          }
        }
        let asset = AVURLAsset(url: engine?.assetURL ?? url,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": target.headers])
        if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = useNative ? 3 : 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.automaticallyPreservesTimeOffsetFromLive = useNative && position.shouldPlay && position.date == nil
        item.audioTimePitchAlgorithm = .timeDomain
        if !isAudioOnly {
          let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
          item.add(output)
          videoOutput = output
        }
        // Ordinary quality changes retain their AVKit owner. Foreground/reset
        // recovery replaces it before constructing the new item.
        if player.status == .failed { recreatePlayer() }
        player.replaceCurrentItem(with: item)
        if player.currentItem !== item {
          recreatePlayer()
          player.replaceCurrentItem(with: item)
        }
        guard player.currentItem === item else { throw MobilePlaybackError.unavailable }
        diagnostics.trackItem(item, source: target.platform.rawValue)
        player.isMuted = isMuted || muteForTesting
        player.allowsExternalPlayback = !useNative
        if position.shouldPlay && !isPaused && position.date == nil { player.play() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (item.status != .readyToPlay &&
          !(position.date != nil && !item.seekableTimeRanges.isEmpty && item.currentDate() != nil)) ||
          (useNative && position.shouldPlay && !isPaused && item.seekableTimeRanges.isEmpty) {
          guard isCurrent(request) else { return }
          if item.status == .failed { throw item.error ?? MobilePlaybackError.unavailable }
          if ContinuousClock.now >= deadline { throw MobilePlaybackError.timeout }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent(request) else { return }
        var needsLiveAlignment = useNative && position.shouldPlay && !isPaused && position.date == nil
        if needsLiveAlignment, let native = engine {
          let target = await native.origin.liveTargetDate()
          let sourceBuffer = await native.origin.snapshot().forwardBuffer
          guard isCurrent(request) else { return }
          if let sourceBuffer { item.preferredForwardBufferDuration = sourceBuffer }
          if let target, let displayed = item.currentDate(), player.timeControlStatus == .playing,
             target.timeIntervalSince(displayed) <= NativeLiveCatchUp.startupToleranceSeconds {
            needsLiveAlignment = false
          }
        }
        if position.date != nil || needsLiveAlignment {
          if useNative {
            let offset = item.recommendedTimeOffsetFromLive
            if offset.seconds.isFinite, offset.seconds >= 0 { item.configuredTimeOffsetFromLive = offset }
            item.automaticallyPreservesTimeOffsetFromLive = false
          }
          let restored: Bool
          if let date = position.date {
            restored = await PlaybackPositionRestoration.restore(date, on: item) { [weak self] in
              self?.isCurrent(request) == true && self?.player.currentItem === item
            }
          } else {
            let timeout = Task { [weak self, weak item] in
              do { try await Task.sleep(for: .seconds(5)) } catch { return }
              guard self?.isCurrent(request) == true else { return }
              item?.cancelPendingSeeks()
            }
            restored = await player.seek(to: .positiveInfinity)
            timeout.cancel()
          }
          guard isCurrent(request) else { return }
          if !restored {
            throw position.date == nil ? MobilePlaybackError.timeout : MobilePlaybackError.positionUnavailable
          }
          if position.shouldPlay && !isPaused { player.play() }
        }
        isLoading = false
        loadingPosition = nil
        resetPosition = nil
        mediaResetInProgress = false
        if useNative { recoveryNotice = nil }
        installIntentObservers(item: item, request: request)
        startMonitor(item: item, request: request)
      } catch {
        guard isCurrent(request) else { return }
        diagnostics.recordEvent("load_failed", level: .error,
          attributes: PlaybackTelemetryRecorder.errorAttributes(error))
        if PlaybackAudioSession.isMediaServicesReset(error) {
          if mediaResetInProgress {
            fail(String(localized: "Audio services haven't recovered. Please try again."))
          } else {
            handleMediaServicesReset()
          }
        } else if requestsNativePlayback && (error as? MobilePlaybackError) != .positionUnavailable
          && (error as? MobilePlaybackError) != .qualityUnavailable {
          recoverNative(error as? NativeHLSError ?? .unavailable,
                        detail: error.localizedDescription, position: self.position())
        } else {
          fail(error.localizedDescription)
        }
      }
    }
  }

  private func isCurrent(_ request: UUID) -> Bool {
    isActive && suspendedPosition == nil && interruptedPosition == nil
      && !mediaServicesUnavailable && request == generation && !Task.isCancelled
  }

  private func failNative(_ reason: String) {
    guard requestsNativePlayback else { return }
    nativeFailure = reason
    fail(String(localized: "Native playback failed. \(reason) Try Again to reconnect."))
  }

  func recoverNative(_ reason: NativeHLSError, detail: String? = nil, position: Position? = nil) {
    guard isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable, requestsNativePlayback else { return }
    diagnostics.recordEvent("native_hls_retry", level: .warning,
      attributes: ["reason": reason.rawValue], counters: ["attempts_in_window": nativeRecovery.attempts.count])
    guard nativeRecovery.takeRetry(for: reason) else {
      failNative(detail ?? reason.rawValue)
      return
    }
    let saved = position ?? self.position()
    recoveryNotice = "Reconnecting native low-latency playback..."
    Self.logger.warning("Retrying native mobile playback: \(reason.rawValue, privacy: .public)")
    load(position: saved)
  }

  private func fail(_ message: String) {
    diagnostics.recordEvent("playback_failed", level: .error)
    invalidate()
    recoveryNotice = nil
    mediaResetInProgress = false
    resetPosition = nil
    errorMessage = message
    releaseAudioSession()
    Self.logger.error("Mobile playback failed: \(message, privacy: .public)")
  }

  static func decodeRecoveryQuality(in qualities: [StreamQuality], selection: MobileQuality) -> StreamQuality? {
    let selectedID: String?
    if case .fixed(let id) = selection { selectedID = id } else { selectedID = nil }
    return StreamQuality.decodeRecoveryQuality(in: qualities, selectedID: selectedID)
  }

  private func recoverMissingVideo() {
    guard !triedDecodeRecovery,
          let source = Self.decodeRecoveryQuality(in: qualities, selection: selection) else {
      fail("Video could not be decoded. Try another quality or stream.")
      return
    }
    triedDecodeRecovery = true
    let position = position()
    recoveryNotice = "A video rendition could not be decoded. Using \(source.name) instead."
    Self.logger.warning("Recovering undecodable video using the primary video rendition")
    selection = .fixed(source.id)
    load(position: position)
  }

  private func installIntentObservers(item: AVPlayerItem, request: UUID) {
    routeObserver = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self, self.isCurrent(request) else { return }
        self.isExternalPlayback = self.player.isExternalPlaybackActive
      }
    }
    rateObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
      Task { @MainActor [weak self] in
        guard let self, self.isCurrent(request),
          self.player === player, self.player.status != .failed, item.status != .failed else { return }
        self.observePlayerPause(player.rate == 0 && player.timeControlStatus == .paused)
      }
    }
    jumpObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isCurrent(request) else { return }
        if let change = self.catchUpRateChange {
          let elapsed = ProcessInfo.processInfo.systemUptime - change.uptime
          let advance = item.currentTime().seconds - change.clock
          if (0...1).contains(elapsed), abs(advance - elapsed * Double(change.rate)) < 0.5 {
            return
          }
        }
        self.stopFollowingLive()
      }
    }
  }

  func observePlayerPause(_ paused: Bool) {
    // Inline native controls set viewer intent explicitly. A decoder stop must
    // not become a viewer pause; system PiP/AirPlay controls still own theirs.
    guard !requestsNativePlayback || isAudioOnly || usesPictureInPictureControls
      || player.isExternalPlaybackActive else { return }
    isPaused = paused
    if paused { stopFollowingLive() }
  }

  private func stopFollowingLive() {
    followsLive = false
    if catchUp.isActive, player.timeControlStatus == .playing, player.rate > 1 {
      player.rate = 1
    }
    catchUp.interrupt(at: ProcessInfo.processInfo.systemUptime)
    catchUpRateChange = nil
  }

  private func startMonitor(item: AVPlayerItem, request: UUID) {
    monitorTask = Task { [weak self] in
      var bufferedStallRecovery = NativeBufferedStallRecovery()
      var previousClock = item.currentTime().seconds
      var lastProgress = ProcessInfo.processInfo.systemUptime
      var lastVideoFrame = lastProgress
      var receivedVideoFrame = false
      var lastDiagnostics = -Double.infinity
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, isCurrent(request) else { return }
        MobileChatSourcePreferences.apply(to: chat, channel: channel)
        guard player.currentItem === item else {
          fail(MobilePlaybackError.unavailable.localizedDescription)
          return
        }
        if player.status == .failed || item.status == .failed {
          diagnostics.recordEvent("player_item_failed", level: .error,
            attributes: PlaybackTelemetryRecorder.errorAttributes(item.error ?? player.error))
          if PlaybackAudioSession.isMediaServicesReset(player.error)
            || PlaybackAudioSession.isMediaServicesReset(item.error) {
            handleMediaServicesReset()
            return
          }
          let reason = item.error?.localizedDescription ?? player.error?.localizedDescription
            ?? MobilePlaybackError.unavailable.localizedDescription
          if engine != nil { recoverNative(.unavailable, detail: reason) } else { fail(reason) }
          return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let clock = item.currentTime().seconds
        let playing = player.timeControlStatus == .playing
        let paused = player.timeControlStatus == .paused
        if clock > previousClock + 0.05 || isPaused { lastProgress = uptime }
        previousClock = clock
        let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
          .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }
          .map { $0.end.seconds - clock }.max() ?? 0
        if uptime - lastDiagnostics >= 2 {
          lastDiagnostics = uptime
          diagnostics.recordItemLogs()
          diagnostics.recordSnapshot(PlaybackTelemetrySnapshot(
            attributes: [
              "time_control_status": playing ? "playing" : paused ? "paused" : "waiting",
              "item_status": item.status == .readyToPlay ? "ready" : "loading",
              "source": engine == nil ? "standard" : "native",
              "playback_profile": requestsNativePlayback ? "nativeLowLatency" : "standard",
              "quality": qualityLabel, "presentation": "mobile",
            ],
            metrics: ["playhead_seconds": clock, "buffer_ahead_seconds": buffer,
                      "video_frame_age_seconds": uptime - lastVideoFrame],
            flags: ["user_paused": isPaused, "loading": isLoading, "playback_requested": !isPaused,
                    "buffer_empty": item.isPlaybackBufferEmpty, "background": false,
                    "decode_frozen": receivedVideoFrame && uptime - lastVideoFrame > 4
                      && !isAudioOnly && !isExternalPlayback && !isPaused]))
        }
        switch bufferedStallRecovery.observe(clock: clock, uptime: uptime, buffer: buffer,
          minimumBuffer: item.preferredForwardBufferDuration,
          waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
          paused: paused,
          allowed: engine != nil && !isLoading && !isPaused && !isExternalPlayback && !isAudioOnly
            && suspendedPosition == nil && interruptedPosition == nil && !mediaServicesUnavailable
            && !usesPictureInPictureControls) {
        case .resumePaused:
          catchUp.interrupt(at: uptime)
          catchUpRateChange = (uptime, clock, 1)
          Self.logger.warning("Resuming native playback after an unrequested pause")
          diagnostics.recordEvent("native_unrequested_pause_resume", level: .warning)
          player.play()
          continue
        case .resume:
          catchUp.interrupt(at: uptime)
          catchUpRateChange = (uptime, clock, 1)
          Self.logger.warning("Requesting native playback resume from a refilled buffer")
          player.playImmediately(atRate: 1)
          continue
        case .awaitingProgress:
          continue
        case .restart:
          Self.logger.warning("Buffered native playback did not resume; refreshing the native source")
          recoverNative(.timeout)
          return
        case .none:
          break
        }
        let freshVideoFrame = videoOutput?.hasNewPixelBuffer(forItemTime: item.currentTime()) == true
        if let videoOutput,
           let frame = videoOutput.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
          decodedVideoSize = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
          if freshVideoFrame { diagnostics.videoFrameObserved(size: decodedVideoSize) }
          lastVideoFrame = uptime
          receivedVideoFrame = true
          if engine != nil { item.automaticallyPreservesTimeOffsetFromLive = false }
        }
        if paused || isAudioOnly || isExternalPlayback { lastVideoFrame = uptime }
        if uptime - lastVideoFrame > (receivedVideoFrame ? 20 : 8),
           playing, uptime - lastProgress < 2, !isAudioOnly, !isExternalPlayback {
          recoverMissingVideo()
          return
        }
        if uptime - lastProgress > 20 {
          if engine != nil { recoverNative(.timeout) }
          else { fail(MobilePlaybackError.timeout.localizedDescription) }
          return
        }
        let target = await engine?.origin.liveTargetDate()
        let sourceBuffer = await engine?.origin.snapshot().forwardBuffer
        do {
          let controlled = try await engine?.origin.updateControlledPlayback(buffer: buffer, budget: .init()) ?? false
          guard isCurrent(request), player.currentItem === item else { return }
          controlledAutoActive = controlled
        } catch {
          guard isCurrent(request), player.currentItem === item, !(error is CancellationError) else { return }
          Self.logger.error("Controlled playback feedback failed: \((error as NSError).domain) \((error as NSError).code)")
          recoverNative(NativeHLSError.classify(error))
          return
        }
        guard isCurrent(request), player.currentItem === item else { return }
        baseline.observe(context: "\(channel)|\(selection)", itemID: request, playbackDate: item.currentDate(),
                         playbackTime: clock, liveTarget: target,
                         canCalibrate: followsLive && playing && buffer >= 1 && !catchUp.isActive,
                         now: Date(), uptime: uptime)
        extraChatDelay = baseline.extraDelay
        livePosition.observe(extraDelay: baseline.extraDelay)
        chat.configureChatSync(
          enabled: UserDefaults.standard.bool(forKey: PersistenceKey.chatSyncToStream),
          delaySeconds: extraChatDelay ?? 0)
        let rate = catchUp.observe(.init(
          uptime: uptime, clock: clock, playbackDate: item.currentDate(), targetDate: target,
          rendition: "\(controlledAutoActive ? decodedVideoSize ?? .zero : item.presentationSize)",
          isPlaying: playing, buffer: buffer,
          allowed: followsLive && engine != nil && !isExternalPlayback && baseline.reference != .unavailable,
          hasFreshVideo: receivedVideoFrame && uptime - lastVideoFrame < 4,
          playbackRate: player.rate, normalOffset: baseline.nativeCushion ?? 0
        ))
        if let sourceBuffer {
          if item.preferredForwardBufferDuration != sourceBuffer { item.preferredForwardBufferDuration = sourceBuffer }
        }
        if player.timeControlStatus == .playing, abs(player.rate - rate) >= 0.005 {
          catchUpRateChange = (ProcessInfo.processInfo.systemUptime, item.currentTime().seconds, rate)
          player.rate = rate
        }
      }
    }
  }
}

private enum MobilePlaybackError: LocalizedError, Equatable {
  case unavailable, timeout, qualityUnavailable, audioUnavailable, positionUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Could not play this stream. Try again."
    case .timeout: return "The stream stopped responding. Check your connection and try again."
    case .qualityUnavailable: return "That quality is no longer available. Choose Auto or another quality."
    case .audioUnavailable: return String(localized: "This stream doesn't offer audio-only playback. Choose Video and chat or Chat only.")
    case .positionUnavailable: return "That position is no longer available. Use Go live to rejoin the stream."
    }
  }
}
