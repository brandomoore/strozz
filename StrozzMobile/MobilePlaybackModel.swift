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

  @ObservationIgnored private var channel = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var jumpObserver: NSObjectProtocol?
  @ObservationIgnored private var rateObserver: NSKeyValueObservation?
  @ObservationIgnored private var routeObserver: NSKeyValueObservation?
  @ObservationIgnored private var baseline = LiveChatSyncBaseline()
  @ObservationIgnored private var catchUp = NativeLiveCatchUp()
  @ObservationIgnored private var followsLive = true
  @ObservationIgnored private var suspendedPosition: Position?
  @ObservationIgnored private var loadingPosition: Position?
  @ObservationIgnored private var audioSessionActive = false
  @ObservationIgnored private var triedDecodeRecovery = false
  @ObservationIgnored private var nativeRecovery = NativePlaybackRecovery()
  @ObservationIgnored private let muteForTesting: Bool
  @ObservationIgnored private let resolve: (String) async throws -> StreamPlayback
  private static let logger = Logger(subsystem: "com.thatcube.Twozz", category: "mobile-playback")

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

  func displayReady(_ ready: Bool, for source: AVPlayer) {
    guard player === source else { return }
    isReadyForDisplay = ready
    if ready, engine != nil { player.currentItem?.automaticallyPreservesTimeOffsetFromLive = false }
  }

  func start(channel: String) {
    guard !isActive else { return }
    self.channel = channel
    isActive = true
    chat.connect(to: channel)
    load(position: Position(shouldPlay: true, date: nil))
  }

  func select(_ quality: MobileQuality) {
    guard quality != selection,
          quality != .native || (nativeFailure == nil && !isExternalPlayback) else { return }
    let position = position()
    selection = quality
    triedDecodeRecovery = false
    recoveryNotice = nil
    load(position: position)
  }

  func goLive() {
    followsLive = true
    load(position: Position(shouldPlay: true, date: nil))
  }

  func togglePlayPause() {
    guard !isLoading, errorMessage == nil, player.currentItem != nil else { return }
    if isPaused {
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
    if selection == .native {
      select(.automatic)
      recoveryNotice = "AirPlay uses standard playback."
    }
  }

  func retry() {
    load(position: Position(shouldPlay: true, date: nil))
  }

  func suspend() {
    guard isActive, suspendedPosition == nil else { return }
    suspendedPosition = position()
    invalidate()
    chat.disconnect()
    releaseAudioSession()
  }

  func resume() {
    guard isActive, let position = suspendedPosition else { return }
    suspendedPosition = nil
    chat.connect(to: channel)
    load(position: position)
  }

  func stop() {
    isActive = false
    suspendedPosition = nil
    invalidate()
    chat.disconnect()
    releaseAudioSession()
  }

  private func position() -> Position {
    if let loadingPosition { return loadingPosition }
    return Position(shouldPlay: player.timeControlStatus != .paused,
             date: followsLive && player.timeControlStatus != .paused ? nil : player.currentItem?.currentDate())
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
    baseline.itemChanged()
    extraChatDelay = nil
    chat.configureChatSync(enabled: false, delaySeconds: 0)
    isLoading = false
    isReadyForDisplay = false
    loadingPosition = nil
  }

  private func load(position: Position) {
    guard isActive, suspendedPosition == nil else { return }
    invalidate()
    let request = generation
    let selection = selection
    isLoading = true
    loadingPosition = position
    isPaused = !position.shouldPlay
    followsLive = position.shouldPlay && position.date == nil
    errorMessage = nil
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try AVAudioSession.sharedInstance().setActive(true)
        audioSessionActive = true
        let playback = try await resolve(channel)
        guard isCurrent(request) else { return }
        qualities = playback.qualities
        guard let url = selection.source(in: playback) else {
          throw MobilePlaybackError.qualityUnavailable
        }
        if selection == .native {
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
        item.preferredForwardBufferDuration = selection == .native ? 1 : 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.automaticallyPreservesTimeOffsetFromLive = selection == .native && position.shouldPlay && position.date == nil
        item.audioTimePitchAlgorithm = .timeDomain
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
        item.add(output)
        videoOutput = output
        // Keep AVKit's rendering owner stable across normal source changes.
        // Only a terminally failed player requires a new owner and surface.
        if player.status == .failed { player = AVPlayer() }
        player.replaceCurrentItem(with: item)
        if player.currentItem !== item {
          player = AVPlayer(playerItem: item)
        }
        guard player.currentItem === item else { throw MobilePlaybackError.unavailable }
        player.isMuted = isMuted || muteForTesting
        player.allowsExternalPlayback = selection != .native
        if position.shouldPlay && position.date == nil { player.play() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while item.status != .readyToPlay {
          guard isCurrent(request) else { return }
          if item.status == .failed { throw item.error ?? MobilePlaybackError.unavailable }
          if ContinuousClock.now >= deadline { throw MobilePlaybackError.timeout }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard isCurrent(request) else { return }
        if let date = position.date {
          let timeout = Task { [weak self, weak item] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.isCurrent(request) == true else { return }
            item?.cancelPendingSeeks()
          }
          let restored = await player.seek(to: date)
          timeout.cancel()
          guard isCurrent(request) else { return }
          if !restored {
            throw MobilePlaybackError.positionUnavailable
          }
          if position.shouldPlay { player.play() }
        }
        isLoading = false
        loadingPosition = nil
        if selection == .native { recoveryNotice = nil }
        installIntentObservers(item: item, request: request)
        startMonitor(item: item, request: request)
      } catch {
        guard isCurrent(request) else { return }
        if selection == .native && (error as? MobilePlaybackError) != .positionUnavailable {
          recoverNative(error as? NativeHLSError ?? .unavailable,
                        detail: error.localizedDescription, position: position)
        } else {
          fail(error.localizedDescription)
        }
      }
    }
  }

  private func isCurrent(_ request: UUID) -> Bool {
    isActive && suspendedPosition == nil && request == generation && !Task.isCancelled
  }

  private func fallback(_ reason: String, position: Position? = nil) {
    guard selection == .native else { return }
    let saved = position ?? self.position()
    nativeFailure = reason
    selection = .automatic
    Self.logger.warning("Native mobile playback fell back: \(reason, privacy: .public)")
    load(position: saved)
  }

  func recoverNative(_ reason: NativeHLSError, detail: String? = nil, position: Position? = nil) {
    guard isActive, suspendedPosition == nil, selection == .native else { return }
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
    if selection == .native { nativeFailure = "A video rendition could not be decoded on this device." }
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
        guard let self, self.isCurrent(request) else { return }
        self.isPaused = paused
        if paused { self.stopFollowingLive() }
      }
    }
    jumpObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isCurrent(request) else { return }
        self.stopFollowingLive()
      }
    }
  }

  private func stopFollowingLive() {
    followsLive = false
    if catchUp.isActive, player.timeControlStatus == .playing, player.rate > 1 {
      player.rate = 1
    }
    catchUp.interrupt()
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
          let reason = item.error?.localizedDescription ?? player.error?.localizedDescription
            ?? MobilePlaybackError.unavailable.localizedDescription
          if selection == .native { recoverNative(.unavailable, detail: reason) } else { fail(reason) }
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
          if selection == .native { recoverNative(.timeout) }
          else { fail(MobilePlaybackError.timeout.localizedDescription) }
          return
        }
        let target = await engine?.origin.liveTargetDate()
        guard isCurrent(request), player.currentItem === item else { return }
        let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
          .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }
          .map { $0.end.seconds - clock }.max() ?? 0
        baseline.observe(context: "\(channel)|\(selection)", itemID: request, playbackDate: item.currentDate(),
                         playbackTime: clock, liveTarget: target,
                         canCalibrate: followsLive && playing && buffer >= 1 && !catchUp.isActive,
                         now: Date(), uptime: uptime)
        extraChatDelay = baseline.extraDelay
        chat.configureChatSync(
          enabled: UserDefaults.standard.bool(forKey: PersistenceKey.chatSyncToStream),
          delaySeconds: extraChatDelay ?? 0)
        let rate = catchUp.observe(.init(
          uptime: uptime, clock: clock, playbackDate: item.currentDate(), targetDate: target,
          rendition: "\(item.presentationSize)", isPlaying: playing, buffer: buffer,
          allowed: followsLive && engine != nil && !isExternalPlayback,
          hasFreshVideo: receivedVideoFrame && uptime - lastVideoFrame < 4,
          playbackRate: player.rate
        ))
        if player.timeControlStatus == .playing, abs(player.rate - rate) >= 0.005 {
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
