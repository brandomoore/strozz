import AVFoundation
import SwiftUI
import XCTest
@testable import Strozz

@MainActor
final class MultiviewLineupTests: XCTestCase {
  func testExternalDiscoveryAndPoolIDsShareOneSelection() {
    let lineup = MultiviewLineup { _ in .live }
    let search = channel("not-followed", id: "user-id")
    lineup.toggle(search)
    XCTAssertEqual(lineup.liveChannels, [search])
    XCTAssertNil(lineup.controller, "Selecting must never start playback")
    XCTAssertTrue(lineup.contains(channel("NOT-FOLLOWED", id: "stream-id")))
    lineup.toggle(channel("NOT-FOLLOWED", id: "stream-id"))
    XCTAssertTrue(lineup.entries.isEmpty)
  }

  func testProvidersRemainDistinctAndCapacityErrorsAreVisible() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("same", id: "same-id"))
    lineup.toggle(channel("same", id: "same-id", platform: .kick))
    for index in 2..<6 { lineup.toggle(channel("channel\(index)")) }
    XCTAssertEqual(lineup.liveChannels.count, 6)
    lineup.toggle(channel("seventh"))
    XCTAssertEqual(lineup.liveChannels.count, 6)
    XCTAssertNotNil(lineup.notice)
    lineup.startPlayback()
    let panes = try XCTUnwrap(lineup.controller).panes
    XCTAssertEqual(Set(panes.map(\.id)).count, 6)
    XCTAssertEqual(panes[1].channel.platform, .kick)
  }

  func testOfflineAndYouTubeCannotEnterDraft() {
    let lineup = MultiviewLineup { _ in .live }
    lineup.toggle(channel("offline", live: false))
    XCTAssertTrue(lineup.entries.isEmpty)
    XCTAssertNotNil(lineup.notice)
    lineup.toggle(channel("youtube", platform: .youtube))
    XCTAssertTrue(lineup.entries.isEmpty)
    XCTAssertFalse(lineup.canStart)
    lineup.startPlayback()
    XCTAssertNil(lineup.controller)
  }

  func testExplicitOfflineFreesCapacityAndExpiresAfterTenSeconds() {
    let lineup = MultiviewLineup { _ in .live }
    for index in 0..<6 { lineup.toggle(channel("channel\(index)")) }
    let now = ContinuousClock.now
    lineup.observe(.unknown, key: "channel0", now: now)
    XCTAssertTrue(lineup.isFull)
    lineup.observe(.offline, key: "channel0", now: now)
    XCTAssertEqual(lineup.liveChannels.count, 5)
    XCTAssertEqual(lineup.entries.count, 6)
    lineup.observe(.offline, key: "channel0", now: now.advanced(by: .seconds(5)))
    lineup.expire(at: now.advanced(by: .seconds(9)))
    XCTAssertEqual(lineup.entries.count, 6)
    lineup.toggle(channel("replacement"))
    XCTAssertEqual(lineup.liveChannels.count, 6)
    lineup.observe(.live, key: "channel0", now: now.advanced(by: .seconds(9)))
    XCTAssertEqual(lineup.liveChannels.count, 6, "Recovery cannot take a seventh slot")
    lineup.expire(at: now.advanced(by: .seconds(10)))
    XCTAssertFalse(lineup.contains(channel("channel0")))
    XCTAssertEqual(lineup.entries.count, 6)
  }

  func testRecoveryWithinGraceRetainsOrderAndIdentity() {
    let lineup = MultiviewLineup { _ in .live }
    lineup.toggle(channel("first"))
    lineup.toggle(channel("second"))
    let ids = lineup.entries.map(\.id)
    let now = ContinuousClock.now
    lineup.observe(.offline, key: "first", now: now)
    lineup.observe(.unknown, key: "first", now: now.advanced(by: .seconds(2)))
    lineup.observe(.live, key: "first", now: now.advanced(by: .seconds(5)))
    lineup.expire(at: now.advanced(by: .seconds(20)))
    XCTAssertEqual(lineup.entries.map(\.id), ids)
    XCTAssertEqual(lineup.liveChannels.map(\.login), ["first", "second"])
  }

  func testActiveOfflinePanePersistsUntilBrowsingAndDoesNotOversubscribe() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    for index in 0..<6 { lineup.toggle(channel("channel\(index)")) }
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    let now = ContinuousClock.now
    lineup.observe(.offline, key: "channel0", now: now)
    lineup.expire(at: now.advanced(by: .seconds(100)))
    XCTAssertEqual(controller.panes.count, 6)
    XCTAssertTrue(lineup.isFull)
    XCTAssertNil(lineup.nextExpiry)
    lineup.browse()
    XCTAssertEqual(controller.panes.count, 5)
    lineup.toggle(channel("replacement"))
    XCTAssertEqual(controller.panes.count, 6)
    lineup.expire(at: now.advanced(by: .seconds(100)))
    XCTAssertFalse(lineup.contains(channel("channel0")))
  }

  func testBrowsingAndAddingRetainControllerPlayersLayoutAndAudioOwner() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("one"))
    lineup.toggle(channel("two"))
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    let first = controller.panes[0]
    let player = first.player
    controller.spotlight(first.id)
    controller.setAudiblePane(first.id)
    lineup.browse()
    XCTAssertTrue(controller.isBrowsing)
    XCTAssertTrue(controller.panes.allSatisfy { $0.presentation.isBrowsing && !$0.presentation.videoIsVisible })
    lineup.toggle(channel("three", platform: .kick))
    XCTAssertEqual(controller.panes.count, 3)
    XCTAssertTrue(controller.panes[2].presentation.isBrowsing)
    let hidden = PlayerView(channel: "one", auth: TwitchAuthSession(), model: first.model)
    XCTAssertFalse(hidden.shouldPlayAltSource)
    XCTAssertFalse(hidden.preparePlaybackAudio(reason: "test"))
    lineup.startPlayback()
    XCTAssertTrue(lineup.controller === controller)
    XCTAssertTrue(controller.panes[0] === first)
    XCTAssertTrue(first.player === player)
    XCTAssertEqual(controller.layout, .spotlight)
    XCTAssertEqual(controller.audiblePaneID, first.id)
    XCTAssertTrue(controller.panes.allSatisfy { !$0.presentation.isBrowsing && $0.presentation.videoIsVisible })
    lineup.remove("two")
    XCTAssertEqual(controller.panes.map(\.channel.channelKey), ["one", "kick:three"])
    lineup.browse()
    lineup.remove("one")
    lineup.startPlayback()
    XCTAssertEqual(controller.restoredPaneID, controller.panes.first?.id)
    XCTAssertEqual(controller.audiblePaneID, controller.restoredPaneID)
    lineup.remove("kick:three")
    XCTAssertNil(lineup.controller)
    XCTAssertTrue(lineup.entries.isEmpty)
    XCTAssertFalse(lineup.isShowingPlayback)
  }

  func testRefreshChecksSelectedChannelsNotAnyDiscoveryPool() async {
    var checked: [String] = []
    let lineup = MultiviewLineup { channel in
      checked.append(channel.channelKey)
      return channel.platform == .kick ? .unknown : .live
    }
    lineup.toggle(channel("search-only"))
    lineup.toggle(channel("kick-only", platform: .kick))
    await lineup.refreshStatuses()
    XCTAssertEqual(checked, ["search-only", "kick:kick-only"])
    XCTAssertEqual(lineup.liveChannels.count, 2)
    XCTAssertNil(lineup.nextExpiry)
  }

  func testReturningToVisibleWallCollapsesWithoutReplacingPlayersOrTogglingTransport() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("one"))
    lineup.toggle(channel("two"))
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    let panes = controller.panes
    let players = panes.map(\.player)
    controller.spotlight(panes[1].id)
    controller.expand(panes[1].id)
    let transportRequests = panes.map(\.presentation.playPauseRequests)
    XCTAssertNotNil(controller.expandedPaneID)

    lineup.requestPlayback()
    XCTAssertTrue(lineup.isOpeningPlayback)
    lineup.startPlayback()
    XCTAssertFalse(lineup.isOpeningPlayback)
    XCTAssertTrue(lineup.controller === controller)
    XCTAssertNil(controller.expandedPaneID)
    XCTAssertEqual(controller.layout, .spotlight)
    XCTAssertEqual(controller.audiblePaneID, panes[1].id)
    XCTAssertEqual(panes.map(\.presentation.playPauseRequests), transportRequests)
    for index in panes.indices {
      XCTAssertTrue(controller.panes[index] === panes[index])
      XCTAssertTrue(controller.panes[index].player === players[index])
    }
    lineup.startPlayback()
    XCTAssertNil(controller.expandedPaneID, "Another hold on the wall is not a toggle")
    XCTAssertNil(lineup.notice)
  }

  func testReturningToAlreadyVisibleOfflineWallDoesNotShowASelectionAlert() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("one"))
    lineup.toggle(channel("two"))
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    controller.expand(controller.panes[0].id)
    lineup.observe(.offline, key: "one")
    lineup.observe(.offline, key: "two")
    XCTAssertFalse(lineup.canStart)
    lineup.startPlayback()
    XCTAssertTrue(lineup.isShowingPlayback)
    XCTAssertTrue(lineup.controller === controller)
    XCTAssertNil(controller.expandedPaneID)
    XCTAssertNil(lineup.notice)
  }

  func testWindowShortcutInstallationIsIdempotentAndScopedToItsOwnWindow() throws {
    let lineup = MultiviewLineup { _ in .live }
    let first = UIWindow()
    let second = UIWindow()
    let unrelated = UITapGestureRecognizer()
    first.addGestureRecognizer(unrelated)
    let coordinator = MultiviewRemoteShortcut.Coordinator(lineup: lineup,
      palette: AppTheme.light.palette(systemColorScheme: .light), glassDisabled: true)
    defer { coordinator.attach(to: nil) }
    coordinator.attach(to: first)
    let recognizer = try XCTUnwrap(first.gestureRecognizers?.first { $0 !== unrelated } as? UILongPressGestureRecognizer)
    XCTAssertEqual(recognizer.allowedPressTypes, [NSNumber(value: UIPress.PressType.playPause.rawValue)])
    XCTAssertEqual(recognizer.minimumPressDuration, 0.7)
    coordinator.attach(to: first)
    XCTAssertEqual(first.gestureRecognizers?.count, 2)

    let shortPress = UITapGestureRecognizer()
    shortPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
    XCTAssertTrue(coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: shortPress))
    let select = UITapGestureRecognizer()
    select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
    XCTAssertFalse(coordinator.gestureRecognizer(recognizer, shouldBeRequiredToFailBy: select))

    coordinator.attach(to: second)
    XCTAssertEqual(first.gestureRecognizers, [unrelated])
    XCTAssertEqual(second.gestureRecognizers?.count, 1)
    coordinator.attach(to: nil)
    XCTAssertTrue(second.gestureRecognizers?.isEmpty ?? true)
    XCTAssertEqual(first.gestureRecognizers, [unrelated])
    XCTAssertNil(lineup.controller)
  }

  func testPresentationHandoffRemainsBusyUntilStartOrCancellation() {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    let request = lineup.playbackRequest
    lineup.preparePlaybackRequest()
    XCTAssertTrue(lineup.isOpeningPlayback)
    XCTAssertEqual(lineup.playbackRequest, request, "Modal dismissal must finish before navigation")
    lineup.cancelPlaybackRequest()
    XCTAssertFalse(lineup.isOpeningPlayback)
    lineup.requestPlayback()
    XCTAssertTrue(lineup.isOpeningPlayback)
    XCTAssertNotEqual(lineup.playbackRequest, request)
    lineup.startPlayback()
    XCTAssertFalse(lineup.isOpeningPlayback, "A rejected request must also release the handoff")
    XCTAssertNotNil(lineup.notice)
    lineup.preparePlaybackRequest()
    lineup.clear()
    XCTAssertFalse(lineup.isOpeningPlayback)
  }

  func testStaleStatusCannotExpireAReaddedSelection() async throws {
    let requested = expectation(description: "Status request")
    var pending: CheckedContinuation<StreamLiveStatus, Never>?
    let lineup = MultiviewLineup { _ in
      await withCheckedContinuation {
        pending = $0
        requested.fulfill()
      }
    }
    lineup.toggle(channel("one"))
    let task = Task { await lineup.refreshStatuses() }
    await fulfillment(of: [requested], timeout: 2)
    lineup.remove("one")
    lineup.toggle(channel("one"))
    try XCTUnwrap(pending).resume(returning: .offline)
    await task.value
    XCTAssertNil(lineup.entries.first?.offlineSince)
  }

  func testSourceSwitchUpdatesTheSameLineupEntry() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("one"))
    lineup.toggle(channel("two"))
    let id = lineup.entries[0].id
    lineup.startPlayback()
    let pane = try XCTUnwrap(lineup.controller?.panes.first)
    pane.channel = channel("kick-source", platform: .kick)
    lineup.synchronize(pane, previousKey: "one")
    XCTAssertEqual(lineup.entries[0].id, id)
    XCTAssertEqual(lineup.entries[0].channel.channelKey, "kick:kick-source")
    XCTAssertFalse(lineup.contains(channel("one")))
  }

  func testHiddenNativeRecoveryCannotRestartProducersOrAudio() {
    let pane = MultiviewPane(channel: channel("hidden"))
    defer { pane.stop() }
    let view = PlayerView(channel: "hidden", auth: TwitchAuthSession(), model: pane.model)
    pane.model.isUsingNativeHLS = true
    pane.model.nativeNeedsRefresh = true
    pane.model.mediaServicesResetPending = true
    pane.presentation.isBrowsing = true
    view.refreshNativeAfterSuspension()
    view.recoverMediaServicesIfNeeded()
    XCTAssertNil(pane.model.nativeRefreshTask)
    XCTAssertTrue(pane.model.mediaServicesResetPending)
    XCTAssertFalse(view.preparePlaybackAudio(reason: "hidden recovery"))
  }

  func testSwitchingIntoAnExistingChannelDoesNotLeaveDuplicatePanes() throws {
    let lineup = MultiviewLineup { _ in .live }
    defer { lineup.clear() }
    lineup.toggle(channel("one"))
    lineup.toggle(channel("two"))
    lineup.startPlayback()
    let controller = try XCTUnwrap(lineup.controller)
    let originalTwo = controller.panes[1]
    let switching = controller.panes[0]
    switching.channel = channel("two")
    lineup.synchronize(switching, previousKey: "one")
    XCTAssertEqual(lineup.entries.count, 1)
    XCTAssertEqual(controller.panes.count, 1)
    XCTAssertTrue(controller.panes[0] === originalTwo)
  }

  func testBrowsingResumeIsOneShotAndDoesNotInterceptOrdinaryRetries() {
    let pane = MultiviewPane(channel: channel("retry"))
    defer { pane.stop() }
    let view = PlayerView(channel: "retry", auth: TwitchAuthSession(), model: pane.model)
    pane.model.nativeNeedsRefresh = true
    XCTAssertFalse(view.resumeMultiviewAfterBrowsingIfNeeded())
    XCTAssertNil(pane.model.nativeRefreshTask)
    pane.presentation.needsBrowsingResume = true
    pane.model.nativeNeedsRefresh = false
    XCTAssertFalse(view.resumeMultiviewAfterBrowsingIfNeeded(),
      "A pane first added while browsing must take its initial load path")
    XCTAssertFalse(pane.presentation.needsBrowsingResume)
  }

  private func channel(_ login: String, id: String? = nil, platform: LivePlatform = .twitch,
                       live: Bool = true) -> FollowedChannel {
    var value = FollowedChannel(id: id ?? login, login: login, displayName: login,
      title: "", gameName: "", viewerCount: nil, thumbnailURL: nil,
      profileImageURL: nil, isLive: live)
    value.platform = platform
    return value
  }
}
