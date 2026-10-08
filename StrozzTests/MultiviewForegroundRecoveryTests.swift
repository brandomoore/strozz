import AVFoundation
import XCTest
@testable import Strozz

@MainActor
final class MultiviewForegroundRecoveryTests: XCTestCase {
  private func controller(count: Int = 4) -> MultiviewController {
    MultiviewController(channels: (0..<count).map { index in
      FollowedChannel(id: "\(index)", login: "fixture\(index)", displayName: "Fixture \(index)",
        title: "", gameName: "", viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    })
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
    view.livePlaybackProfile = .lowerLatency
    XCTAssertEqual(pane.presentation.quality, "720p")
    XCTAssertEqual(pane.presentation.profile, .lowerLatency)
    XCTAssertEqual(UserDefaults.standard.string(forKey: PersistenceKey.preferredQuality), savedQuality)
    XCTAssertEqual(UserDefaults.standard.string(forKey: PersistenceKey.livePlaybackProfile), savedProfile)
    XCTAssertEqual(controller.panes[1].presentation.profile, .nativeLowLatency)
  }
}
