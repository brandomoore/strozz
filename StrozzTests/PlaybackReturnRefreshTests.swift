import XCTest

@testable import Strozz

@MainActor
final class PlaybackReturnRefreshTests: XCTestCase {
  func testHomeOnlyPlaybackRefreshesAfterDismissal() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    var refreshes = 0

    coordinator.playerDidDismiss { refreshes += 1 }
    await coordinator.inFlight?.value

    XCTAssertEqual(refreshes, 1)
    XCTAssertNil(coordinator.inFlight)
  }

  func testEveryReturnRefreshesThumbnailURLsWithoutChangingChannelIdentity() async throws {
    let coordinator = PlaybackReturnRefreshCoordinator()
    let channel = channel(id: "fixture", login: "example", title: "Live", viewers: 1)
    let url = try XCTUnwrap(URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_example-640x360.jpg"))
    let original = coordinator.thumbnailRevision
    let before = LiveThumbnailPolicy.freshURL(from: url, renderedWidth: 320, scale: 1, token: original.uuidString)
    coordinator.playerDidDismiss {}
    await coordinator.inFlight?.value
    let after = LiveThumbnailPolicy.freshURL(from: url, renderedWidth: 320, scale: 1,
      token: coordinator.thumbnailRevision.uuidString)
    XCTAssertNotEqual(before, after)
    XCTAssertEqual(before?.path, after?.path)
    XCTAssertEqual(channel.channelKey, "example", "Refresh must not require replacing focus/row identity")
  }

  func testOriginWaitsForDismissalAndIsConsumedOnce() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    var calls: [String] = []
    coordinator.prepareOrigin { calls.append("category") }
    XCTAssertTrue(calls.isEmpty)

    coordinator.playerDidDismiss { calls.append("home") }
    await coordinator.inFlight?.value
    coordinator.playerDidDismiss { calls.append("home") }
    await coordinator.inFlight?.value

    XCTAssertEqual(calls, ["category", "home", "home"])
  }

  func testLatestOriginReplacesPreviousList() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    var calls: [String] = []
    coordinator.prepareOrigin { calls.append("directory") }
    coordinator.prepareOrigin { calls.append("search") }

    coordinator.playerDidDismiss { calls.append("home") }
    await coordinator.inFlight?.value

    XCTAssertEqual(calls, ["search", "home"])
  }

  func testClosingChannelPageWithoutPlayingRefreshesOrigin() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    var calls: [String] = []
    coordinator.prepareOrigin { calls.append("search") }

    coordinator.playerDidDismiss { calls.append("home") }
    await coordinator.inFlight?.value

    XCTAssertEqual(calls, ["search", "home"])
  }

  func testStartingPlayerPreservesChannelPageOrigin() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    var calls: [String] = []
    coordinator.prepareOrigin { calls.append("directory") }
    coordinator.cancelRefresh()

    coordinator.playerDidDismiss { calls.append("home") }
    await coordinator.inFlight?.value

    XCTAssertEqual(calls, ["directory", "home"])
  }

  func testCancelledRefreshDoesNotContinueAfterAnotherPlayerOpens() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    let started = expectation(description: "Origin refresh started")
    let gate = RefreshGate()
    var homeRefreshes = 0
    coordinator.prepareOrigin {
      started.fulfill()
      await gate.wait()
    }
    coordinator.playerDidDismiss { homeRefreshes += 1 }
    let oldTask = coordinator.inFlight
    await fulfillment(of: [started], timeout: 2)

    coordinator.cancelRefresh()
    gate.resume()
    await oldTask?.value

    XCTAssertEqual(homeRefreshes, 0)
    XCTAssertNil(coordinator.inFlight)
  }

  func testOldCompletionCannotClearNewRefreshTask() async {
    let coordinator = PlaybackReturnRefreshCoordinator()
    let oldStarted = expectation(description: "Old refresh started")
    let newStarted = expectation(description: "New refresh started")
    let oldGate = RefreshGate()
    let newGate = RefreshGate()
    var homeRefreshes = 0
    coordinator.prepareOrigin {
      oldStarted.fulfill()
      await oldGate.wait()
    }
    coordinator.playerDidDismiss { homeRefreshes += 1 }
    let oldTask = coordinator.inFlight
    await fulfillment(of: [oldStarted], timeout: 2)

    coordinator.prepareOrigin {
      newStarted.fulfill()
      await newGate.wait()
    }
    coordinator.playerDidDismiss { homeRefreshes += 1 }
    let newTask = coordinator.inFlight
    await fulfillment(of: [newStarted], timeout: 2)

    oldGate.resume()
    await oldTask?.value
    XCTAssertNotNil(coordinator.inFlight)
    newGate.resume()
    await newTask?.value
    XCTAssertEqual(homeRefreshes, 1)
    XCTAssertNil(coordinator.inFlight)
  }

  func testChannelIdentitySurvivesNewBroadcastMetadataAndReordering() {
    let original = channel(id: "user-1", login: "Example", title: "Original", viewers: 10)
    let updated = channel(id: "new-stream-2", login: "example", title: "Updated", viewers: 100)
    let other = channel(id: "user-3", login: "other", title: "Other", viewers: 50)
    let refreshed = [updated, other].sorted { ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) }

    XCTAssertNotEqual(original, updated)
    XCTAssertNotEqual(original.id, updated.id)
    XCTAssertEqual(original.channelKey, updated.channelKey)
    XCTAssertEqual(refreshed.first(where: { $0.channelKey == original.channelKey })?.title, "Updated")
    XCTAssertNil([other].first(where: { $0.channelKey == original.channelKey }))
  }

  func testRailPrefixesKeepSameChannelDistinctAcrossSections() {
    let followed = channel(id: "user", login: "example", title: "Live", viewers: 1)
    let recommended = channel(id: "stream", login: "example", title: "Live", viewers: 1)

    XCTAssertEqual(followed.channelKey, recommended.channelKey)
    XCTAssertNotEqual("following-\(followed.channelKey)", "foryou-\(recommended.channelKey)")
    XCTAssertNotEqual("following-\(followed.channelKey)", "topstreams-\(recommended.channelKey)")
  }

  func testMissingLoginRetainsStableIDFallback() {
    XCTAssertEqual(channel(id: "channel-1", login: "", title: "", viewers: 0).channelKey, "channel-1")
  }

  private func channel(id: String, login: String, title: String, viewers: Int) -> FollowedChannel {
    FollowedChannel(
      id: id, login: login, displayName: login, title: title, gameName: "",
      viewerCount: viewers, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }
}

@MainActor
private final class RefreshGate {
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
