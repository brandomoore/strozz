import AVFoundation
import Combine
import XCTest

#if os(tvOS)
  @testable import Strozz
#else
  @testable import StrozzMobile
#endif

private actor KickSourceGate {
  private var continuations: [String: CheckedContinuation<StreamPlayback, Error>] = [:]
  private(set) var requests: [PlatformLiveTarget] = []

  func resolve(_ source: PlatformLiveTarget) async throws -> StreamPlayback {
    requests.append(source)
    return try await withCheckedThrowingContinuation { continuations[source.id] = $0 }
  }

  func reply(_ source: PlatformLiveTarget) {
    continuations.removeValue(forKey: source.id)?.resume(
      returning: StreamPlayback(
        master: URL(string: "https://fixture.live-video.net/master.m3u8")!, qualities: []))
  }
}

@MainActor
final class KickSharedPlayerTests: XCTestCase {
  func testKickDoesNotBecomeATwitchRecommendationHistoryEntry() {
    let defaults = UserDefaults.standard
    let key = "kick-shared-player-history-\(UUID().uuidString)"
    let preference = RecommendationPreferences.enabledDefaultsKey
    let previous = defaults.object(forKey: preference)
    defaults.set(true, forKey: preference)
    defer {
      defaults.removeObject(forKey: key)
      if let previous {
        defaults.set(previous, forKey: preference)
      } else {
        defaults.removeObject(forKey: preference)
      }
    }
    let history = WatchHistoryService(storageKey: key)
    history.record(
      KickChannel(
        slug: "fixture", displayName: "Creator", title: "Live",
        category: "Games", viewerCount: 42, isLive: true, chatroomID: 123, imageURL: nil
      ).followedChannel)
    XCTAssertTrue(history.entries.isEmpty)
  }

  func testKickIdentityDoesNotAliasATwitchChannelOrViewerCount() throws {
    let kick = KickChannel(
      slug: "fixture", displayName: "Creator", title: "Live",
      category: "Games", viewerCount: 42, isLive: true, chatroomID: 123, imageURL: nil
    ).followedChannel
    let twitch = FollowedChannel(
      id: "twitch-user", login: "fixture", displayName: "Creator",
      title: "Live", gameName: "Games", viewerCount: 12, thumbnailURL: nil, profileImageURL: nil,
      isLive: true)
    XCTAssertEqual(kick.platform, .kick)
    XCTAssertNotEqual(kick.channelKey, twitch.channelKey)
    XCTAssertEqual(kick.livePlatformViewerCounts.first?.platform, .kick)
    XCTAssertEqual(twitch.livePlatformViewerCounts.first?.platform, .twitch)
    XCTAssertThrowsError(
      try PlatformLiveTarget.validated(platform: .twitch, input: "https://kick.com/fixture"))
    XCTAssertEqual(
      try PlatformLiveTarget.validated(platform: .kick, input: "https://kick.com/fixture").channel,
      "fixture")
    XCTAssertEqual(
      PlatformLiveTarget(platform: .kick, channel: "fixture").watchURL?.host, "kick.com")
    XCTAssertEqual(
      PlatformLiveTarget(platform: .youtube, channel: "UCfixture").watchURL?.path,
      "/channel/UCfixture/live")
  }

  #if os(tvOS)
    func testKickUsesTheExistingTVPlayerAndCannotSendThroughTwitch() async {
      let model = PlayerModel()
      model.activeChannel = "fixture"
      let view = PlayerView(
        channel: "fixture", auth: TwitchAuthSession(), initialPlatform: .kick, model: model)
      view.initializeLiveSource()
      XCTAssertEqual(view.currentLiveTarget, .init(platform: .kick, channel: "fixture"))
      XCTAssertEqual(view.streamSourceOptions, ["Kick"])
      XCTAssertEqual(view.selectedStreamSourceIndex, 0)
      XCTAssertTrue(view.isNativeLiveVideo)
      XCTAssertFalse(view.controlOrder.contains(.rewards))
      XCTAssertNil(view.youtubeViewerCountForCurrentStream)
      let broadcast = await view.resolveBroadcastVODIfNeeded()
      XCTAssertNil(broadcast)
      view.submitChatMessage()
      XCTAssertNotNil(model.chatSendError)
      XCTAssertNil(model.chat.channel)
    }

    func testStaleKickResolutionCannotReplaceTheExistingTVPlayersNewSource() async throws {
      let gate = KickSourceGate()
      let kick = PlatformLiveTarget(platform: .kick, channel: "fixture")
      let model = PlayerModel(resolveLivePlayback: { try await gate.resolve($0) })
      model.activeChannel = kick.channel
      model.isUserPaused = true
      let view = PlayerView(
        channel: kick.channel, auth: TwitchAuthSession(), initialPlatform: .kick, model: model)
      view.initializeLiveSource()
      view.beginPlaybackTelemetry()
      let player = model.player
      let loading = Task { await view.load(maxAttempts: 1) }
      for _ in 0..<100 {
        if await gate.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      view.resetAltSourceWork()
      model.livePlatform = .twitch
      await gate.reply(kick)
      await loading.value
      XCTAssertTrue(model.player === player)
      XCTAssertNil(player.currentItem)
      XCTAssertTrue(model.isUserPaused)
      view.stopPlaybackTelemetry(reason: "test_finished")
    }
  #else
    func testKickUsesTheExistingMobileModelAndRejectsStaleSourceCompletion() async throws {
      let gate = KickSourceGate()
      let first = PlatformLiveTarget(platform: .kick, channel: "fixture")
      let model = MobilePlaybackModel(
        resolve: { _ in throw KickPlaybackService.Failure.restricted },
        resolveKick: { slug in
          let playback = try await gate.resolve(.init(platform: .kick, channel: slug))
          return .init(
            channel: KickChannel(
              slug: slug, displayName: slug, title: "", category: "",
              viewerCount: nil, isLive: true, chatroomID: nil, imageURL: nil), playback: playback)
        })
      model.activateAudioSession = {}
      model.loadKickMetadata = { _ in throw KickPlaybackService.Failure.restricted }
      model.loadMetadata = { _ in nil }
      var changes: [PlatformLiveTarget] = []
      model.onSourceChanged = { changes.append($0) }
      defer { model.stop() }
      let player = model.player
      model.start(channel: first.channel, platform: .kick)
      for _ in 0..<100 {
        if await gate.requests.count == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      model.selectMode(.chatOnly)
      model.switchSource(.init(platform: .twitch, channel: "other"))
      await gate.reply(first)
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertTrue(model.player === player)
      XCTAssertNil(player.currentItem)
      XCTAssertEqual(model.source.platform, .twitch)
      XCTAssertTrue(model.isPaused)
      XCTAssertEqual(model.mode, .chatOnly)
      XCTAssertNil(model.kickChannel)
      XCTAssertEqual(changes, [.init(platform: .twitch, channel: "other")])
    }
  #endif
}

@MainActor
private final class ExistingKickPlayer {
  #if os(tvOS)
    let model: PlayerModel
    let view: PlayerView
    private var loadTask: Task<Void, Never>?
    private var readiness: AnyCancellable?
    private let savedQuality = UserDefaults.standard.object(forKey: PersistenceKey.preferredQuality)
    init(_ source: PlatformLiveTarget) {
      let model = PlayerModel()
      self.model = model
      model.activeChannel = source.channel
      model.player.isMuted = true
      view = PlayerView(
        channel: source.channel, auth: TwitchAuthSession(), initialPlatform: source.platform,
        model: model)
      view.initializeLiveSource()
      view.preferredQuality = "Auto"
    }
    var player: AVPlayer { model.player }
    var qualities: [StreamQuality] { model.playback?.qualities ?? [] }
    var decodedSize: CGSize? { model.playbackTelemetry.decodedVideoSize }
    var isLoading: Bool { model.isLoading }
    var error: String? {
      model.errorMessage ?? model.nativeFallbackReason ?? (model.isOffline ? "Offline" : nil)
    }
    var source: PlatformLiveTarget { view.currentLiveTarget }
    var qualityID: String? { qualities.first { $0.name == view.preferredQuality }?.id }
    func start() {
      // Supply the existing view's readiness subscription in this headless test.
      readiness = model.player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)
        .sink { [weak model] _ in
          Task { @MainActor in model?.revealPlaybackIfStarted() }
        }
      view.configurePlayerForLive()
      view.beginPlaybackTelemetry()
      view.connectCurrentLiveChat()
      loadTask = Task { await view.loadInitialSource() }
    }
    func selectQuality(_ id: String?) {
      view.preferredQuality =
        id.flatMap { selected in qualities.first { $0.id == selected }?.name } ?? "Auto"
      view.applyQualityPreference(view.preferredQuality)
    }
    func switchSource(_ source: PlatformLiveTarget) {
      if source.platform == .kick {
        view.switchToKickSource(channel: source.channel)
      } else {
        model.activeChannel = source.channel
        view.switchToTwitchSource(refresh: true)
      }
    }
    func stop() {
      readiness?.cancel()
      view.resetAltSourceWork()
      loadTask?.cancel()
      model.channelMetadataTask?.cancel()
      model.nativeRefreshTask?.cancel()
      view.cancelNativeStartup()
      view.stopPlaybackWatchdog()
      view.stopLatencyMonitor()
      view.stopPlaybackTelemetry(reason: "test_finished")
      model.nativeHLS?.stop()
      model.player.pause()
      model.player.replaceCurrentItem(with: nil)
      model.chat.disconnect()
      model.eventSub.stop()
      model.hermes.stop()
      if let savedQuality {
        UserDefaults.standard.set(savedQuality, forKey: PersistenceKey.preferredQuality)
      } else {
        UserDefaults.standard.removeObject(forKey: PersistenceKey.preferredQuality)
      }
    }
  #else
    let model = MobilePlaybackModel(muted: true)
    private let initial: PlatformLiveTarget
    init(_ source: PlatformLiveTarget) { initial = source }
    var player: AVPlayer { model.player }
    var qualities: [StreamQuality] { model.qualities }
    var decodedSize: CGSize? { model.decodedVideoSize }
    var isLoading: Bool { model.isLoading }
    var error: String? { model.errorMessage }
    var source: PlatformLiveTarget { model.source }
    var qualityID: String? { if case .fixed(let id) = model.selection { id } else { nil } }
    func start() { model.start(channel: initial.channel, platform: initial.platform) }
    func selectQuality(_ id: String?) { model.select(id.map { .fixed($0) } ?? .native) }
    func switchSource(_ source: PlatformLiveTarget) { model.switchSource(source) }
    func stop() { model.stop() }
  #endif
}

@MainActor
final class KickSharedPlayerLiveTests: XCTestCase {
  private func requireLive() throws {
    guard ProcessInfo.processInfo.environment["STROZZ_KICK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Explicit live existing-player Kick verification only")
    }
  }
  private var kick: PlatformLiveTarget {
    .init(
      platform: .kick, channel: ProcessInfo.processInfo.environment["STROZZ_KICK_CHANNEL"] ?? "xqc")
  }

  private func waitForVideo(_ player: ExistingKickPlayer, maximumHeight: CGFloat? = nil)
    async throws
  {
    for _ in 0..<450 {
      if let error = player.error {
        throw NSError(
          domain: "KickSharedPlayerTest", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
      }
      if !player.isLoading, player.player.timeControlStatus == .playing,
        let size = player.decodedSize, size.height > 0,
        maximumHeight.map({ size.height <= $0 }) ?? true
      {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Existing \(player.source.platform.title) player did not produce decoded video")
    throw CancellationError()
  }

  func testStandaloneKickDecodesInTheExistingPlayerAndChangesQuality() async throws {
    try requireLive()
    let playback = ExistingKickPlayer(kick)
    defer { playback.stop() }
    let renderer = playback.player
    playback.start()
    try await waitForVideo(playback)
    let low = try XCTUnwrap(playback.qualities.last { !$0.isAudioOnly })
    playback.selectQuality(low.id)
    try await waitForVideo(playback, maximumHeight: 480)
    XCTAssertEqual(playback.qualityID, low.id)
    playback.selectQuality(nil)
    try await waitForVideo(playback)
    XCTAssertNil(playback.qualityID)
    XCTAssertTrue(playback.player === renderer)
  }

  func testTwitchKickSwitchesKeepTheExistingPlayer() async throws {
    try requireLive()
    guard let channel = ProcessInfo.processInfo.environment["STROZZ_KICK_SWITCH_TWITCH_CHANNEL"]
    else {
      throw XCTSkip("A currently live Twitch source is required")
    }
    let twitch = PlatformLiveTarget(platform: .twitch, channel: channel)
    let playback = ExistingKickPlayer(twitch)
    defer { playback.stop() }
    let renderer = playback.player
    playback.start()
    try await waitForVideo(playback)
    playback.switchSource(kick)
    try await waitForVideo(playback)
    XCTAssertEqual(playback.source.platform, .kick)
    playback.switchSource(twitch)
    try await waitForVideo(playback)
    XCTAssertEqual(playback.source.platform, .twitch)
    XCTAssertTrue(playback.player === renderer)
  }

  func testExistingPlayerKickLatencyAgainstPlainHLS() async throws {
    try requireLive()
    let playback = ExistingKickPlayer(kick)
    let baseline = AVPlayer(
      url: try await KickPlaybackService.resolve(kick.channel).playback.master)
    baseline.isMuted = true
    defer {
      playback.stop()
      baseline.pause()
      baseline.replaceCurrentItem(with: nil)
    }
    playback.start()
    baseline.play()
    var native: [Double] = []
    var plain: [Double] = []
    for second in 0..<90 {
      try await Task.sleep(for: .seconds(1))
      if let error = playback.error { return XCTFail(error) }
      if second >= 30, playback.decodedSize != nil, playback.player.timeControlStatus == .playing,
        baseline.timeControlStatus == .playing, let a = playback.player.currentItem?.currentDate(),
        let b = baseline.currentItem?.currentDate()
      {
        native.append(Date().timeIntervalSince(a))
        plain.append(Date().timeIntervalSince(b))
      }
    }
    XCTAssertGreaterThanOrEqual(native.count, 30)
    guard !native.isEmpty else { return }
    let a = native.sorted()[native.count / 2]
    let b = plain.sorted()[plain.count / 2]
    let attachment = XCTAttachment(
      string:
        "{\"player\":\"existing\",\"platform\":\"\(PlaybackTelemetrySentry.platform)\",\"native_median_seconds\":\(a),\"plain_hls_median_seconds\":\(b),\"decoded_samples\":\(native.count)}"
    )
    attachment.name = "Existing player Kick latency.json"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThan(a, b)
  }
}
