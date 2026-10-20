import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewForegroundRecoveryTests: XCTestCase {
  func testOfflinePaneIsDistinctFromLoadFailureAndRemoteRetryKeepsItsIdentity() {
    let controller = controller(count: 2)
    defer { controller.teardown() }
    let pane = controller.panes[0]
    pane.model.isLoading = false
    pane.model.isOffline = true
    XCTAssertTrue(pane.hasError)
    XCTAssertEqual(String(localized: pane.accessibilityStatus(isTransitioning: false)), "Offline")
    XCTAssertEqual(String(localized: pane.accessibilityStatus(isTransitioning: true)), "Offline")
    let player = pane.player
    let previous = pane.presentation.reloadID
    controller.load(pane)
    XCTAssertNotEqual(pane.presentation.reloadID, previous)
    XCTAssertTrue(pane.player === player)
    XCTAssertEqual(pane.channel.displayName, "Fixture 0")

    pane.model.isOffline = false
    pane.model.errorMessage = "Synthetic native failure"
    XCTAssertEqual(String(localized: pane.accessibilityStatus(isTransitioning: false)), "Unavailable")
    pane.model.errorMessage = nil
    XCTAssertEqual(String(localized: pane.accessibilityStatus(isTransitioning: true)), "Transitioning")
    XCTAssertEqual(String(localized: pane.accessibilityStatus(isTransitioning: false)), "Live")
  }

  func testHiddenExpandedPeersCannotForceDecodeRecoveryAndBecomeVisibleAgain() {
    let controller = controller(count: 3)
    defer { controller.teardown() }
    let selected = controller.panes[0]
    let hidden = controller.panes[1]
    XCTAssertTrue(controller.panes.allSatisfy { $0.model.isVideoPresentationVisible })
    controller.spotlight(selected.id)
    XCTAssertTrue(controller.panes.allSatisfy { $0.model.isVideoPresentationVisible },
      "Filmstrip peers remain visible even though they are not expanded")
    controller.expand(selected.id)
    XCTAssertTrue(selected.model.isVideoPresentationVisible)
    XCTAssertFalse(hidden.model.isVideoPresentationVisible)
    let view = PlayerView(channel: hidden.channel.login, auth: TwitchAuthSession(), model: hidden.model)
    let url = URL(string: "https://example.invalid/source.m3u8")!
    view.playback = StreamPlayback(master: url, qualities: [
      StreamQuality(id: "source", name: "1080p60 (Source)", url: url, isAudioOnly: false, bitrate: 8_000_000),
    ])
    view.videoDecodeFrozenSince = .distantPast
    view.checkVideoDecodeFreeze(item: AVPlayerItem(url: url), clockAdvanced: 2)
    XCTAssertNil(view.videoDecodeFrozenSince)
    XCTAssertFalse(view.recoverUndecodableVideo())
    XCTAssertFalse(hidden.model.triedDecodeRecovery)
    XCTAssertNil(hidden.model.decodeRecoveryQualityID)
    XCTAssertEqual(hidden.presentation.quality, "Auto")
    controller.collapse()
    XCTAssertTrue(controller.panes.allSatisfy { $0.model.isVideoPresentationVisible })
    view.currentSourceURL = url
    hidden.player.replaceCurrentItem(with: AVPlayerItem(url: url))
    XCTAssertTrue(view.recoverUndecodableVideo(), "Visible panes retain genuine decode recovery")
    XCTAssertEqual(hidden.model.decodeRecoveryQualityID, "source")
    XCTAssertTrue(PlayerModel().isVideoPresentationVisible)
  }

  private func controller(count: Int = 4, controlledAuto: Bool = false) -> MultiviewController {
    MultiviewController(channels: (0..<count).map { index in
      FollowedChannel(id: "\(index)", login: "fixture\(index)", displayName: "Fixture \(index)",
        title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }, controlledAuto: controlledAuto)
  }

  func testControlledGridRaisesSmallLayoutsAndRetainsPlayersAcrossTheFourPaneBoundary() throws {
    let controller = controller(count: 6, controlledAuto: true)
    defer { controller.teardown() }
    let players = controller.panes.map(\.player)
    let items = controller.panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    XCTAssertTrue(controller.panes.allSatisfy { $0.qualityTier == .grid720 })
    controller.removePane(try XCTUnwrap(controller.panes.last).id)
    XCTAssertTrue(controller.panes.allSatisfy { $0.qualityTier == .grid720 })
    controller.removePane(try XCTUnwrap(controller.panes.last).id)
    XCTAssertTrue(controller.panes.allSatisfy { $0.qualityTier == .grid1080 })
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index])
      XCTAssertTrue(pane.player.currentItem === items[index])
    }
    controller.expand(controller.panes[0].id)
    XCTAssertEqual(controller.panes[0].qualityTier, .source)
    XCTAssertTrue(controller.panes.dropFirst().allSatisfy { $0.qualityTier == .hidden })
    controller.collapse()
    XCTAssertTrue(controller.panes.allSatisfy { $0.qualityTier == .grid1080 })
    controller.addPane(FollowedChannel(id: "new", login: "new", displayName: "New",
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true))
    XCTAssertTrue(controller.panes.allSatisfy { $0.qualityTier == .grid720 })
  }

  func testControlledGridBudgetsAdmitReal720p60And1080p60Bitrates() throws {
    let variants: [NativeAdaptiveRenditionPolicy.Variant] = [
      .init(id: 0, bitrate: 1_427_999, width: 852, height: 480),
      .init(id: 1, bitrate: 3_422_999, width: 1280, height: 720),
      .init(id: 2, bitrate: 9_013_733, width: 1920, height: 1080),
    ]
    for (tier, expected) in [(MultiviewQualityTier.grid720, 720), (.grid1080, 1080)] {
      var policy = try NativeAdaptiveRenditionPolicy(variants: variants)
      try policy.recordCompletedTransfer(bytes: 262_144, seconds: 0.1, at: 0)
      let budget = NativeAdaptiveRenditionPolicy.Budget(
        maximumWidth: Int(tier.maximumResolution.width), maximumHeight: Int(tier.maximumResolution.height),
        maximumBitrate: tier.targetBitrate)
      XCTAssertEqual(tier.targetBitrate, 0, "A nominal resolution must not hide an excluding bitrate ceiling")
      XCTAssertEqual(try policy.select(budget: budget, buffer: 1.5, deliveryLate: false, at: 0).variant.height, expected)
    }
    let small = controller(count: 2, controlledAuto: true)
    let legacy = controller(count: 4)
    defer { small.teardown(); legacy.teardown() }
    XCTAssertEqual(small.panes.first?.qualityTier, .grid1080)
    XCTAssertEqual(legacy.panes.first?.qualityTier, .grid,
      "An explicit diagnostic opt-out retains the previous resource policy")
  }

  func testOnlyFullyHiddenPeersUse360pAndReturnRestoresVisibleBudgetsWithoutReloading() {
    let controller = controller(count: 3, controlledAuto: true)
    defer { controller.teardown() }
    let players = controller.panes.map(\.player)
    let requests = controller.panes.map(\.presentation.reloadID)
    let items = controller.panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    let primary = controller.panes[0]
    let peer = controller.panes[1]
    let view = PlayerView(channel: peer.channel.login, auth: TwitchAuthSession(), model: peer.model)
    controller.spotlight(primary.id)
    XCTAssertEqual(peer.qualityTier, .thumbnail)
    XCTAssertTrue(peer.model.isVideoPresentationVisible)
    view.applyMultiviewBudget()
    XCTAssertEqual(items[1].preferredMaximumResolution.height, 480)
    controller.expand(primary.id)
    XCTAssertEqual(primary.qualityTier, .source)
    XCTAssertEqual(peer.qualityTier, .hidden)
    XCTAssertFalse(peer.model.isVideoPresentationVisible)
    view.applyMultiviewBudget()
    XCTAssertEqual(items[1].preferredMaximumResolution, CGSize(width: 640, height: 360))
    XCTAssertEqual(items[1].preferredPeakBitRate, 800_000)
    controller.collapse()
    XCTAssertEqual(peer.qualityTier, .thumbnail)
    XCTAssertTrue(peer.model.isVideoPresentationVisible)
    view.applyMultiviewBudget()
    XCTAssertEqual(items[1].preferredMaximumResolution.height, 480)
    controller.toggleLayout()
    view.applyMultiviewBudget()
    XCTAssertEqual(peer.qualityTier, .grid1080)
    XCTAssertEqual(items[1].preferredMaximumResolution.height, 1080)
    XCTAssertEqual(items[1].preferredPeakBitRate, 0)
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index])
      XCTAssertTrue(pane.player.currentItem === items[index])
      XCTAssertEqual(pane.presentation.reloadID, requests[index])
      XCTAssertEqual(pane.presentation.quality, "Auto")
    }
  }

  func testDiagnosticLayerSelectionIsStableAcrossExpansionAndExcludesStandalone() {
    let controller = controller(count: 2)
    defer { controller.teardown() }
    let pane = controller.panes[0]
    let view = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
    let control = ["STROZZ_MULTIVIEW_VIDEO_SURFACE": "layer"]
    XCTAssertFalse(view.usesDirectMultiviewVideoLayer(environment: [:]))
    XCTAssertTrue(view.usesDirectMultiviewVideoLayer(environment: control))
    controller.expand(pane.id)
    XCTAssertTrue(view.usesDirectMultiviewVideoLayer(environment: control))
    controller.collapse()
    XCTAssertTrue(view.usesDirectMultiviewVideoLayer(environment: control))
    let standalone = PlayerView(channel: "fixture", auth: TwitchAuthSession(), model: PlayerModel())
    XCTAssertFalse(standalone.usesDirectMultiviewVideoLayer(environment: control))
  }

  func testDirectLayerHostRetainsPlayerDuringResizeAndDetachesOnDismantle() async throws {
    let player = AVPlayer()
    let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-layer-fixture.m3u8"))
    player.replaceCurrentItem(with: item)
    defer { player.pause(); player.replaceCurrentItem(with: nil) }
    let host = UIHostingController(rootView: PreviewVideoSurface(player: player))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    host.view.frame = CGRect(x: 0, y: 0, width: 854, height: 480)
    host.view.layoutIfNeeded()
    func layerView(in view: UIView) -> PlayerLayerHostView? {
      if let layer = view as? PlayerLayerHostView { return layer }
      return view.subviews.lazy.compactMap { layerView(in: $0) }.first
    }
    for _ in 0..<25 {
      if layerView(in: host.view) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let view = try XCTUnwrap(layerView(in: host.view))
    XCTAssertTrue(view.playerLayer.player === player)
    XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
    host.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    host.view.layoutIfNeeded()
    XCTAssertTrue(layerView(in: host.view) === view)
    XCTAssertTrue(view.playerLayer.player === player)
    XCTAssertTrue(player.currentItem === item)
    PreviewVideoSurface.dismantleUIView(view, coordinator: ())
    XCTAssertNil(view.playerLayer.player)
    XCTAssertTrue(player.currentItem === item, "Surface cleanup must not stop its retained player")
  }

  func testExpansionAndReturnKeepEveryPlayerAndItemAlive() {
    let controller = controller()
    defer { controller.teardown() }
    controller.start()
    let players = controller.panes.map(\.player)
    let items = controller.panes.map { pane in
      let item = AVPlayerItem(url: URL(fileURLWithPath: "/dev/null"))
      pane.player.replaceCurrentItem(with: item)
      return item
    }
    let selected = controller.panes[1]
    controller.expand(selected.id)
    XCTAssertEqual(controller.expandedPaneID, selected.id)
    XCTAssertEqual(controller.panes.filter(\.presentation.isExpanded).count, 1)
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index])
      XCTAssertTrue(pane.player.currentItem === items[index])
      XCTAssertEqual(pane.qualityTier, pane === selected ? .source : .hidden)
      XCTAssertEqual(pane.player.isMuted, pane !== selected)
    }
    selected.player.isMuted = true
    controller.collapse()
    controller.setAudiblePane(selected.id)
    XCTAssertTrue(selected.player.isMuted, "Returning focus to the same pane must preserve explicit mute")
    for (index, pane) in controller.panes.enumerated() {
      XCTAssertTrue(pane.player === players[index])
      XCTAssertTrue(pane.player.currentItem === items[index])
      XCTAssertEqual(pane.qualityTier, .grid)
      XCTAssertFalse(pane.presentation.isExpanded)
    }
  }

  func testPresentationBudgetsUpdateWithoutReplacingTheNativeItem() {
    let controller = controller()
    defer { controller.teardown() }
    let pane = controller.panes[0]
    pane.model.isUserPaused = true
    let view = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
    let url = URL(string: "https://example.invalid/master.m3u8")!
    view.playback = StreamPlayback(master: url, qualities: [])
    let item = view.makeItem(url: url)
    view.replacePlaybackItem(with: item)
    XCTAssertTrue(pane.model.isUsingNativeHLS)
    XCTAssertEqual(view.livePlaybackProfile, .nativeLowLatency)
    XCTAssertEqual(item.preferredMaximumResolution, CGSize(width: 1280, height: 720))
    controller.expand(pane.id)
    view.applyMultiviewBudget()
    XCTAssertTrue(pane.player.currentItem === item)
    XCTAssertEqual(item.preferredMaximumResolution, .zero)
    XCTAssertEqual(item.preferredPeakBitRate, 0)
    controller.collapse()
    view.applyMultiviewBudget()
    XCTAssertTrue(pane.player.currentItem === item)
    XCTAssertEqual(item.preferredPeakBitRate, 3_000_000)
    XCTAssertEqual(item.preferredForwardBufferDuration, 3)
  }

  func testEveryPaneUsesSharedNativeForegroundRecoveryAndRetainsItsBudget() async {
    let controller = controller()
    defer { controller.teardown() }
    controller.expand(controller.panes[0].id)
    for pane in controller.panes {
      pane.model.isUserPaused = true
      let view = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
      let url = URL(string: "https://example.invalid/\(pane.id)/master.m3u8")!
      view.playback = StreamPlayback(master: url, qualities: [])
      view.replacePlaybackItem(with: view.makeItem(url: url))
      let oldPlayer = pane.player
      let wasMuted = oldPlayer.isMuted
      view.suspendNativePlayback()
      view.refreshNativeAfterSuspension { StreamPlayback(master: url, qualities: []) }
      await pane.model.nativeRefreshTask?.value
      XCTAssertFalse(pane.player === oldPlayer)
      XCTAssertNil(oldPlayer.currentItem)
      XCTAssertTrue(pane.model.isUsingNativeHLS)
      XCTAssertEqual(pane.player.isMuted, wasMuted)
      XCTAssertEqual(pane.player.rate, 0)
      XCTAssertEqual(pane.player.currentItem?.preferredPeakBitRate, Double(pane.qualityTier.targetBitrate))
    }
  }

  func testLayoutsKeepStablePaneKeysAndStayInsideViewport() throws {
    let size = CGSize(width: 1920, height: 1080)
    for count in 1...6 {
      let ids = (0..<count).map(String.init)
      for layout in [MultiviewLayout.grid, .spotlight] {
        let frames = MultiviewGeometry.frames(ids: ids, size: size, layout: layout,
          primary: ids.last, expanded: nil)
        XCTAssertEqual(Set(frames.keys), Set(ids))
        for frame in frames.values {
          XCTAssertGreaterThan(frame.width, 0)
          XCTAssertGreaterThan(frame.height, 0)
          XCTAssertGreaterThanOrEqual(frame.minX, 0)
          XCTAssertGreaterThanOrEqual(frame.minY, 0)
          XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.001)
          XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001)
        }
        let expanded = MultiviewGeometry.frames(ids: ids, size: size, layout: layout,
          primary: ids.last, expanded: ids[0])
        XCTAssertEqual(expanded[ids[0]], CGRect(origin: .zero, size: size))
        for id in ids.dropFirst() { XCTAssertEqual(expanded[id], frames[id]) }
      }
    }
  }

  func testClosingExpandedPlayerRestoresTheWallInsteadOfDismissingIt() {
    let controller = controller()
    defer { controller.teardown() }
    let pane = controller.panes[2]
    controller.spotlight(controller.panes[0].id)
    controller.expand(pane.id)
    let view = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
    view.closePlayer()
    XCTAssertNil(controller.expandedPaneID)
    XCTAssertEqual(controller.layout, .spotlight)
    XCTAssertEqual(controller.panes.count, 4)
  }

  func testExpandedSleepPausesHiddenWorkWithoutOverridingAUserPause() {
    let controller = controller(count: 3)
    let idle = UIApplication.shared.isIdleTimerDisabled
    defer {
      controller.teardown()
      UIApplication.shared.isIdleTimerDisabled = idle
    }
    controller.reduceMotion = true
    let selected = controller.panes[0]
    let live = controller.panes[1]
    let paused = controller.panes[2]
    paused.model.isUserPaused = true
    let liveRequest = live.presentation.reloadID
    let pausedRequest = paused.presentation.reloadID
    controller.expand(selected.id)
    selected.model.isSleeping = true
    controller.synchronizeExpandedSleep()
    XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    XCTAssertTrue(live.model.multiviewSleepSuspended)
    XCTAssertFalse(paused.model.multiviewSleepSuspended)
    let view = PlayerView(channel: live.channel.login, auth: TwitchAuthSession(), model: live.model)
    XCTAssertFalse(view.shouldPlayAltSource)
    var activations = 0
    live.model.activateAudioSession = { activations += 1 }
    view.startPlayback()
    view.resumePlayback()
    view.resumePlaybackAfterAbsence(restoreLive: true)
    XCTAssertEqual(activations, 0)
    XCTAssertEqual(live.player.rate, 0)
    selected.model.isSleeping = false
    controller.synchronizeExpandedSleep()
    XCTAssertFalse(live.model.multiviewSleepSuspended)
    XCTAssertTrue(view.shouldPlayAltSource)
    XCTAssertNotEqual(live.presentation.reloadID, liveRequest)
    XCTAssertEqual(paused.presentation.reloadID, pausedRequest)
    XCTAssertTrue(paused.model.isUserPaused)
  }

  func testPaneQualityChoicesDoNotChangeTheSavedStandalonePreference() {
    let controller = controller()
    defer { controller.teardown() }
    let savedQuality = UserDefaults.standard.object(forKey: PersistenceKey.preferredQuality) as? String
    let savedProfile = UserDefaults.standard.object(forKey: PersistenceKey.livePlaybackProfile) as? String
    let pane = controller.panes[0]
    let view = PlayerView(channel: pane.channel.login, auth: TwitchAuthSession(), model: pane.model)
    view.preferredQuality = "720p"
    view.livePlaybackProfile = .nativeLowLatency
    XCTAssertEqual(pane.presentation.quality, "720p")
    XCTAssertEqual(pane.presentation.profile, .nativeLowLatency)
    XCTAssertEqual(UserDefaults.standard.string(forKey: PersistenceKey.preferredQuality), savedQuality)
    XCTAssertEqual(UserDefaults.standard.string(forKey: PersistenceKey.livePlaybackProfile), savedProfile)
    XCTAssertEqual(controller.panes[1].presentation.profile, .nativeLowLatency)
  }
}
