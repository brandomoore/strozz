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

  @ObservationIgnored private var channel = ""
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var jumpObserver: NSObjectProtocol?
  @ObservationIgnored private var rateObserver: NSKeyValueObservation?
  @ObservationIgnored private var baseline = LiveChatSyncBaseline()
  @ObservationIgnored private var catchUp = NativeLiveCatchUp()
  @ObservationIgnored private var followsLive = true
  @ObservationIgnored private var suspendedPosition: Position?
  @ObservationIgnored private var loadingPosition: Position?
  @ObservationIgnored private var audioSessionActive = false
  @ObservationIgnored private var triedDecodeRecovery = false
  @ObservationIgnored private let muted: Bool
  @ObservationIgnored private let resolve: (String) async throws -> StreamPlayback
  private static let logger = Logger(subsystem: "com.thatcube.Twozz", category: "mobile-playback")

  struct Position {
    var shouldPlay: Bool
    var date: Date?
  }

  init(muted: Bool = false,
       resolve: @escaping (String) async throws -> StreamPlayback = { try await PlaybackService.resolve(for: $0) }) {
    #if targetEnvironment(simulator)
    self.muted = muted || ProcessInfo.processInfo.environment["STROZZ_MUTE_PLAYBACK"] == "1"
    #else
    self.muted = muted
    #endif
    self.resolve = resolve
    player.isMuted = self.muted
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
  }

  func start(channel: String) {
    guard !isActive else { return }
    self.channel = channel
    isActive = true
    chat.connect(to: channel)
    load(position: Position(shouldPlay: true, date: nil))
  }

  func select(_ quality: MobileQuality) {
    guard quality != selection, quality != .native || nativeFailure == nil else { return }
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
              self.fallback(reason.localizedDescription)
            }
          }
        }
        let asset = AVURLAsset(url: engine?.assetURL ?? url,
                               options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
        if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = selection == .native ? 1 : 8
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.automaticallyPreservesTimeOffsetFromLive = selection == .native && position.date == nil
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
        player.isMuted = muted
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
        installIntentObservers(item: item, request: request)
        startMonitor(item: item, request: request)
      } catch {
        guard isCurrent(request) else { return }
        if selection == .native && (error as? MobilePlaybackError) != .positionUnavailable {
          fallback(error.localizedDescription, position: position)
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
        guard let self, self.isCurrent(request), self.catchUp.inFlight == nil else { return }
        self.stopFollowingLive()
      }
    }
  }

  private func stopFollowingLive() {
    followsLive = false
    if catchUp.inFlight != nil { player.currentItem?.cancelPendingSeeks() }
    catchUp.interrupt(at: ProcessInfo.processInfo.systemUptime)
    player.currentItem?.automaticallyPreservesTimeOffsetFromLive = false
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
          if selection == .native { fallback(reason) } else { fail(reason) }
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
        }
        if paused || isAudioOnly { lastVideoFrame = uptime }
        if uptime - lastVideoFrame > (receivedVideoFrame ? 20 : 8),
           playing, uptime - lastProgress < 2, !isAudioOnly {
          recoverMissingVideo()
          return
        }
        if uptime - lastProgress > 20 {
          if selection == .native { fallback(MobilePlaybackError.timeout.localizedDescription) }
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
                         canCalibrate: followsLive && playing && buffer >= 1 && catchUp.inFlight == nil,
                         now: Date(), uptime: uptime)
        extraChatDelay = baseline.extraDelay
        chat.configureChatSync(
          enabled: UserDefaults.standard.bool(forKey: PersistenceKey.chatSyncToStream),
          delaySeconds: extraChatDelay ?? 0)
        if catchUp.timedOut(at: uptime) {
          item.cancelPendingSeeks()
          catchUp.interrupt(at: uptime)
        }
        if let correction = catchUp.observe(.init(
          uptime: uptime, clock: clock, playbackDate: item.currentDate(), targetDate: target,
          rendition: "\(item.presentationSize)", isPlaying: playing, buffer: buffer,
          allowed: followsLive && engine != nil
        )) {
          player.seek(to: correction.target) { [weak self] _ in
            Task { @MainActor [weak self] in
              guard let self, self.isCurrent(request) else { return }
              self.catchUp.finish(correction.id, at: ProcessInfo.processInfo.systemUptime)
            }
          }
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
