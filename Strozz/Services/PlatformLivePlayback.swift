import AVFoundation
import CoreVideo
import Foundation
import Observation

enum LivePlatform: String, CaseIterable, Codable, Sendable {
  case twitch, kick, youtube
  var title: String {
    switch self {
    case .twitch: "Twitch"
    case .kick: "Kick"
    case .youtube: "YouTube"
    }
  }
}

struct PlatformLiveTarget: Identifiable, Equatable, Sendable {
  enum Failure: LocalizedError {
    case invalidChannel(LivePlatform)
    case missingQuality
    var errorDescription: String? {
      switch self {
      case .invalidChannel(let platform):
        String(localized: "Enter a valid \(platform.title) channel name or channel URL.")
      case .missingQuality:
        String(localized: "That quality is no longer available. Choose Auto or another quality.")
      }
    }
  }
  let platform: LivePlatform
  let channel: String
  var id: String { "\(platform.rawValue):\(channel)" }

  static func validated(platform: LivePlatform, input: String) throws -> Self {
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    switch platform {
    case .kick: return Self(platform: platform, channel: try KickPlaybackService.slug(from: input))
    case .twitch:
      let name: String
      if input.contains("://") {
        guard let url = URL(string: input), url.scheme == "https",
          ["twitch.tv", "www.twitch.tv"].contains(url.host?.lowercased() ?? ""),
          url.user == nil, url.password == nil, url.pathComponents.count == 2
        else { throw Failure.invalidChannel(platform) }
        name = url.lastPathComponent
      } else {
        name = input.hasPrefix("@") ? String(input.dropFirst()) : input
      }
      guard name.range(of: #"^[A-Za-z0-9_]{1,25}$"#, options: .regularExpression) != nil else {
        throw Failure.invalidChannel(platform)
      }
      return Self(platform: platform, channel: name.lowercased())
    case .youtube:
      if input.contains("://") {
        guard let url = URL(string: input), url.scheme == "https",
          ["youtube.com", "www.youtube.com", "youtu.be"].contains(url.host?.lowercased() ?? ""),
          url.user == nil, url.password == nil
        else { throw Failure.invalidChannel(platform) }
      } else {
        guard input.range(of: #"^[@A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil
        else {
          throw Failure.invalidChannel(platform)
        }
      }
      return Self(platform: platform, channel: input)
    }
  }
}

@MainActor
@Observable
final class PlatformLivePlayback {
  struct Resolution: Sendable {
    let playback: StreamPlayback
    let title: String
    let viewers: Int?
  }
  typealias Resolver = @Sendable (PlatformLiveTarget) async throws -> Resolution
  private(set) var player = AVPlayer()
  let chat = ChatService()
  let telemetry: PlaybackTelemetryRecorder
  private(set) var target: PlatformLiveTarget
  private(set) var sources: [PlatformLiveTarget]
  private(set) var title = ""
  private(set) var viewers: Int?
  private(set) var isLoading = true
  private(set) var isPaused = false
  private(set) var errorMessage: String?
  private(set) var qualities: [StreamQuality] = []
  private(set) var qualityID: String?
  private(set) var latencySeconds: Double?
  private(set) var decodedSize: CGSize?
  private(set) var sourceStatus = String(localized: "Loading stream")
  var isAudioOnly: Bool { qualities.first { $0.id == qualityID }?.isAudioOnly == true }
  @ObservationIgnored private let resolve: Resolver
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var monitor: Task<Void, Never>?
  @ObservationIgnored private var engine: NativeLowLatencyHLS?
  @ObservationIgnored private var output: AVPlayerItemVideoOutput?
  @ObservationIgnored private var recovery = NativePlaybackRecovery()
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var backgrounded = false
  @ObservationIgnored private var mediaServicesUnavailable = false
  @ObservationIgnored private var alignmentComplete = false
  @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []

  init(
    target: PlatformLiveTarget, sources: [PlatformLiveTarget] = [],
    resolve: @escaping Resolver = PlatformLivePlayback.resolveSource,
    telemetry: PlaybackTelemetryRecorder = PlaybackTelemetryRecorder()
  ) {
    self.target = target
    self.sources = [target] + sources.filter { $0.platform != target.platform }
    self.resolve = resolve
    self.telemetry = telemetry
    #if targetEnvironment(simulator)
      player.isMuted = true
    #endif
  }

  func start() {
    if audioObservers.isEmpty {
      let center = NotificationCenter.default
      audioObservers = [
        center.addObserver(
          forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
          let began =
            (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            == AVAudioSession.InterruptionType.began.rawValue
          Task { @MainActor [weak self] in
            guard let self else { return }
            if began {
              self.isPaused = true
              self.player.pause()
            }
            self.telemetry.recordEvent("audio_interruption", flags: ["began": began])
          }
        },
        center.addObserver(
          forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
          let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          Task { @MainActor [weak self] in
            guard let self else { return }
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
              self.isPaused = true
              self.player.pause()
            }
            self.telemetry.recordEvent(
              "audio_route_changed",
              counters: reason.map { ["route_change_reason": Int(clamping: $0)] } ?? [:])
          }
        },
        center.addObserver(
          forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.mediaServicesReset() }
        },
        center.addObserver(
          forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.mediaServicesUnavailable = true
            self.generation = UUID()
            self.task?.cancel()
            self.monitor?.cancel()
            self.clearPlayback()
            self.telemetry.recordEvent("audio_media_services_lost", level: .warning)
          }
        },
      ]
    }
    load(target, deliberate: true)
  }
  func switchSource(_ target: PlatformLiveTarget) {
    guard target != self.target else { return }
    qualityID = nil
    load(target, deliberate: true)
  }
  func selectQuality(_ id: String?) {
    guard id == nil || qualities.contains(where: { $0.id == id }) else { return }
    qualityID = id
    load(target, deliberate: true)
  }
  func retry() { load(target, deliberate: true) }
  func togglePause() {
    isPaused.toggle()
    if isPaused {
      player.pause()
      if player.currentItem?.status == .readyToPlay { isLoading = false }
    } else {
      do {
        try PlaybackAudioSession.activate()
        if !isPaused { player.play() }
      } catch { fail(error.localizedDescription) }
    }
    telemetry.recordEvent("viewer_pause_changed", flags: ["user_paused": isPaused])
  }
  func goLive() {
    isPaused = false
    load(target, deliberate: true)
  }
  func sceneActive(_ active: Bool) {
    guard !stopped else { return }
    if !active {
      backgrounded = true
      generation = UUID()
      task?.cancel()
      monitor?.cancel()
      clearPlayback()
      telemetry.recordEvent("app_backgrounded")
    } else if backgrounded {
      backgrounded = false
      load(target, deliberate: true)
    }
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    generation = UUID()
    task?.cancel()
    monitor?.cancel()
    clearPlayback()
    for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    audioObservers.removeAll()
    telemetry.endSession(reason: "player_closed")
  }

  private func clearPlayback() {
    player.pause()
    player.replaceCurrentItem(with: nil)
    output = nil
    engine?.stop()
    engine = nil
    chat.disconnect()
  }

  func mediaServicesReset() {
    guard !stopped else { return }
    mediaServicesUnavailable = false
    clearPlayback()
    player = AVPlayer()
    #if targetEnvironment(simulator)
      player.isMuted = true
    #endif
    telemetry.recordEvent("audio_media_services_reset", level: .warning)
    load(target, deliberate: false)
  }

  private func load(_ requested: PlatformLiveTarget, deliberate: Bool) {
    guard !stopped, !backgrounded, !mediaServicesUnavailable else { return }
    task?.cancel()
    monitor?.cancel()
    generation = UUID()
    let request = generation
    clearPlayback()
    isLoading = true
    errorMessage = nil
    alignmentComplete = false
    latencySeconds = nil
    decodedSize = nil
    sourceStatus = String(localized: "Loading stream")
    if deliberate { recovery = NativePlaybackRecovery() }
    let oldTarget = target
    if oldTarget != requested {
      title = ""
      viewers = nil
      qualities = []
    }
    target = requested
    sources.removeAll { $0.platform == requested.platform }
    sources.append(requested)
    if oldTarget != requested || telemetry.sessionID == nil {
      telemetry.beginSession(
        channel: requested.channel, playbackMode: requested.platform.rawValue,
        attributes: ["source": requested.platform.rawValue, "playback_profile": "nativeLowLatency"])
      telemetry.startSchedulerMonitoring()
    }
    telemetry.recordEvent("load_started", attributes: ["source": requested.platform.rawValue])
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await resolve(requested)
        guard current(request) else { return }
        title = result.title
        viewers = result.viewers
        qualities = result.playback.qualities
        if let qualityID, !qualities.contains(where: { $0.id == qualityID }) {
          throw PlatformLiveTarget.Failure.missingQuality
        }
        let url =
          qualityID.flatMap { id in qualities.first { $0.id == id }?.url } ?? result.playback.master
        let native = requested.platform != .youtube && !isAudioOnly
        if native {
          let recorder = telemetry
          let session = telemetry.sessionID
          engine = NativeLowLatencyHLS(
            sourceURL: requested.platform == .kick ? result.playback.master : url,
            headers: requested.platform == .kick
              ? ["User-Agent": "Strozz/0.68.0"] : PlaybackService.streamHeaders, history: 30,
            fixedRenditionID: requested.platform == .kick ? qualityID : nil,
            diagnostic: { [weak self, weak recorder] detail in
              let dispatchedAt = ProcessInfo.processInfo.systemUptime
              Task { @MainActor in
                guard let self, self.current(request), let recorder, recorder.sessionID == session
                else { return }
                let optional = ["manifest_retry", "capacity_probe"].contains(
                  detail.attributes["operation"] ?? "")
                recorder.recordEvent(
                  optional ? "native_hls_background_probe" : "native_hls_failure",
                  level: optional ? .warning : .error,
                  attributes: detail.attributes.merging(["native_generation": request.uuidString]) {
                    _, new in new
                  },
                  metrics: PlaybackTelemetryRecorder.nativeDeliveryMetrics(
                    detail.metrics, dispatchedAt: dispatchedAt),
                  counters: detail.counters)
              }
            },
            trace: { [weak self, weak recorder] detail in
              let dispatchedAt = ProcessInfo.processInfo.systemUptime
              Task { @MainActor in
                guard let self, self.current(request), let recorder, recorder.sessionID == session
                else { return }
                recorder.recordEvent(
                  detail.event.rawValue,
                  attributes: detail.attributes.merging(["native_generation": request.uuidString]) {
                    _, new in new
                  },
                  metrics: PlaybackTelemetryRecorder.nativeDeliveryMetrics(
                    detail.metrics, dispatchedAt: dispatchedAt),
                  counters: detail.counters)
              }
            }
          ) { [weak self] reason in
            Task { @MainActor in
              guard let self, self.current(request) else { return }
              self.recover(reason)
            }
          }
        }
        let asset = AVURLAsset(
          url: engine?.assetURL ?? url,
          options: [
            "AVURLAssetHTTPHeaderFieldsKey": requested.platform == .youtube
              ? AltSourceService.mediaHTTPHeaders
              : requested.platform == .kick
                ? ["User-Agent": "Strozz/0.68.0"] : PlaybackService.streamHeaders
          ])
        if let engine { asset.resourceLoader.setDelegate(engine, queue: engine.queue) }
        let item = AVPlayerItem(asset: asset)
        player.allowsExternalPlayback = !native
        item.preferredForwardBufferDuration = native ? 3 : 0
        item.audioTimePitchAlgorithm = .timeDomain
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        let tap = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
        item.add(tap)
        output = tap
        try PlaybackAudioSession.activate()
        guard current(request) else { return }
        player.replaceCurrentItem(with: item)
        telemetry.trackItem(item, source: requested.platform.rawValue)
        connectChat()
        if !isPaused { player.play() }
        startMonitor(item: item, request: request)
      } catch {
        guard current(request) else { return }
        telemetry.recordEvent(
          "load_failed", level: .error,
          attributes: PlaybackTelemetryRecorder.errorAttributes(error))
        if recovery.takeResolutionRetry(for: error) {
          try? await Task.sleep(for: .milliseconds(500))
          guard current(request) else { return }
          load(requested, deliberate: false)
        } else {
          fail(error.localizedDescription)
        }
      }
    }
  }

  private func current(_ request: UUID) -> Bool {
    request == generation && !Task.isCancelled && !stopped && !backgrounded
  }
  private func recover(_ reason: NativeHLSError) {
    guard recovery.takeRetry(for: reason) else {
      fail(reason.rawValue)
      return
    }
    telemetry.recordEvent(
      "native_hls_retry", level: .warning, attributes: ["reason": reason.rawValue])
    load(target, deliberate: false)
  }
  private func fail(_ message: String) {
    monitor?.cancel()
    clearPlayback()
    errorMessage = message
    isLoading = false
    telemetry.recordEvent("playback_failed", level: .error)
  }
  private func connectChat() {
    chat.disconnect()
    chat.youtubeMergeEnabled = false
    chat.kickMergeEnabled = false
    switch target.platform {
    case .twitch: chat.connect(to: target.channel)
    case .kick:
      chat.configureExperimentalKickMerge(enabled: true, channelOrURL: target.channel)
    case .youtube:
      chat.configureExperimentalYouTubeMerge(enabled: true, channelOrURL: target.channel)
    }
  }
  private func startMonitor(item: AVPlayerItem, request: UUID) {
    monitor = Task { [weak self] in
      let started = ProcessInfo.processInfo.systemUptime
      var lastClock = item.currentTime().seconds
      var lastProgress = started
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, current(request), player.currentItem === item else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if item.status == .failed {
          telemetry.recordEvent(
            "player_item_failed", level: .error,
            attributes: PlaybackTelemetryRecorder.errorAttributes(item.error))
          recover(.unavailable)
          return
        }
        let clock = item.currentTime().seconds
        if clock > lastClock + 0.05 || isPaused { lastProgress = now }
        lastClock = clock
        let buffer =
          item.loadedTimeRanges.map(\.timeRangeValue)
          .filter { $0.start.seconds <= clock && $0.end.seconds >= clock }.map {
            $0.end.seconds - clock
          }.max() ?? 0
        let nativeSnapshot = await engine?.origin.snapshot()
        guard current(request), player.currentItem === item else { return }
        if let preferred = nativeSnapshot?.forwardBuffer {
          item.preferredForwardBufferDuration = preferred
        }
        if !alignmentComplete, item.status == .readyToPlay, !item.seekableTimeRanges.isEmpty {
          alignmentComplete = true
          if isPaused { isLoading = false }
          if !isPaused {
            let timeout = Task { @MainActor in
              do { try await Task.sleep(for: .seconds(4)) } catch { return }
              if self.current(request) { item.cancelPendingSeeks() }
            }
            let aligned = await item.seek(to: .positiveInfinity)
            timeout.cancel()
            guard current(request), player.currentItem === item else { return }
            telemetry.recordEvent("native_startup_alignment_completed", flags: ["aligned": aligned])
            player.play()
          }
        }
        if isAudioOnly || isPaused, item.status == .readyToPlay { isLoading = false }
        if player.timeControlStatus == .playing, let output,
          output.hasNewPixelBuffer(forItemTime: item.currentTime()),
          let frame = output.copyPixelBuffer(
            forItemTime: item.currentTime(), itemTimeForDisplay: nil)
        {
          decodedSize = CGSize(
            width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
          telemetry.videoFrameObserved(size: decodedSize)
          isLoading = false
        }
        if let date = item.currentDate() { latencySeconds = max(0, Date().timeIntervalSince(date)) }
        sourceStatus =
          isAudioOnly
          ? String(localized: "Audio only")
          : engine == nil
            ? String(localized: "Native HLS") : String(localized: "Native low latency")
        telemetry.recordItemLogs()
        telemetry.recordSnapshot(
          PlaybackTelemetrySnapshot(
            attributes: [
              "source": target.platform.rawValue,
              "time_control_status": player.timeControlStatus == .playing ? "playing" : "waiting",
              "quality": qualityID ?? "Auto", "playback_profile": "nativeLowLatency",
            ],
            metrics: [
              "playhead_seconds": clock, "buffer_ahead_seconds": buffer,
              "wall_clock_latency_seconds": latencySeconds ?? .nan,
            ],
            flags: [
              "user_paused": isPaused, "loading": isLoading,
              "playback_requested": !isPaused, "background": false,
            ]))
        if let engine {
          do {
            _ = try await engine.origin.updateControlledPlayback(buffer: buffer, budget: .init())
          } catch {
            guard current(request) else { return }
            recover(NativeHLSError.classify(error))
            return
          }
        }
        if !isPaused, now - lastProgress > 20 || (isLoading && now - started > 30) {
          recover(.timeout)
          return
        }
      }
    }
  }

  nonisolated static func resolveSource(_ target: PlatformLiveTarget) async throws -> Resolution {
    switch target.platform {
    case .kick:
      let resolved = try await KickPlaybackService.resolve(target.channel)
      return Resolution(
        playback: resolved.playback, title: resolved.channel.displayName,
        viewers: resolved.channel.viewerCount)
    case .twitch:
      return Resolution(
        playback: try await PlaybackService.resolve(for: target.channel),
        title: target.channel, viewers: nil)
    case .youtube:
      let live = try await AltSourceService.youtubeLive(forTarget: target.channel)
      return Resolution(
        playback: StreamPlayback(master: live.hlsMaster, qualities: []),
        title: target.channel, viewers: live.concurrentViewers)
    }
  }
}
