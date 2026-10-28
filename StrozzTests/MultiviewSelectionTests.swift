import XCTest
@testable import Strozz

@MainActor
final class MultiviewSelectionTests: XCTestCase {
  func testOfflineSelectionFreesCapacityAndFadesAfterTenSeconds() throws {
    let channels = (0...6).map { channel("creator\($0)") }
    let sections = section(channels)
    var selection = MultiviewSelection()
    for channel in channels.prefix(6) { XCTAssertEqual(selection.toggle(channel, in: sections), .updated) }
    XCTAssertEqual(selection.toggle(channels[6], in: sections), .limitReached)
    let now = ContinuousClock.now
    let remaining = section(Array(channels.dropFirst()))
    selection.reconcile(remaining, now: now)
    XCTAssertEqual(selection.channels(in: remaining).count, 5)
    let retained = try XCTUnwrap(selection.presentedSections(remaining).first?.channels.first)
    XCTAssertEqual(retained.channelKey, channels[0].channelKey)
    XCTAssertFalse(retained.isLive)
    XCTAssertEqual(selection.toggle(channels[6], in: remaining), .updated)
    XCTAssertEqual(selection.channels(in: remaining).count, 6)
    selection.reconcile(remaining, now: now.advanced(by: .seconds(8)))
    XCTAssertEqual(selection.nextExpiry, now.advanced(by: .seconds(10)))
    selection.expire(at: now.advanced(by: .milliseconds(9_999)))
    XCTAssertEqual(selection.entries.count, 7)
    selection.expire(at: now.advanced(by: .seconds(10)))
    XCTAssertEqual(selection.entries.count, 6)
    XCTAssertEqual(selection.presentedSections(remaining).flatMap(\.channels).count, 6)
  }

  func testRecoveringDuringGraceKeepsSelectionAndCancelsExpiry() {
    let channels = [channel("one"), channel("two")]
    var selection = MultiviewSelection()
    for channel in channels { selection.toggle(channel, in: section(channels)) }
    let now = ContinuousClock.now
    selection.reconcile(section([channels[1]]), now: now)
    XCTAssertNotNil(selection.nextExpiry)
    selection.reconcile(section(channels), now: now.advanced(by: .seconds(9)))
    XCTAssertNil(selection.nextExpiry)
    selection.expire(at: now.advanced(by: .seconds(11)))
    XCTAssertEqual(selection.channels(in: section(channels)).map(\.channelKey), ["one", "two"])
    selection.reconcile(section([channels[1]]), now: now.advanced(by: .seconds(12)))
    XCTAssertEqual(selection.nextExpiry, now.advanced(by: .seconds(22)))
  }

  func testChangingPoolIDsPreservesSelectionOrderAndFreshMetadata() {
    var selection = MultiviewSelection()
    let old = [channel("one", id: "user-1"), channel("two")]
    selection.toggle(old[1], in: section(old))
    selection.toggle(old[0], in: section(old))
    let updated = [channel("one", id: "stream-99"), old[1]]
    selection.reconcile(section(updated))
    XCTAssertEqual(selection.channels(in: section(updated)).map(\.id), ["two", "stream-99"])
    XCTAssertNil(selection.nextExpiry)
    XCTAssertEqual(selection.toggle(updated[0], in: section(updated)), .updated)
    XCTAssertEqual(selection.entries.count, 1)
  }

  func testProviderQualifiedSelectionsAndOfflineManualRemoval() {
    let twitch = channel("same")
    var kick = channel("same")
    kick.platform = .kick
    let sections = section([twitch, kick])
    var selection = MultiviewSelection()
    selection.toggle(twitch, in: sections)
    selection.toggle(kick, in: sections)
    selection.reconcile(section([kick]))
    XCTAssertEqual(selection.channels(in: section([kick])).map(\.channelKey), ["kick:same"])
    XCTAssertEqual(selection.toggle(twitch, in: section([kick])), .updated)
    XCTAssertEqual(selection.entries.count, 1)
    XCTAssertNil(selection.nextExpiry)
  }

  func testEntireDisappearingSectionRetainsNoticesButCannotLaunchOfflineChannels() {
    let channels = [channel("one"), channel("two")]
    var selection = MultiviewSelection()
    for channel in channels { selection.toggle(channel, in: section(channels)) }
    let now = ContinuousClock.now
    selection.reconcile([], now: now)
    XCTAssertTrue(selection.channels(in: []).isEmpty)
    XCTAssertEqual(selection.presentedSections([]).first?.title, "Following")
    XCTAssertEqual(selection.presentedSections([]).first?.channels.count, 2)
    selection.expire(at: now.advanced(by: .seconds(10)))
    XCTAssertTrue(selection.entries.isEmpty)
    XCTAssertTrue(selection.presentedSections([]).isEmpty)
    XCTAssertEqual(selection.toggle(channels[0], in: []), .unavailable)
  }

  private func section(_ channels: [FollowedChannel]) -> [MultiviewChannelSection] {
    [.init(id: "following", title: "Following", channels: channels)]
  }

  private func channel(_ login: String, id: String? = nil) -> FollowedChannel {
    .init(id: id ?? login, login: login, displayName: login, title: "", gameName: "",
      viewerCount: 1, thumbnailURL: nil, profileImageURL: nil, isLive: true)
  }
}
