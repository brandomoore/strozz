import AVKit
import CoreVideo
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewContinuityLiveTests: XCTestCase {
  @MainActor private enum Surface {
    case avkit(AVPlayerViewController)
    case layer(PlayerLayerHostView)

    var view: UIView {
      switch self {
      case .avkit(let controller): controller.view
      case .layer(let view): view
      }
    }

    var identity: ObjectIdentifier { ObjectIdentifier(view) }

    var player: AVPlayer? {
      switch self {
      case .avkit(let controller): controller.player
      case .layer(let view): view.playerLayer.player
      }
    }

    var isReadyForDisplay: Bool {
      switch self {
      case .avkit(let controller): controller.isReadyForDisplay
      case .layer(let view): view.playerLayer.isReadyForDisplay
      }
    }
  }

  func testAdaptiveVerificationRejectsFixedQualityAndDecodeRecovery() {
    let channel = FollowedChannel(id: "auto-proof", login: "auto-proof", displayName: "Auto proof",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    let pane = MultiviewPane(channel: channel)
    defer { pane.stop() }
    pane.model.isUsingNativeHLS = true
    XCTAssertTrue(isNativeAuto(pane))
    pane.model.decodeRecoveryQualityID = "source"
    XCTAssertFalse(isNativeAuto(pane), "Source decode recovery must never count as adaptive playback")
    pane.model.decodeRecoveryQualityID = nil
    pane.model.triedDecodeRecovery = true
    XCTAssertFalse(isNativeAuto(pane), "A previous decode recovery must not be hidden by clearing its quality")
    pane.model.triedDecodeRecovery = false
    pane.presentation.quality = "1080p60 (Source)"
    XCTAssertFalse(isNativeAuto(pane))
    pane.presentation.quality = "Auto"
    pane.model.nativeFallbackReason = "unsupported"
    XCTAssertFalse(isNativeAuto(pane))
    pane.model.nativeFallbackReason = nil
    pane.model.isUsingNativeHLS = false
    XCTAssertFalse(isNativeAuto(pane))
  }

  private func isNativeAuto(_ pane: MultiviewPane) -> Bool {
    pane.presentation.quality == "Auto" && pane.presentation.profile == .nativeLowLatency
      && pane.model.isUsingNativeHLS && pane.model.decodeRecoveryQualityID == nil
      && !pane.model.triedDecodeRecovery && pane.model.nativeFallbackReason == nil
  }

  func testOptInLiveZoomKeepsPlayersItemsAndAVKitSurfaces() async throws {
    #if targetEnvironment(simulator)
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_LIVE_TESTS"] == "1",
      let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Enable STROZZ_MULTIVIEW_LIVE_TESTS with two to four live channels.")
    }
    try await check(names: names, settings: settings, muted: true, environment: AppEnvironment())
    #else
    throw XCTSkip("This opt-in check must not take over the physical TV.")
    #endif
  }

  func testOptInBrowsingSuspendsAndResumesNativeLineup() async throws {
    #if targetEnvironment(simulator)
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_LIVE_TESTS"] == "1",
      settings["STROZZ_MUTE_PLAYBACK"] == "1",
      let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Enable muted simulator live tests with two to four live channels.")
    }
    let logins = names.split(separator: ",").map(String.init)
    guard (2...4).contains(logins.count) else { return XCTFail("Select two to four live sources") }
    let lineup = MultiviewLineup { _ in .live }
    for login in logins {
      lineup.toggle(FollowedChannel(id: login, login: login, displayName: login,
        title: "", gameName: "", viewerCount: nil, thumbnailURL: nil,
        profileImageURL: nil, isLive: true))
    }
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    let environment = AppEnvironment()
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIHostingController(rootView: MultiviewPlayerView(
      channels: [], availableChannels: [], auth: environment.auth, goLive: nil,
      onWatch: { _ in }, controller: controller)
      .environment(environment)
      .environment(\.multiviewLineup, lineup)
      .environment(\.themePalette, ThemePalette.dark))
    window.rootViewController = host
    defer {
      lineup.clear()
      window.rootViewController = previous
    }
    try await ready(controller, host: host, audiblePaneID: nil)
    controller.spotlight(controller.panes[0].id)
    let audioOwner = controller.audiblePaneID
    let panes = controller.panes
    let models = panes.map(\.model)
    let players = controller.panes.map(\.player)
    let items = try controller.panes.map { try XCTUnwrap($0.player.currentItem) }
    attach(host, name: "Live wall before browsing")

    lineup.browse()
    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(controller.isBrowsing)
    XCTAssertTrue(controller.panes.allSatisfy {
      $0.player.rate == 0 && !$0.presentation.videoIsVisible
        && $0.model.nativeHLS == nil && $0.model.nativeNeedsRefresh
    }, "Browsing must stop playback and native producers, not just hide video")
    let pausedClocks = players.map { $0.currentTime().seconds }
    try await Task.sleep(for: .seconds(1))
    for (index, player) in players.enumerated() {
      XCTAssertEqual(player.currentTime().seconds, pausedClocks[index], accuracy: 0.1)
    }

    lineup.startPlayback()
    try await ready(controller, host: host, audiblePaneID: nil)
    XCTAssertTrue(lineup.controller === controller)
    XCTAssertEqual(controller.layout, .spotlight)
    XCTAssertEqual(controller.audiblePaneID, audioOwner)
    XCTAssertEqual(surfaces(in: host).count, panes.count)
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane === panes[index])
      XCTAssertTrue(pane.model === models[index])
      // Existing native suspension recovery rebuilds the audio renderer too.
      XCTAssertFalse(pane.player === players[index])
      XCTAssertNil(players[index].currentItem)
      XCTAssertEqual(players[index].rate, 0)
      XCTAssertFalse(pane.player.currentItem === items[index],
        "Returning must refresh the suspended live source")
      XCTAssertTrue(isNativeAuto(pane))
      XCTAssertFalse(pane.model.nativeNeedsRefresh)
      let item = try XCTUnwrap(pane.player.currentItem)
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
      item.add(output)
      defer { item.remove(output) }
      var frames = 0
      for _ in 0..<20 {
        try await Task.sleep(for: .milliseconds(100))
        if output.hasNewPixelBuffer(forItemTime: item.currentTime()),
          output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil {
          frames += 1
        }
      }
      XCTAssertGreaterThan(frames, 10, "Returned panes must deliver new decoded frames")
    }
    attach(host, name: "Live wall resumed after browsing")
    #else
    throw XCTSkip("This opt-in check must not take over the physical TV.")
    #endif
  }

  func testOptInPhysicalLiveFollowedZoomKeepsPlayback() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Hardware verification requires its own explicit opt-in.")
    #else
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_PHYSICAL_TESTS"] == "1",
      let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Explicitly select live followed channels for a permitted hardware check.")
    }
    let requested = names.split(separator: ",").map { $0.lowercased() }
    guard requested.count == 4, Set(requested).count == 4 else {
      return XCTFail("Hardware verification requires four distinct followed channels")
    }
    for _ in 0..<50 {
      if AppEnvironment.playbackTestEnvironment != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let environment = try XCTUnwrap(AppEnvironment.playbackTestEnvironment)
    for _ in 0..<300 {
      if environment.accountSync.hasCompletedInitialSync,
        environment.follows.lastUpdatedAt != nil, !environment.follows.isLoading { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard environment.auth.isAuthenticated else {
      throw XCTSkip("Wait for the real account restoration; do not create a second auth session")
    }
    let liveFollowed = Set(environment.follows.channels.filter(\.isLive).map(\.channelKey))
    guard !environment.follows.isUsingDemoData, requested.allSatisfy(liveFollowed.contains) else {
      throw XCTSkip("The selected channels must still be live in the real Following list")
    }
    try await check(names: names, settings: settings,
      muted: settings["STROZZ_MULTIVIEW_TEST_AUDIO"] != "audible", environment: environment)
    #endif
  }

  func testOptInPhysicalGridResolutionCapacity() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Decoder capacity must be measured on the explicitly authorized physical TV.")
    #else
    let settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_MULTIVIEW_CAPACITY_TESTS"] == "1",
      NativeLowLatencyHLS.controlledAutoEnabled else {
      throw XCTSkip("Explicitly enable the physical capacity check and controlled Native Auto.")
    }
    guard let seconds = Int(settings["STROZZ_CAPACITY_SECONDS"] ?? "180"),
      (180...600).contains(seconds) else { return XCTFail("Use a sustained 180...600-second capacity stage") }
    let verifyGridBudgets = settings["STROZZ_CAPACITY_APPLY_GRID_BUDGETS"] == "1"
    let requestedCounts = (settings["STROZZ_CAPACITY_COUNTS"] ?? "2,4,6").components(separatedBy: ",")
    let counts = requestedCounts.compactMap(Int.init)
    guard counts.count == requestedCounts.count, counts == counts.sorted(), Set(counts).count == counts.count,
      counts.allSatisfy({ [2, 4, 6].contains($0) }) else { return XCTFail("Select ascending unique 2/4/6-pane stages") }
    for _ in 0..<50 {
      if AppEnvironment.playbackTestEnvironment != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let environment = try XCTUnwrap(AppEnvironment.playbackTestEnvironment)
    for _ in 0..<300 {
      if environment.accountSync.hasCompletedInitialSync, environment.auth.isAuthenticated { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard environment.auth.isAuthenticated else {
      throw XCTSkip("The real account must restore without creating another auth session.")
    }
    await environment.follows.refresh(using: environment.auth)
    guard !environment.follows.isUsingDemoData, environment.follows.errorMessage == nil else {
      return XCTFail("A fresh real Following list is required for the hardware check")
    }
    var channels: [FollowedChannel] = []
    var evidence: [[String: String]] = []
    let selectionDeadline = ContinuousClock.now.advanced(by: .seconds(120))
    for channel in environment.follows.channels.filter(\.isLive).prefix(20) {
      try Task.checkCancellation()
      if ContinuousClock.now >= selectionDeadline { break }
      do {
        let playback = try await PlaybackService.resolve(for: channel.login)
        let video = playback.qualities.filter { !$0.isAudioOnly }
        guard video.contains(where: { $0.name.contains("1080p60") }),
          video.contains(where: { $0.name.contains("720p60") }),
          video.compactMap({ PlayerView.verticalResolution(from: $0.name) }).max() == 1080 else {
          evidence.append(["phase": "source_selection", "channel": channel.login,
            "outcome": "not_a_1080p60_source"])
          continue
        }
        guard let highest = video.max(by: { $0.bitrate < $1.bitrate }) else {
          return XCTFail("The advertised video ladder has no highest rendition")
        }
        var request = URLRequest(url: highest.url)
        PlaybackService.streamHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          return XCTFail("Could not verify the candidate's upstream format")
        }
        let manifest = try NativeCMAF.manifest(String(decoding: bytes, as: UTF8.self), url: highest.url)
        guard manifest.initialization == nil, video.count > 1 else {
          evidence.append(["phase": "source_selection", "channel": channel.login,
            "outcome": "separate_cmaf_or_single_rendition_path"])
          continue
        }
        channels.append(channel)
        if channels.count == multiviewPaneLimit { break }
      } catch PlaybackError.offline {
        evidence.append(["phase": "source_selection", "channel": channel.login, "outcome": "now_offline"])
      } catch {
        evidence.append(["phase": "source_selection", "channel": channel.login,
          "outcome": "resolution_failed", "error_domain": (error as NSError).domain,
          "error_code": String((error as NSError).code)])
        throw error
      }
    }
    func checkpoint(_ name: String) {
      do {
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Physical multiview capacity \(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        evidence.removeAll(keepingCapacity: true)
      } catch { XCTFail("Could not preserve the physical capacity evidence") }
    }
    defer { checkpoint("final samples") }
    guard channels.count >= 2 else { return XCTFail("Two distinct live 1080p60 sources are required") }
    let controller = MultiviewController(channels: Array(channels.prefix(2)), muted: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let suite = "MultiviewCapacity.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set("Auto", forKey: PersistenceKey.preferredQuality)
    defaults.set(LivePlaybackProfile.nativeLowLatency.rawValue, forKey: PersistenceKey.livePlaybackProfile)
    let host = UIHostingController(rootView: MultiviewPlayerView(channels: channels,
      availableChannels: channels, auth: environment.auth, goLive: nil, onWatch: { _ in },
      controller: controller).environment(environment).environment(\.themePalette, ThemePalette.dark)
      .defaultAppStorage(defaults))
    window.rootViewController = host
    defer {
      controller.teardown()
      window.rootViewController = previous
      defaults.removePersistentDomain(forName: suite)
    }
    evidence.append(["phase": "device", "os": UIDevice.current.systemVersion,
      "screen_pixels": "\(scene.screen.nativeBounds.size)", "screen_scale": "\(scene.screen.nativeScale)",
      "requested_stage_seconds": String(seconds), "available_1080p60_sources": String(channels.count)])
    for count in counts {
      let targetHeight = verifyGridBudgets && count > 4 ? 720 : 1080
      guard channels.count >= count else {
        evidence.append(["phase": "stage", "panes": String(count), "outcome": "insufficient_1080p60_sources"])
        continue
      }
      for channel in channels.prefix(count).dropFirst(controller.panes.count) {
        XCTAssertNotNil(controller.addPane(channel))
      }
      try await ready(controller, host: host, audiblePaneID: nil)
      // Lift only the resource preference; every pane must still use genuine Auto.
      if !verifyGridBudgets {
        for pane in controller.panes { pane.presentation.qualityTier = .source }
      }
      let players = controller.panes.map(\.player)
      let items = try controller.panes.map { try XCTUnwrap($0.player.currentItem) }
      let renderers = Dictionary(uniqueKeysWithValues: surfaces(in: host).compactMap { surface in
        surface.player.map { (ObjectIdentifier($0), surface) }
      })
      let outputs = items.map { item in
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
        item.add(output)
        return output
      }
      defer { for (item, output) in zip(items, outputs) { item.remove(output) } }
      let warmupDeadline = ContinuousClock.now.advanced(by: .seconds(45))
      var reached = Set<Int>()
      while reached.count < count, ContinuousClock.now < warmupDeadline {
        try await Task.sleep(for: .milliseconds(100))
        for index in items.indices {
          let item = items[index]
          if outputs[index].hasNewPixelBuffer(forItemTime: item.currentTime()),
            let frame = outputs[index].copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil),
            CVPixelBufferGetHeight(frame) == targetHeight { reached.insert(index) }
        }
      }
      guard reached.count == count else {
        evidence.append(["phase": "stage", "panes": String(count), "outcome": "not_all_reached_target",
          "reached": String(reached.count), "target_height": String(targetHeight)])
        return XCTFail("Only \(reached.count)/\(count) physical grid panes reached \(targetHeight)p")
      }
      for pane in controller.panes {
        let timeline = await pane.model.nativeHLS?.origin.timelineDiagnostics()
        evidence.append(["phase": "pipeline", "panes": String(count), "channel": pane.channel.login,
          "controlled_auto": String(pane.model.nativeControlledAuto),
          "indexed_format": timeline?.first?["format"] ?? "unknown",
          "video_variants": String(pane.model.playback?.qualities.filter { !$0.isAudioOnly }.count ?? 0)])
        guard pane.model.nativeControlledAuto else {
          return XCTFail("The selected source changed format; controlled-engine capacity is unmeasured")
        }
      }
      attach(host, name: "Physical \(count)-pane \(targetHeight)p grid")
      let start = ProcessInfo.processInfo.systemUptime
      let initialClocks = items.map { $0.currentTime().seconds }
      let restartSerials = controller.panes.map { $0.model.nativeRestartSerial }
      var lastFresh = Array(repeating: start, count: count)
      var fresh = Array(repeating: 0, count: count)
      var fullResolution = Array(repeating: 0, count: count)
      var maximumGap = Array(repeating: 0.0, count: count)
      var ticks = 0
      var checkpointSecond = 0
      var previousSample = start
      var maximumSamplingInterval = 0.0
      while ProcessInfo.processInfo.systemUptime - start < Double(seconds) {
        try await Task.sleep(for: .milliseconds(100))
        let now = ProcessInfo.processInfo.systemUptime
        let samplingInterval = now - previousSample
        previousSample = now
        maximumSamplingInterval = max(maximumSamplingInterval, samplingInterval)
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical else {
          evidence.append(["phase": "stage", "panes": String(count), "outcome": "thermal_limit",
            "thermal_state": String(thermal.rawValue)])
          return XCTFail("Physical thermal pressure ended the capacity check")
        }
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: renderers, audiblePaneID: nil)
        ticks += 1
        for (index, pane) in controller.panes.enumerated() {
          let item = items[index]
          let clock = item.currentTime()
          var displayed = CMTime.invalid
          let frame = outputs[index].hasNewPixelBuffer(forItemTime: clock)
            ? outputs[index].copyPixelBuffer(forItemTime: clock, itemTimeForDisplay: &displayed) : nil
          let height = frame.map(CVPixelBufferGetHeight) ?? 0
          if frame != nil { fresh[index] += 1; lastFresh[index] = now }
          if height == targetHeight { fullResolution[index] += 1 }
          maximumGap[index] = max(maximumGap[index], now - lastFresh[index])
          let buffer = item.loadedTimeRanges.map(\.timeRangeValue)
            .filter { $0.start <= clock && $0.end >= clock }
            .map { ($0.end - clock).seconds }.max() ?? 0
          evidence.append(["phase": "sample", "panes": String(count), "channel": pane.channel.login,
            "seconds": String(now - start), "clock": String(clock.seconds),
            "sampling_interval_seconds": String(samplingInterval),
            "fresh": String(frame != nil), "decoded_height": String(height),
            "target_height": String(targetHeight),
            "buffer_seconds": String(buffer), "time_control": String(pane.player.timeControlStatus.rawValue),
            "controlled_auto": String(pane.model.nativeControlledAuto),
            "thermal_state": String(thermal.rawValue),
            "dropped_frames": String(item.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? -1)])
          guard pane.model.nativeRestartSerial == restartSerials[index],
            pane.player.timeControlStatus == .playing, maximumGap[index] < 0.5,
            pane.model.errorMessage == nil, !pane.model.mediaServicesUnavailable else {
            evidence.append(["phase": "stage", "panes": String(count), "outcome": "continuity_failed"])
            return XCTFail("Physical \(count)-pane continuity failed on \(pane.channel.login)")
          }
        }
        let elapsedSecond = Int(now - start)
        if elapsedSecond - checkpointSecond >= 30 {
          checkpointSecond = elapsedSecond
          checkpoint("\(count) panes \(elapsedSecond) seconds")
        }
      }
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      var healthy = ticks >= seconds * 8 && maximumSamplingInterval < 0.5
      for (index, pane) in controller.panes.enumerated() {
        let advancement = items[index].currentTime().seconds - initialClocks[index]
        let sustained = fullResolution[index] >= Int(ceil(Double(ticks) * 0.98))
        healthy = healthy && sustained && advancement >= elapsed * 0.95
        evidence.append(["phase": "summary", "panes": String(count), "channel": pane.channel.login,
          "elapsed_seconds": String(elapsed), "ticks": String(ticks), "fresh_frames": String(fresh[index]),
          "decoded_target_frames": String(fullResolution[index]), "target_height": String(targetHeight),
          "clock_advance": String(advancement),
          "maximum_sampling_interval_seconds": String(maximumSamplingInterval),
          "maximum_frame_gap_seconds": String(maximumGap[index]), "sustained_target": String(sustained)])
      }
      evidence.append(["phase": "stage", "panes": String(count), "outcome": healthy ? "passed" : "quality_or_sampling_limit"])
      checkpoint("\(count) panes completed")
      guard healthy else { return XCTFail("Physical \(count)-pane grid did not sustain full decoded quality") }
    }
    #endif
  }

  func testOptInPhysicalCMAFZoomKeepsPlayback() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("The physical CMAF check requires its own explicit permission.")
    #else
    var settings = ProcessInfo.processInfo.environment
    guard settings["STROZZ_CMAF_PHYSICAL_TESTS"] == "1",
      NativeLowLatencyHLS.controlledAutoEnabled, let names = settings["STROZZ_MATRIX_CHANNELS"] else {
      throw XCTSkip("Explicitly select a CMAF primary and a second live channel for authorized hardware verification.")
    }
    let channels = names.split(separator: ",").map(String.init)
    guard channels.count == 2, Set(channels).count == 2,
      channels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } })
      else { return XCTFail("Select two distinct public channel logins") }
    for _ in 0..<50 {
      if AppEnvironment.playbackTestEnvironment != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let environment = try XCTUnwrap(AppEnvironment.playbackTestEnvironment)
    for _ in 0..<300 {
      if environment.accountSync.hasCompletedInitialSync, environment.auth.isAuthenticated { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard environment.auth.isAuthenticated else { throw XCTSkip("Wait for the existing account restoration") }
    let playback = try await PlaybackService.resolve(for: channels[0])
    let highest = try XCTUnwrap(playback.qualities.filter { !$0.isAudioOnly }.max { $0.bitrate < $1.bitrate })
    var request = URLRequest(url: highest.url)
    PlaybackService.streamHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let (bytes, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return XCTFail("CMAF source verification failed") }
    guard try NativeCMAF.manifest(String(decoding: bytes, as: UTF8.self), url: highest.url).initialization != nil else {
      throw XCTSkip("The selected primary is no longer a source-CMAF stream")
    }
    settings["STROZZ_REQUIRE_CONTROLLED_AUTO"] = "1"
    try await check(names: names, settings: settings,
      muted: settings["STROZZ_MULTIVIEW_TEST_AUDIO"] != "audible", environment: environment)
    #endif
  }

  private func check(names: String, settings: [String: String], muted: Bool,
                     environment: AppEnvironment) async throws {
    let logins = names.split(separator: ",").map(String.init)
    guard (2...4).contains(logins.count) else { return XCTFail("Select two to four live sources") }
    guard let holdSeconds = Int(settings["STROZZ_MULTIVIEW_HOLD_SECONDS"] ?? "5"),
      (5...300).contains(holdSeconds) else { return XCTFail("Expanded hold must be between 5 and 300 seconds") }
    let channels = logins.map { login in
      FollowedChannel(id: login, login: login, displayName: login, title: "", gameName: "",
        viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }
    let controller = MultiviewController(channels: channels, muted: muted)
    let audiblePaneID = muted ? nil : controller.panes.first?.id
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = try XCTUnwrap(scene.keyWindow)
    let previous = window.rootViewController
    let host = UIHostingController(rootView: MultiviewPlayerView(
      channels: channels, availableChannels: channels, auth: environment.auth, goLive: nil,
      onWatch: { _ in }, controller: controller)
      .environment(environment)
      .environment(\.themePalette, ThemePalette.dark))
    // Simulators stay silent; authorized hardware checks keep only the first stream audible.
    window.rootViewController = host
    defer {
      let states = controller.panes.map { pane in
        ["channel": pane.channel.login, "native": String(pane.model.isUsingNativeHLS),
         "offline": String(pane.model.isOffline), "loading": String(pane.isLoading),
         "error": String(pane.model.errorMessage != nil), "fallback": pane.model.nativeFallbackReason ?? "none",
         "selected_quality": pane.presentation.quality,
         "controlled_auto": String(pane.model.nativeControlledAuto),
         "decode_recovery": pane.model.decodeRecoveryQualityID ?? "none"]
      }
      do {
        let data = try JSONSerialization.data(withJSONObject: states, options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Multiview final states"
        attachment.lifetime = .keepAlways
        add(attachment)
      } catch { XCTFail("Could not preserve multiview state evidence") }
      controller.teardown()
      window.rootViewController = previous
    }
    controller.setAudiblePane(audiblePaneID)
    try await ready(controller, host: host, audiblePaneID: audiblePaneID)
    if settings["STROZZ_REQUIRE_CONTROLLED_AUTO"] == "1" {
      guard controller.panes.allSatisfy({ $0.model.nativeControlledAuto }) else {
        return XCTFail("CMAF verification must use the actual controlled engine on every selected pane")
      }
    }
    let players = controller.panes.map(\.player)
    let items = try controller.panes.map { try XCTUnwrap($0.player.currentItem) }
    let outputs = items.map { item in
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [:])
      item.add(output)
      return output
    }
    defer {
      for (item, output) in zip(items, outputs) { item.remove(output) }
    }
    let originalSurfaces = surfaces(in: host)
    let surfacesByPlayer = Dictionary(uniqueKeysWithValues: originalSurfaces.compactMap { surface in
      surface.player.map { (ObjectIdentifier($0), surface) }
    })
    XCTAssertEqual(surfacesByPlayer.count, channels.count)
    attach(host, name: "Native multiview grid")
    var transitions: [[String: String]] = []
    for selected in controller.panes.prefix(muted ? 2 : 1) {
      let selectedIndex = try XCTUnwrap(controller.panes.firstIndex(where: { $0 === selected }))
      let output = outputs[selectedIndex]
      let surface = try XCTUnwrap(surfacesByPlayer[ObjectIdentifier(selected.player)])
      let gridFrame = surface.view.convert(surface.view.bounds, to: host.view)
      let startClock = selected.player.currentTime().seconds
      controller.expand(selected.id)
      var expandingFrames = 0
      for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        if output.hasNewPixelBuffer(forItemTime: items[selectedIndex].currentTime()),
          output.copyPixelBuffer(forItemTime: items[selectedIndex].currentTime(), itemTimeForDisplay: nil) != nil {
          expandingFrames += 1
        }
      }
      let expandedFrame = surface.view.convert(surface.view.bounds, to: host.view)
      XCTAssertGreaterThan(expandedFrame.width, gridFrame.width)
      XCTAssertGreaterThan(selected.player.currentTime().seconds, startClock + 0.5)
      XCTAssertTrue(surface.isReadyForDisplay)
      XCTAssertGreaterThanOrEqual(expandingFrames, 12, "Video must advance during the zoom, not just retain its owner")
      XCTAssertTrue(controller.panes.filter { $0 !== selected }.allSatisfy { $0.qualityTier == .hidden })
      attach(host, name: "Expanded normal player \(selected.channel.login)")
      let hiddenClocks = controller.panes.map { $0.player.currentTime().seconds }
      var previousHeight = selected.player.currentItem?.presentationSize.height ?? 0
      var qualityChanges = 0
      var freshFrames = 0
      let highest = selected.model.playback?.qualities.filter { !$0.isAudioOnly }
        .compactMap { PlayerView.verticalResolution(from: $0.name) }.max()
      var reachedHighestAt: Int?
      var dropsAfterHighest = 0
      for second in 0..<holdSeconds {
        try await Task.sleep(for: .seconds(1))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        let item = items[selectedIndex]
        let frame = output.hasNewPixelBuffer(forItemTime: item.currentTime())
          ? output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) : nil
        let height = frame.map { CGFloat(CVPixelBufferGetHeight($0)) }
          ?? (selected.model.nativeControlledAuto ? 0 : item.presentationSize.height)
        if second >= 15, height > 0, previousHeight > 0, height != previousHeight { qualityChanges += 1 }
        if let highest {
          if height >= CGFloat(highest), reachedHighestAt == nil { reachedHighestAt = second }
          if second >= 15, reachedHighestAt != nil, height < previousHeight { dropsAfterHighest += 1 }
        }
        previousHeight = height
        if frame != nil { freshFrames += 1 }
        transitions.append(["channel": selected.channel.login, "phase": "expanded", "second": String(second),
          "height": String(Double(height)), "clock": String(item.currentTime().seconds),
          "peak_bitrate": String(item.preferredPeakBitRate), "fresh_frames": String(freshFrames),
          "settled_quality_changes": String(qualityChanges),
          "reached_highest_at": reachedHighestAt.map(String.init) ?? "not_yet",
          "drops_after_highest": String(dropsAfterHighest)])
      }
      XCTAssertGreaterThanOrEqual(freshFrames, Int(ceil(Double(holdSeconds) * 0.98)),
        "Expanded Auto must keep delivering video, not merely preserve its player")
      if holdSeconds >= 60, highest != nil {
        // A monotonic startup upgrade is not oscillation. Require prompt full
        // quality and reject every subsequent drop in this unthrottled check.
        XCTAssertLessThanOrEqual(reachedHighestAt ?? holdSeconds, 30, "Expanded Auto must reach full quality promptly")
        XCTAssertEqual(dropsAfterHighest, 0, "Expanded Auto must not cycle away from sustained full quality")
      }
      for hidden in controller.panes where hidden !== selected {
        let index = try XCTUnwrap(controller.panes.firstIndex(where: { $0 === hidden }))
        let bytes = await hidden.model.nativeHLS?.origin.snapshot().cachedMediaBytes ?? 0
        transitions.append(["hidden_channel": hidden.channel.login,
          "height": String(Double(hidden.player.currentItem?.presentationSize.height ?? 0)),
          "bitrate_limit": String(hidden.player.currentItem?.preferredPeakBitRate ?? 0),
          "cached_media_bytes": String(bytes), "muted": String(hidden.player.isMuted)])
        XCTAssertEqual(hidden.player.currentItem?.preferredPeakBitRate, 800_000)
        XCTAssertTrue(hidden.player.isMuted)
        XCTAssertGreaterThan(hidden.player.currentTime().seconds - hiddenClocks[index], Double(holdSeconds) * 0.8,
          "Hidden panes must remain live, not merely retain an old item")
      }
      let expandedClock = selected.player.currentTime().seconds
      PlayerView(channel: selected.channel.login, auth: environment.auth, model: selected.model).closePlayer()
      var returningFrames = 0
      for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100))
        try assertIdentity(controller, host: host, players: players, items: items,
          surfaces: surfacesByPlayer, audiblePaneID: audiblePaneID)
        if output.hasNewPixelBuffer(forItemTime: items[selectedIndex].currentTime()),
          output.copyPixelBuffer(forItemTime: items[selectedIndex].currentTime(), itemTimeForDisplay: nil) != nil {
          returningFrames += 1
        }
      }
      let returned = surface.view.convert(surface.view.bounds, to: host.view)
      XCTAssertEqual(returned.width, gridFrame.width, accuracy: 2)
      XCTAssertEqual(returned.height, gridFrame.height, accuracy: 2)
      XCTAssertGreaterThan(selected.player.currentTime().seconds, expandedClock + 0.5)
      XCTAssertGreaterThanOrEqual(returningFrames, 12, "Returning to the grid must retain advancing video")
      transitions.append(["channel": selected.channel.login, "grid_width": "\(gridFrame.width)",
        "expanded_width": "\(expandedFrame.width)", "returned_width": "\(returned.width)",
        "same_player_item_surface": "true", "expanding_frames": String(expandingFrames),
        "returning_frames": String(returningFrames)])
    }
    if muted {
      let pausedPane = controller.panes[0]
      let pausedItem = pausedPane.player.currentItem
      let pausedView = PlayerView(channel: pausedPane.channel.login, auth: environment.auth, model: pausedPane.model)
      pausedView.toggleRewindPlayPause()
      controller.expand(pausedPane.id)
      try await Task.sleep(for: .milliseconds(400))
      controller.collapse()
      try await Task.sleep(for: .milliseconds(400))
      XCTAssertTrue(pausedPane.model.isUserPaused)
      XCTAssertEqual(pausedPane.player.rate, 0)
      XCTAssertTrue(pausedPane.player.currentItem === pausedItem)
      pausedView.toggleRewindPlayPause()
    }
    attach(host, name: "Returned native multiview grid")
    let data = try JSONSerialization.data(withJSONObject: transitions, options: [.sortedKeys])
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "Multiview continuity identities"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func ready(_ controller: MultiviewController, host: UIViewController,
                     audiblePaneID: String?) async throws {
    for _ in 0..<450 {
      guard controller.panes.allSatisfy({
        $0.presentation.quality == "Auto" && $0.model.decodeRecoveryQualityID == nil && !$0.model.triedDecodeRecovery
      }) else {
        XCTFail("Adaptive verification cannot start after pinning quality or recovering to Source")
        throw URLError(.cannotDecodeContentData)
      }
      XCTAssertTrue(controller.panes.allSatisfy { $0.player.isMuted == ($0.id != audiblePaneID) })
      let rendered = surfaces(in: host)
      if controller.panes.allSatisfy({ pane in
        pane.model.isUsingNativeHLS && pane.model.nativeStartupComplete && !pane.isLoading
          && pane.player.timeControlStatus == .playing
          && pane.model.playbackTelemetry.videoFrameAge.map { $0 < 3 } == true
          && rendered.contains { $0.player === pane.player && $0.isReadyForDisplay }
      }) { return }
      if controller.panes.contains(where: { $0.hasError || $0.model.nativeFallbackReason != nil }) {
        for pane in controller.panes where pane.hasError || pane.model.nativeFallbackReason != nil {
          XCTFail("\(pane.channel.login): \(pane.model.isOffline ? "offline" : pane.model.nativeFallbackReason ?? "playback error")")
        }
        throw URLError(.cannotDecodeContentData)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("All multiview panes must show native video before testing the transition")
    throw URLError(.timedOut)
  }

  private func assertIdentity(_ controller: MultiviewController, host: UIViewController,
                              players: [AVPlayer], items: [AVPlayerItem],
                              surfaces original: [ObjectIdentifier: Surface],
                              audiblePaneID: String?) throws {
    let current = surfaces(in: host)
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index], "Zoom must not create a player")
      XCTAssertTrue(pane.player.currentItem === items[index], "Zoom must not reload playback")
      XCTAssertTrue(current.contains { $0.identity == original[ObjectIdentifier(pane.player)]?.identity },
                    "Zoom must preserve the actual native rendering surface")
      XCTAssertTrue(pane.model.isUsingNativeHLS)
      XCTAssertTrue(isNativeAuto(pane), "Native Auto must remain adaptive without a fixed-quality decode recovery")
      XCTAssertEqual(pane.player.isMuted, pane.id != audiblePaneID, "Audio must remain with the authorized stream")
      if pane.id == audiblePaneID {
        XCTAssertGreaterThan(pane.player.volume, 0)
        XCTAssertFalse(pane.model.audioInterrupted)
        XCTAssertFalse(pane.model.audioSessionActivationFailed)
      }
    }
    XCTAssertEqual(current.count, players.count, "No extra rendering owner may appear during zoom")
  }

  private func surfaces(in controller: UIViewController) -> [Surface] {
    func controllers(in controller: UIViewController) -> [Surface] {
      if let surface = controller as? AVPlayerViewController { return [.avkit(surface)] }
      return controller.children.flatMap { controllers(in: $0) }
    }
    func layers(in view: UIView) -> [Surface] {
      if let layer = view as? PlayerLayerHostView { return [.layer(layer)] }
      return view.subviews.flatMap { layers(in: $0) }
    }
    return controllers(in: controller) + layers(in: controller.view)
  }

  private func attach(_ host: UIViewController, name: String) {
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
