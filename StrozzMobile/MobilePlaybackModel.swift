import AVFoundation
import Observation
import OSLog

enum MobileQuality: Hashable {
  case native
  case automatic
  case fixed(String)

  func source(in playback: StreamPlayback) -> URL? {
    switch self {
    case .native, .automatic: return playback.master
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

  @ObservationIgnored private var channel = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
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
  @ObservationIgnored private var triedDecodeRecovery = false
  @ObservationIgnored private var nativeRecovery = NativePlaybackRecovery()
  @ObservationIgnored private let muteForTesting: Bool
  @ObservationIgnored private let resolve: (String) async throws -> StreamPlayback
  @ObservationIgnored var loadMetadata: (String) async -> ChannelMetadata? = {
    await PlaybackService.channelMetadata(for: $0)
  }
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "mobile-playback")

  struct Position {
    var shouldPlay: Bool
    var date: Date?
  }

  init(muted: Bool = false,
       resolve: @escaping (String) async throws -> StreamPlayback = { try await PlaybackService.resolve(for: $0) }) {
    #if targetEnvironment(simulator)
    muteForTesting = ProcessInfo.processInfo.environment["STROZZ_MUTE_PLAYBACK"] == "1"
    #else
    muteForTesting = false
    #endif
    isMuted = muted || muteForTesting
    self.resolve = resolve
    player.isMuted = isMuted
  }

  var qualityLabel: String {
    switch selection {
    case .native: return "Auto - Native Low Latency"
    case .automatic: return "Auto - Standard"
    case .fixed(let id): return qualities.first { $0.id == id }?.name ?? "Selected quality"
    }
  }

  var isAudioOnly: Bool {
    guard case .fixed(let id) = selection else { return false }
    return qualities.first { $0.id == id }?.isAudioOnly == true
  }

  var requestsNativePlayback: Bool {
    prefersNativePlayback && nativeFailure == nil && !isAudioOnly && !isExternalPlayback
  }

  var presentationState: PlaybackPresentationState {
    .init(isLoading: isLoading,
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

  func start(channel: String) {
    guard !isActive else { return }
    self.channel = channel
    isActive = true
    refreshStreamMetadata()
    observeAudioSession()
    chat.connect(to: channel)
    load(position: Position(shouldPlay: true, date: nil))
  }

  func select(_ quality: MobileQuality) {
    guard quality != selection,
          quality != .native || (nativeFailure == nil && !isExternalPlayback) else { return }
    let position = position()
    selection = quality
    if quality == .native { prefersNativePlayback = true }
    if quality == .automatic { prefersNativePlayback = false }
    triedDecodeRecovery = false
    recoveryNotice = nil
    load(position: position)
  }

  func goLive() {
    followsLive = true
    refreshStreamMetadata()
    load(position: Position(shouldPlay: true, date: nil))
  }

  func togglePlayPause() {
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
      select(.automatic)
      recoveryNotice = "AirPlay uses standard playback."
    }
  }

  func retry() {
    refreshStreamMetadata()
    load(position: Position(shouldPlay: true, date: nil))
  }

  func suspend() {
    guard isActive, suspendedPosition == nil else { return }
    suspendedPosition = position()
    needsFreshPlayer = true
    mediaResetInProgress = false
    invalidate()
    chat.disconnect()
    releaseAudioSession()
  }

  func resume() {
    guard isActive, let suspended = suspendedPosition else { return }
    // Returning is an opportunity to reactivate even if the OS never ended
    // its suspension interruption. Preserve any newer explicit pause intent.
    let position = interruptedPosition ?? suspended
    suspendedPosition = nil
    interruptedPosition = nil
    chat.connect(to: channel)
    refreshStreamMetadata()
    load(position: position)
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
    let loadMetadata = loadMetadata
    metadataTask = Task { [weak self] in
      let metadata = await loadMetadata(login)
      guard let self, self.isActive, self.channel == login, !Task.isCancelled else { return }
      self.streamStartedAt = metadata?.streamStartedAt
      if metadata == nil { Self.logger.warning("Mobile stream metadata unavailable") }
    }
  }

  private func prepareAudioSession() -> Bool {
    guard isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable else { return false }
    do {
      try activateAudioSession()
      audioSessionActive = true
      return true
    } catch {
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
    ]
  }

  func handleMediaServicesLost() {
    guard isActive else { return }
    resetPosition = position()
    mediaServicesUnavailable = true
    mediaResetInProgress = false
    needsFreshPlayer = true
    audioSessionActive = false
    invalidate()
    isLoading = true
    Self.logger.warning("Mobile media services lost; waiting for reset")
  }

  func handleMediaServicesReset() {
    guard isActive, !mediaResetInProgress else { return }
    let saved = position()
    resetPosition = saved
    mediaServicesUnavailable = false
    needsFreshPlayer = true
    audioSessionActive = false
    Self.logger.warning("Recreating mobile playback after media services reset")
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
    guard isActive, let value,
      let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
    switch type {
    case .began:
      guard interruptedPosition == nil else { return }
      interruptedPosition = position()
      mediaResetInProgress = false
      audioSessionActive = false
      invalidate()
      isLoading = true
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
    player.replaceCurrentItem(with: nil)
    videoOutput = nil
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
    guard isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable else { return }
    invalidate()
    if needsFreshPlayer || player.status == .failed {
      recreatePlayer()
      needsFreshPlayer = false
    }
    let request = generation
    let selection = selection
    isLoading = true
    loadingPosition = position
    isPaused = !position.shouldPlay
    followsLive = position.shouldPlay && position.date == nil
    errorMessage = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      guard prepareAudioSession() else { return }
      do {
        let playback = try await resolve(channel)
        guard isCurrent(request) else { return }
        qualities = playback.qualities
        guard let url = selection.source(in: playback) else {
          throw MobilePlaybackError.qualityUnavailable
        }
        let useNative = requestsNativePlayback
        if useNative {
          engine = NativeLowLatencyHLS(sourceURL: url, headers: PlaybackService.streamHeaders,
                                      history: 180) { [weak self] reason in
            Task { @MainActor [weak self] in
              guard let self, self.isCurrent(request) else { return }
              self.recoverNative(reason)
            }
          }
        }
        let asset = AVURLAsset(url: engine?.assetURL ?? url,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
        if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = useNative ? 3 : 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.automaticallyPreservesTimeOffsetFromLive = useNative && position.shouldPlay && position.date == nil
        item.audioTimePitchAlgorithm = .timeDomain
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
        item.add(output)
        videoOutput = output
        // Ordinary quality changes retain their AVKit owner. Foreground/reset
        // recovery replaces it before constructing the new item.
        if player.status == .failed { recreatePlayer() }
        player.replaceCurrentItem(with: item)
        if player.currentItem !== item {
          recreatePlayer()
          player.replaceCurrentItem(with: item)
        }
        guard player.currentItem === item else { throw MobilePlaybackError.unavailable }
        player.isMuted = isMuted || muteForTesting
        player.allowsExternalPlayback = !useNative
        if position.shouldPlay && position.date == nil { player.play() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (item.status != .readyToPlay &&
          !(position.date != nil && !item.seekableTimeRanges.isEmpty && item.currentDate() != nil)) ||
          (useNative && position.shouldPlay && item.seekableTimeRanges.isEmpty) {
          guard isCurrent(request) else { return }
          if item.status == .failed { throw item.error ?? MobilePlaybackError.unavailable }
          if ContinuousClock.now >= deadline { throw MobilePlaybackError.timeout }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent(request) else { return }
        var needsLiveAlignment = useNative && position.shouldPlay && position.date == nil
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
          if position.shouldPlay { player.play() }
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
        if PlaybackAudioSession.isMediaServicesReset(error) {
          if mediaResetInProgress {
            fail(String(localized: "Audio services haven't recovered. Please try again."))
          } else {
            handleMediaServicesReset()
          }
        } else if requestsNativePlayback && (error as? MobilePlaybackError) != .positionUnavailable
          && (error as? MobilePlaybackError) != .qualityUnavailable {
          recoverNative(error as? NativeHLSError ?? .unavailable,
                        detail: error.localizedDescription, position: position)
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

  private func fallback(_ reason: String, position: Position? = nil) {
    guard requestsNativePlayback else { return }
    let saved = position ?? self.position()
    nativeFailure = reason
    if selection == .native { selection = .automatic }
    Self.logger.warning("Native mobile playback fell back: \(reason, privacy: .public)")
    load(position: saved)
  }

  func recoverNative(_ reason: NativeHLSError, detail: String? = nil, position: Position? = nil) {
    guard isActive, suspendedPosition == nil, interruptedPosition == nil,
      !mediaServicesUnavailable, requestsNativePlayback else { return }
    guard nativeRecovery.takeRetry(for: reason) else {
      fallback(detail ?? reason.rawValue, position: position)
      return
    }
    let saved = position ?? self.position()
    recoveryNotice = "Reconnecting native low-latency playback..."
    Self.logger.warning("Retrying native mobile playback: \(reason.rawValue, privacy: .public)")
    load(position: saved)
  }

  private func fail(_ message: String) {
    invalidate()
    mediaResetInProgress = false
    resetPosition = nil
    errorMessage = message
    releaseAudioSession()
    Self.logger.error("Mobile playback failed: \(message, privacy: .public)")
  }

  static func decodeRecoveryQuality(in qualities: [StreamQuality], selection: MobileQuality) -> StreamQuality? {
    guard let source = qualities.filter({ !$0.isAudioOnly }).max(by: { $0.bitrate < $1.bitrate }),
          selection != .fixed(source.id) else { return nil }
    return source
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
      let paused = player.rate == 0 && player.timeControlStatus == .paused
      Task { @MainActor [weak self] in
        guard let self, self.isCurrent(request),
          self.player.status != .failed, item.status != .failed else { return }
        self.isPaused = paused
        if paused { self.stopFollowingLive() }
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
      var previousClock = item.currentTime().seconds
      var lastProgress = ProcessInfo.processInfo.systemUptime
      var lastVideoFrame = lastProgress
      var receivedVideoFrame = false
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, isCurrent(request) else { return }
        guard player.currentItem === item else {
          fail(MobilePlaybackError.unavailable.localizedDescription)
          return
        }
        if player.status == .failed || item.status == .failed {
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
        if clock > previousClock + 0.05 || paused { lastProgress = uptime }
        previousClock = clock
        if let videoOutput,
           videoOutput.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
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
        guard isCurrent(request), player.currentItem === item else { return }
        let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
          .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }
          .map { $0.end.seconds - clock }.max() ?? 0
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
          rendition: "\(item.presentationSize)", isPlaying: playing, buffer: buffer,
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
  case unavailable, timeout, qualityUnavailable, positionUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Could not play this stream. Try again."
    case .timeout: return "The stream stopped responding. Check your connection and try again."
    case .qualityUnavailable: return "That quality is no longer available. Choose Auto or another quality."
    case .positionUnavailable: return "That position is no longer available. Use Go live to rejoin the stream."
    }
  }
}
