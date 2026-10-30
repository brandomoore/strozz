import XCTest

#if os(tvOS)
  @testable import Strozz
#else
  @testable import StrozzMobile
#endif

@MainActor
final class CreatorLiveSessionTests: XCTestCase {
  private let twitch = PlatformLiveTarget(platform: .twitch, channel: "creator")
  private let kick = PlatformLiveTarget(platform: .kick, channel: "creator-kick")
  private let youtube = PlatformLiveTarget(platform: .youtube, channel: "@creator-video")

  func testBroadcastPushOverridesLaggingMetadataAndKeepsLinkedChat() async throws {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, kick])
    try await eventually { session.viewerCounts.count == 2 }
    session.hermes.prepareBroadcastFixture(channel: twitch.channel)
    let chatID = session.chat.sessionID
    session.hermes.handle(HermesBroadcastTests.frame("stream-down", extra: ",\"server_time\":100"))
    XCTAssertEqual(session.twitchBroadcastStatus?.status, .offline)
    XCTAssertEqual(session.twitchBroadcastStatus?.target, twitch)
    XCTAssertEqual(session.twitchBroadcastStatus?.reason, "twitch_event")
    await session.refreshStatistics(epoch: session.generation)
    XCTAssertEqual(session.twitchBroadcastStatus?.status, .offline)
    XCTAssertEqual(session.viewerCounts.map(\.platform), [.kick])
    XCTAssertEqual(session.chat.sessionID, chatID)
    session.selectVideo(kick)
    XCTAssertEqual(session.twitchBroadcastStatus?.target, twitch)
    XCTAssertEqual(session.videoTarget, kick)
    session.hermes.invalidateBroadcastStatus()
    XCTAssertEqual(session.twitchBroadcastStatus?.status, .unknown)
    session.suspend()
    XCTAssertNil(session.twitchBroadcastStatus)
  }

  func testStatusFallbackDetectsMissedEndAndNetworkFailureRemainsUnknown() async throws {
    var status = CreatorViewerSnapshot.live(71)
    let session = makeSession(loadTwitch: { _ in status })
    defer { session.stop() }
    session.start(twitch)
    try await eventually { session.twitchBroadcastStatus?.status == .live }
    status = .offline
    await session.refreshStatistics(epoch: session.generation)
    try await eventually { session.twitchBroadcastStatus?.status == .offline }
    XCTAssertEqual(session.twitchBroadcastStatus?.reason, "status_check")
    status = .unknown
    await session.refreshStatistics(epoch: session.generation)
    try await eventually { session.twitchBroadcastStatus?.status == .unknown }
    session.selectVideo(.init(platform: .twitch, channel: "replacement"))
    XCTAssertNil(session.twitchBroadcastStatus)
  }

  func testVideoSwitchPreservesCreatorTransportsMessagesAndCounts() async throws {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, kick, youtube])
    await session.refreshStatistics(epoch: session.generation)
    try await eventually { session.viewerCounts.count == 3 }
    let epoch = session.generation
    let chatSession = session.chat.sessionID
    session.chat.messages = [ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
      text: "Keep this conversation", twitchEmoteURLs: [:])]
    session.chat.youtubeStatusMessage = "existing YouTube transport"
    session.chat.kickStatusMessage = "existing Kick transport"
    let messages = session.chat.messages.map(\.id)
    let counts = session.viewerCounts

    for target in [kick, youtube, twitch, kick] {
      session.selectVideo(target)
      session.configureChat(kickEnabled: true, youtubeEnabled: true)
      XCTAssertEqual(session.generation, epoch)
      XCTAssertEqual(session.chat.sessionID, chatSession)
      XCTAssertEqual(session.chat.messages.map(\.id), messages)
      XCTAssertEqual(session.chat.channel, twitch.channel)
      XCTAssertEqual(session.chat.kickStatusMessage, "existing Kick transport")
      XCTAssertEqual(session.chat.youtubeStatusMessage, "existing YouTube transport")
      XCTAssertEqual(session.viewerCounts, counts)
      XCTAssertEqual(session.videoTarget, target)
    }
  }

  func testKickRootDoesNotGuessTwitchButCanExplicitlyLinkIt() async throws {
    let session = makeSession()
    defer { session.stop() }
    session.start(kick)
    try await eventually { session.viewerCounts.count == 1 }
    XCTAssertNil(session.chat.channel)
    XCTAssertEqual(session.chatPlatform, .kick)
    session.updateLinks([kick, twitch, youtube])
    try await eventually { session.viewerCounts.count == 3 }
    XCTAssertEqual(session.twitchChannel, twitch.channel)
    XCTAssertEqual(session.chat.channel, twitch.channel)
    XCTAssertEqual(session.chatPlatform, .twitch)
    XCTAssertEqual(session.videoTarget, kick)
    XCTAssertEqual(session.viewerCounts.first(where: { $0.platform == .twitch })?.count, 71)
  }

  func testFeedPreferencesDoNotDisableViewerStatistics() async throws {
    let session = makeSession()
    defer { session.stop() }
    session.configureChat(kickEnabled: false, youtubeEnabled: false)
    session.start(kick)
    session.updateLinks([twitch, kick, youtube])
    try await eventually { session.viewerCounts.count == 3 }
    XCTAssertFalse(session.chat.kickMergeEnabled)
    XCTAssertFalse(session.chat.youtubeMergeEnabled)
  }

  func testDifferentAccountOnKnownPlatformStartsDifferentCreator() {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, kick])
    let epoch = session.generation
    session.chat.messages = [ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
      text: "Old creator", twitchEmoteURLs: [:])]
    let other = PlatformLiveTarget(platform: .twitch, channel: "someoneelse")
    session.selectVideo(other)
    XCTAssertNotEqual(session.generation, epoch)
    XCTAssertEqual(session.sources?.root, other)
    XCTAssertNil(session.sources?.kick)
    XCTAssertTrue(session.chat.messages.isEmpty)
  }

  func testManualGraphCannotChangePrimaryOrRemovePlayingPeer() {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, kick])
    session.selectVideo(kick)
    let before = session.sources
    session.updateLinks([twitch])
    XCTAssertNotNil(session.identityError)
    XCTAssertEqual(session.sources, before)
    session.updateLinks([.init(platform: .twitch, channel: "unrelated"), kick])
    XCTAssertNotNil(session.identityError)
    XCTAssertEqual(session.sources, before)
    session.updateLinks([twitch, kick, .init(platform: .youtube, channel: "https://example.com")])
    XCTAssertNotNil(session.identityError)
    XCTAssertEqual(session.sources, before)
  }

  func testManualLinksRestoreWhenEnteringThroughPeer() throws {
    let suite = "CreatorLiveSessionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = makeSession(defaults: defaults)
    first.start(twitch)
    first.updateLinks([twitch, kick, youtube])
    first.stop()
    let second = makeSession(defaults: defaults)
    defer { second.stop() }
    second.start(kick)
    XCTAssertEqual(second.sources?.root, kick)
    XCTAssertEqual(second.twitchChannel, twitch.channel)
    XCTAssertEqual(Set(second.targets.map(\.id)), Set([twitch, kick, youtube].map(\.id)))
  }

  func testUnknownCountsExpireAndAuthoritativeOfflineHidesThem() async throws {
    var clock = Date()
    var snapshot = CreatorViewerSnapshot.live(71)
    let session = makeSession(loadTwitch: { _ in snapshot }, now: { clock })
    defer { session.stop() }
    session.start(twitch)
    try await eventually { session.viewerCounts.count == 1 }
    snapshot = .unknown
    clock.addTimeInterval(60)
    await session.refreshStatistics(epoch: session.generation)
    XCTAssertEqual(session.viewerCounts.first?.count, 71)
    clock.addTimeInterval(31)
    await session.refreshStatistics(epoch: session.generation)
    XCTAssertTrue(session.viewerCounts.isEmpty)
    snapshot = .live(24)
    await session.refreshStatistics(epoch: session.generation)
    XCTAssertEqual(session.viewerCounts.first?.count, 24)
    snapshot = .offline
    await session.refreshStatistics(epoch: session.generation)
    XCTAssertTrue(session.viewerCounts.isEmpty)
  }

  func testStaleResolutionCannotReviveStoppedOrReplacedCreator() async throws {
    var continuation: CheckedContinuation<CreatorLiveSources, Error>?
    let session = makeSession(resolve: { root in
      if root.platform == .twitch {
        return try await withCheckedThrowingContinuation { continuation = $0 }
      }
      return CreatorLiveSources(root: root)
    })
    session.start(twitch)
    try await eventually { continuation != nil }
    session.start(kick)
    var old = CreatorLiveSources(root: twitch)
    old.youtube = youtube.channel
    continuation?.resume(returning: old)
    continuation = nil
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(session.sources?.root, kick)
    XCTAssertNil(session.sources?.twitch)
    XCTAssertNil(session.sources?.youtube)
    session.stop()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNil(session.sources)
    XCTAssertNil(session.chat.channel)
    XCTAssertNil(session.chat.kickReceiveTask)
    XCTAssertTrue(session.viewerCounts.isEmpty)
  }

  func testSuspendPreventsResolutionFromRestartingTransports() async throws {
    var continuation: CheckedContinuation<CreatorLiveSources, Error>?
    let session = makeSession(resolve: { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    })
    defer { session.stop() }
    session.start(kick)
    try await eventually { continuation != nil }
    session.suspend()
    var links = CreatorLiveSources(root: kick)
    links.set(twitch)
    continuation?.resume(returning: links)
    continuation = nil
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNil(session.chat.channel)
    XCTAssertNil(session.chat.kickReceiveTask)
    session.resume()
    XCTAssertEqual(session.chat.channel, twitch.channel)
  }

  func testReverseMappingsRequireUniqueExplicitIdentity() {
    XCTAssertNil(CreatorSourceResolver.uniqueKey(for: "same", in: ["one": "same", "two": "same"]))
    XCTAssertEqual(CreatorSourceResolver.uniqueKey(for: "exact", in: ["creator": "exact"]), "creator")
    XCTAssertEqual(CreatorSourceResolver.uniqueKey(for: "https://youtube.com/@Creator",
      in: ["creator": "@creator"], youtube: true), "creator")
    XCTAssertNil(CreatorSourceResolver.youtubeTarget("https://youtube.com.example.com/@creator"))
    XCTAssertNil(CreatorSourceResolver.kickTarget("https://kick.com.example.com/creator"))
    XCTAssertEqual(CreatorSourceResolver.youtubeTarget("channel/UCAbCd"), "UCAbCd")
  }

  func testDiscoveryAttachesTwitchWithoutClearingKickHistory() async throws {
    var continuation: CheckedContinuation<CreatorLiveSources, Error>?
    let session = makeSession(resolve: { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    })
    defer { session.stop() }
    session.start(kick)
    try await eventually { continuation != nil }
    let transport = session.chat.sessionID
    let message = ChatMessage(username: "Viewer", colorHex: nil, badgeKeys: [],
      text: "Already reading Kick", twitchEmoteURLs: [:])
    session.chat.messages = [message]
    var resolved = CreatorLiveSources(root: kick)
    resolved.set(twitch)
    resolved.set(youtube)
    continuation?.resume(returning: resolved)
    continuation = nil
    try await eventually { session.twitchChannel != nil }
    XCTAssertEqual(session.chat.channel, twitch.channel)
    XCTAssertEqual(session.chat.sessionID, transport)
    XCTAssertEqual(session.chat.messages.map(\.id), [message.id])
  }

  func testLateViewerResponseCannotReplaceNewCreatorsCounts() async throws {
    var continuation: CheckedContinuation<CreatorViewerSnapshot, Never>?
    let session = makeSession(loadTwitch: { _ in
      await withCheckedContinuation { continuation = $0 }
    })
    defer { session.stop() }
    session.start(twitch)
    try await eventually { continuation != nil }
    session.start(kick)
    try await eventually { session.viewerCounts.first?.platform == .kick }
    continuation?.resume(returning: .live(999))
    continuation = nil
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(session.viewerCounts.map(\.platform), [.kick])
    XCTAssertEqual(session.viewerCounts.first?.count, 42)
  }

  func testEditingFromPeerKeepsPersistedGraphConsistent() throws {
    let suite = "CreatorLiveSessionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = makeSession(defaults: defaults)
    first.start(twitch)
    first.updateLinks([twitch, kick, youtube])
    first.stop()
    let peer = makeSession(defaults: defaults)
    peer.start(kick)
    let replacement = PlatformLiveTarget(platform: .youtube, channel: "@new-video")
    peer.updateLinks([kick, twitch, replacement])
    peer.stop()
    let restored = makeSession(defaults: defaults)
    defer { restored.stop() }
    restored.start(twitch)
    XCTAssertEqual(restored.sources?.youtube, replacement.channel)
  }

  func testValidNoOpEditClearsPreviousValidationError() {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, .init(platform: .kick, channel: "invalid/channel")])
    XCTAssertNotNil(session.identityError)
    session.updateLinks([twitch])
    XCTAssertNil(session.identityError)
  }

  func testCanonicalYouTubeIdentitiesUseChannelRoutesForAllConsumers() throws {
    let id = "UCabcdefghijklmnopqrstuv"
    for input in [id, "https://www.youtube.com/channel/\(id)", "channel/\(id)"] {
      let canonical = try XCTUnwrap(CreatorSourceResolver.youtubeTarget(input))
      XCTAssertEqual(AltSourceService.liveLookupURL(from: canonical)?.path, "/channel/\(id)/live")
      XCTAssertEqual(ChatService.makeYouTubeLiveLookupURL(from: canonical)?.path, "/channel/\(id)/live")
    }
    for input in ["@Creator", "https://www.youtube.com/@Creator"] {
      let canonical = try XCTUnwrap(CreatorSourceResolver.youtubeTarget(input))
      XCTAssertEqual(AltSourceService.liveLookupURL(from: canonical)?.path, "/@creator/live")
      XCTAssertEqual(ChatService.makeYouTubeLiveLookupURL(from: canonical)?.path, "/@creator/live")
    }
  }

  func testNoOpSaveFencesPendingDiscoveryWithoutResettingChat() async throws {
    var continuation: CheckedContinuation<CreatorLiveSources, Error>?
    let session = makeSession(resolve: { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    })
    defer { session.stop() }
    session.start(twitch)
    try await eventually { continuation != nil }
    let transport = session.chat.sessionID
    session.updateLinks([twitch])
    var discovered = CreatorLiveSources(root: twitch)
    discovered.set(kick)
    continuation?.resume(returning: discovered)
    continuation = nil
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertNil(session.sources?.kick)
    XCTAssertNil(session.chat.kickReceiveTask)
    XCTAssertEqual(session.chat.sessionID, transport)
  }

  func testExplicitRemovalIsAuthoritativeOnRootAndPeerReentry() async throws {
    let suite = "CreatorLiveSessionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = twitch
    let removed = youtube
    let resolver: (PlatformLiveTarget) async throws -> CreatorLiveSources = {
      var sources = CreatorLiveSources(root: $0)
      sources.set(root)
      sources.set(removed)
      return sources
    }
    let first = makeSession(resolve: resolver, defaults: defaults)
    first.start(twitch)
    try await eventually { first.sources?.youtube != nil }
    first.updateLinks([twitch, kick])
    first.stop()
    for entry in [twitch, kick] {
      let restored = makeSession(resolve: resolver, defaults: defaults)
      restored.start(entry)
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertNil(restored.sources?.youtube)
      XCTAssertNil(restored.chat.youtubeReceiveTask)
      restored.stop()
    }
  }

  #if os(tvOS)
  func testUnlinkingPendingYouTubeRestoresRetainedTwitchOrKickVideo() async throws {
    for root in [twitch, kick] {
      let gate = CreatorYouTubeGate()
      let session = makeSession()
      session.start(root)
      session.updateLinks([root, youtube])
      let model = PlayerModel(creatorSession: session)
      model.activeChannel = root.channel
      model.livePlatform = root.platform
      model.twitchPlaybackTarget = root.platform == .twitch ? root.channel : ""
      model.kickPlaybackTarget = root.platform == .kick ? root.channel : ""
      model.isUsingAltSource = true
      model.isUserPaused = true
      model.resolveYouTubeLive = { try await gate.resolve($0) }
      let view = PlayerView(channel: root.channel, auth: TwitchAuthSession(),
        initialPlatform: root.platform, model: model)
      let loading = Task { await view.resolveAndPlayAltSource(reason: "test") }
      for _ in 0..<100 {
        if await gate.waiting { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      session.updateLinks([root])
      view.synchronizeCreatorServices()
      view.handleCreatorGenerationChange()
      XCTAssertFalse(model.isUsingAltSource)
      XCTAssertEqual(view.currentLiveTarget, root)
      XCTAssertEqual(session.videoTarget, root)
      XCTAssertNotNil(model.playbackWatchdogTask)
      await gate.reply()
      let installed = await loading.value
      XCTAssertFalse(installed)
      XCTAssertNil(session.sources?.youtube)
      XCTAssertNil(model.player.currentItem)
      view.stopLatencyMonitor()
      view.stopRateController()
      view.stopPlaybackWatchdog()
      session.stop()
    }
  }

  func testSuspendedPlayerDoesNotRestartEventSubDuringLateDiscovery() async throws {
    var continuation: CheckedContinuation<CreatorLiveSources, Error>?
    let session = makeSession(resolve: { _ in
      try await withCheckedThrowingContinuation { continuation = $0 }
    })
    defer { session.stop() }
    session.start(twitch)
    try await eventually { continuation != nil }
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    session.suspend()
    model.eventSubChannel = nil
    var discovered = CreatorLiveSources(root: twitch)
    discovered.set(kick)
    continuation?.resume(returning: discovered)
    continuation = nil
    try await eventually { session.sources?.kick != nil }
    view.synchronizeCreatorServices()
    XCTAssertNil(model.eventSubChannel)
    XCTAssertNil(session.chat.channel)
    session.resume()
    view.synchronizeCreatorServices()
    XCTAssertEqual(model.eventSubChannel, twitch.channel)
  }

  func testYouTubeHeaderRefreshUsesCreatorIdentityInsteadOfYouTubeTarget() async {
    let requested = CreatorRequestedChannels()
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, youtube])
    session.selectVideo(youtube)
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    model.isUsingAltSource = true
    model.youtubeAutoResolvedTarget = youtube.channel
    model.loadChannelMetadata = { await requested.record($0); return nil }
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    await view.refreshChannelMetadata()
    let channels = await requested.channels
    XCTAssertEqual(channels, [twitch.channel])
    session.start(kick)
    session.updateLinks([kick, youtube])
    session.selectVideo(youtube)
    model.channelDisplayName = "Kick creator"
    await view.refreshChannelMetadata()
    let after = await requested.channels
    XCTAssertEqual(after, channels)
    XCTAssertEqual(model.channelDisplayName, "Kick creator")
  }

  func testEditingKickRestartsPendingYouTubeIntentWithSameTarget() async throws {
    let gate = CreatorYouTubeGate()
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, youtube])
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    model.isUsingAltSource = true
    model.isUserPaused = true
    model.resolveYouTubeLive = { try await gate.resolve($0) }
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    let original = Task { await view.resolveAndPlayAltSource(reason: "test") }
    for _ in 0..<100 {
      if await gate.count == 1 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    session.updateLinks([twitch, youtube, kick])
    view.handleCreatorGenerationChange()
    for _ in 0..<100 {
      if await gate.count == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let count = await gate.count
    XCTAssertEqual(count, 2)
    await gate.reply()
    let oldInstalled = await original.value
    XCTAssertFalse(oldInstalled)
    await gate.reply()
    try await eventually { session.videoTarget == self.youtube }
    XCTAssertNotNil(model.player.currentItem)
    XCTAssertEqual(session.videoTarget, youtube)
    model.player.replaceCurrentItem(with: nil)
  }

  func testTwitchStatusUsesVideoAccountAfterKickEntry() async {
    let requested = CreatorRequestedChannels()
    let session = makeSession()
    defer { session.stop() }
    session.start(kick)
    session.updateLinks([kick, twitch])
    let model = PlayerModel(loadStreamStatus: { await requested.record($0); return .live },
      creatorSession: session)
    model.activeChannel = kick.channel
    model.livePlatform = .twitch
    model.twitchPlaybackTarget = twitch.channel
    let view = PlayerView(channel: kick.channel, auth: TwitchAuthSession(),
      initialPlatform: .kick, model: model)
    _ = await view.loadCurrentStreamStatus(kick.channel)
    let channels = await requested.channels
    XCTAssertEqual(channels, [twitch.channel])
  }

  func testUnlinkedYouTubeCannotInstallOrCreateCreatorAssociation() async {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    await view.switchToAltYouTubeSource(resolved: .init(
      hlsMaster: URL(string: "https://example.com/live.m3u8")!, concurrentViewers: 99),
      resolvedTarget: "@creator")
    XCTAssertNil(session.sources?.youtube)
    XCTAssertNil(model.player.currentItem)
    XCTAssertFalse(model.isUsingAltSource)
  }

  func testLateYouTubeResolveCannotInstallUnderEditedLink() async throws {
    let gate = CreatorYouTubeGate()
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    session.updateLinks([twitch, youtube])
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    model.isUsingAltSource = true
    model.resolveYouTubeLive = { try await gate.resolve($0) }
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    let loading = Task { await view.resolveAndPlayAltSource(reason: "test") }
    for _ in 0..<100 {
      if await gate.waiting { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    session.updateLinks([twitch, .init(platform: .youtube, channel: "@replacement")])
    view.synchronizeCreatorServices()
    await gate.reply()
    let installed = await loading.value
    XCTAssertFalse(installed)
    XCTAssertNil(model.player.currentItem)
    XCTAssertEqual(session.videoTarget, twitch)
    XCTAssertEqual(session.sources?.youtube, "@replacement")
  }

  func testLateLinkedYouTubeCanBeOfferedAfterVideoIsReady() async {
    let session = makeSession()
    defer { session.stop() }
    session.start(twitch)
    let model = PlayerModel(creatorSession: session)
    model.activeChannel = twitch.channel
    model.isLoading = false
    model.resolveYouTubeLive = { _ in .init(
      hlsMaster: URL(string: "https://example.com/live.m3u8")!, concurrentViewers: 15) }
    let view = PlayerView(channel: twitch.channel, auth: TwitchAuthSession(), model: model)
    session.updateLinks([twitch, youtube])
    await view.refreshYouTubeSourceAvailability()
    XCTAssertTrue(view.streamSourceOptions.contains("YouTube"))
    XCTAssertEqual(model.youtubeViewerCount, 15)
  }
  #endif

  private func makeSession(
    resolve: @escaping (PlatformLiveTarget) async throws -> CreatorLiveSources = { CreatorLiveSources(root: $0) },
    loadTwitch: @escaping (String) async -> CreatorViewerSnapshot = { _ in .live(71) },
    now: @escaping () -> Date = Date.init, defaults: UserDefaults? = nil
  ) -> CreatorLiveSession {
    CreatorLiveSession(resolve: resolve, loadTwitch: loadTwitch, loadKick: { slug in
      KickChannel(slug: slug, displayName: slug, title: "Live", category: "",
        viewerCount: 42, isLive: true, chatroomID: nil, imageURL: nil)
    }, loadYouTube: { _ in .live(13) }, now: now, defaults: defaults)
  }

  #if os(tvOS)
  private actor CreatorRequestedChannels {
    private(set) var channels: [String] = []
    func record(_ channel: String) { channels.append(channel) }
  }

  private actor CreatorYouTubeGate {
    private var continuations: [CheckedContinuation<AltSourceService.YouTubeLive, Error>] = []
    var waiting: Bool { !continuations.isEmpty }
    var count: Int { continuations.count }
    func resolve(_ target: String) async throws -> AltSourceService.YouTubeLive {
      try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func reply() {
      guard !continuations.isEmpty else { return }
      continuations.removeFirst().resume(returning: .init(
        hlsMaster: URL(fileURLWithPath: "/nonexistent-creator-fixture.m3u8"), concurrentViewers: 11))
    }
  }
  #endif

  private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Creator session did not reach the expected state", file: file, line: line)
  }
}
