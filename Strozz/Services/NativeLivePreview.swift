import AVFoundation
import Observation
import OSLog

/// One muted live preview, with the same native origin and recovery policies as
/// foreground playback. Its owner controls visibility and must call stop().
@MainActor
@Observable
final class NativeLivePreview {
  private(set) var player = AVPlayer()
  private(set) var isReady = false
  private(set) var isNative = false
  private(set) var errorMessage: String?
  private(set) var fallbackReason: String?
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var failure: NativeHLSError?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engineGeneration = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "native-preview")

  private enum PreviewError: Error { case missingVideo, startupTimeout }

  init() {
    player.isMuted = true
    player.allowsExternalPlayback = false
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
  }

  func start(url: URL, refresh: @escaping @MainActor (Bool) async throws -> URL) {
    stop()
    let request = generation
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var source = url
      var native = true
      var triedSource = false
      var recovery = NativePlaybackRecovery()
      while isCurrent(request) {
        do {
          try await play(source, native: native, request: request)
          return
        } catch {
          guard isCurrent(request) else { return }
          player.pause()
          player.replaceCurrentItem(with: nil)
          engine?.stop()
          engine = nil
          isReady = false
          isNative = false
          if error is PreviewError, !triedSource {
            triedSource = true
            Self.logger.warning("Preview video unavailable; retrying the original video rendition")
          } else if native {
            let reason = error as? NativeHLSError ?? .unavailable
            if !recovery.takeRetry(for: reason) {
              native = false
              fallbackReason = reason.rawValue
              Self.logger.warning("Native preview fell back to standard playback: \(reason.rawValue)")
            }
          } else {
            errorMessage = "Live preview unavailable."
            Self.logger.warning("Preview failed: \((error as NSError).domain) \((error as NSError).code)")
            return
          }
          do {
            source = try await refresh(triedSource)
          } catch {
            guard isCurrent(request) else { return }
            errorMessage = "Live preview unavailable."
            Self.logger.warning("Preview source refresh failed: \((error as NSError).domain) \((error as NSError).code)")
            return
          }
        }
      }
    }
  }

  func stop() {
    generation = UUID()
    engineGeneration = UUID()
    task?.cancel()
    task = nil
    engine?.stop()
    engine = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    isReady = false
    isNative = false
    failure = nil
    errorMessage = nil
    fallbackReason = nil
  }

  private func isCurrent(_ request: UUID) -> Bool {
    request == generation && !Task.isCancelled
  }

  private func play(_ url: URL, native: Bool, request: UUID) async throws {
    failure = nil
    isNative = native
    engineGeneration = UUID()
    let engineRequest = engineGeneration
    if player.status == .failed { player = AVPlayer() }
    player.isMuted = true
    player.allowsExternalPlayback = false
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    if native {
      engine = NativeLowLatencyHLS(sourceURL: url, headers: PlaybackService.streamHeaders, history: 30) {
        [weak self] error in
        Task { @MainActor in
          guard let self, self.generation == request, self.engineGeneration == engineRequest else { return }
          self.failure = error
        }
      }
    }
    let asset = AVURLAsset(url: engine?.assetURL ?? url,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders])
    if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = native ? 3 : 0.8
    item.automaticallyPreservesTimeOffsetFromLive = native
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
    item.add(output)
    player.replaceCurrentItem(with: item)
    player.play()
    var aligned = !native
    var receivedFrame = false
    var lastFrame = ProcessInfo.processInfo.systemUptime
    let started = lastFrame
    var bufferedRecovery = NativeBufferedStallRecovery()
    var catchUp = NativeLiveCatchUp()
    while isCurrent(request), player.currentItem === item {
      try await Task.sleep(for: .milliseconds(250))
      guard isCurrent(request) else { return }
      if let failure { throw failure }
      if item.status == .failed || player.status == .failed {
        throw item.error ?? player.error ?? NativeHLSError.unavailable
      }
      let now = ProcessInfo.processInfo.systemUptime
      let clock = item.currentTime().seconds
      let playing = player.timeControlStatus == .playing
      if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
        output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
        receivedFrame = true
        lastFrame = now
      }
      let target = await engine?.origin.liveTargetDate()
      guard isCurrent(request) else { return }
      if !aligned, playing, receivedFrame, target != nil {
        item.automaticallyPreservesTimeOffsetFromLive = false
        let offset = item.recommendedTimeOffsetFromLive
        if offset.seconds.isFinite { item.configuredTimeOffsetFromLive = offset }
        let deadline = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          item.cancelPendingSeeks()
        }
        let positioned = await item.seek(to: .positiveInfinity, toleranceBefore: .zero, toleranceAfter: .zero)
        deadline.cancel()
        guard isCurrent(request) else { return }
        guard positioned else { throw PreviewError.startupTimeout }
        aligned = true
        receivedFrame = false
        lastFrame = ProcessInfo.processInfo.systemUptime
        continue
      }
      if aligned && receivedFrame && now - lastFrame < 1 { isReady = true }
      if now - lastFrame > 8 { throw PreviewError.missingVideo }
      if !aligned, now - started > 15 { throw PreviewError.startupTimeout }
      let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
        .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }
        .map { $0.end.seconds - clock }.max() ?? 0
      let source = await engine?.origin.snapshot()
      guard isCurrent(request) else { return }
      if let forwardBuffer = source?.forwardBuffer { item.preferredForwardBufferDuration = forwardBuffer }
      switch bufferedRecovery.observe(clock: clock, uptime: now, buffer: buffer,
        minimumBuffer: item.preferredForwardBufferDuration,
        waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate, allowed: native && aligned) {
      case .resume: player.playImmediately(atRate: 1)
      case .restart: throw NativeHLSError.timeout
      case .awaitingProgress: continue
      case .none: break
      }
      let rate = catchUp.observe(.init(uptime: now, clock: clock, playbackDate: item.currentDate(),
        targetDate: target, rendition: "\(item.presentationSize)", isPlaying: playing, buffer: buffer,
        allowed: native && aligned, hasFreshVideo: receivedFrame && now - lastFrame < 3,
        playbackRate: player.rate, normalOffset: 0))
      if playing, abs(player.rate - rate) >= 0.005 { player.rate = rate }
    }
  }
}
