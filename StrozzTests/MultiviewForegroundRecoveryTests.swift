import AVKit
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewForegroundRecoveryTests: XCTestCase {
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
    XCTAssertTrue(controller.panes.dropFirst().allSatisfy { $0.qualityTier == .thumbnail })
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
      XCTAssertEqual(pane.qualityTier, pane === selected ? .source : .thumbnail)
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
    selected.model.isSleeping = false
    controller.synchronizeExpandedSleep()
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
