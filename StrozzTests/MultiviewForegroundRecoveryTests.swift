import XCTest

@testable import Strozz

@MainActor
final class MultiviewForegroundRecoveryTests: XCTestCase {
  func testReturnFromBackgroundReloadsEveryPaneWithFreshPlaylist() async {
    let channels = ["one", "two", "three"].map { login in
      FollowedChannel(
        id: login, login: login, displayName: login, title: "", gameName: "",
        viewerCount: nil, thumbnailURL: nil, profileImageURL: nil, isLive: true)
    }
    var calls: [(channel: String, bitrate: Int, forceRefresh: Bool)] = []
    let initial = expectation(description: "All panes resolve initially")
    initial.expectedFulfillmentCount = channels.count
    let returnFromBackground = expectation(description: "All panes resolve on return")
    returnFromBackground.expectedFulfillmentCount = channels.count
    let controller = MultiviewController(channels: channels) { channel, bitrate, forceRefresh in
      calls.append((channel, bitrate, forceRefresh))
      if forceRefresh {
        returnFromBackground.fulfill()
      } else {
        initial.fulfill()
      }
      return URL(fileURLWithPath: "/dev/null")
    }
    defer { controller.teardown() }

    controller.start()
    await fulfillment(of: [initial], timeout: 5)
    XCTAssertEqual(Set(calls.map(\.channel)), Set(channels.map(\.login)))
    XCTAssertTrue(calls.allSatisfy { !$0.forceRefresh && $0.bitrate == 3_000_000 })

    controller.suspend()
    controller.reloadAfterForeground()
    await fulfillment(of: [returnFromBackground], timeout: 5)
    XCTAssertEqual(calls.count, channels.count * 2)
    XCTAssertEqual(Set(calls.filter(\.forceRefresh).map(\.channel)), Set(channels.map(\.login)))
    XCTAssertTrue(calls.filter(\.forceRefresh).allSatisfy { $0.bitrate == 3_000_000 })
  }
}
