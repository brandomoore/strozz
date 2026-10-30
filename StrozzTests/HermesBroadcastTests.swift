import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

@MainActor
final class HermesBroadcastTests: XCTestCase {
  func testRealEnvelopeRoutesBroadcastEventsWithoutSignInOrChangingMoments() {
    let service = HermesEventService()
    service.prepareBroadcastFixture(channel: "FIXTURE")
    defer { service.stop() }
    var updates: [StreamLiveStatus] = []
    service.onBroadcastStatusChanged = { channel, status in
      XCTAssertEqual(channel, "fixture")
      updates.append(status)
    }
    service.handle(Self.frame("viewcount", extra: ",\"viewers\":42"))
    XCTAssertEqual(service.viewerCount, 42)
    XCTAssertTrue(updates.isEmpty)
    service.handle(Self.frame("stream-down", extra: ",\"server_time\":100"))
    XCTAssertEqual(service.broadcast.status, .offline)
    XCTAssertEqual(updates, [.offline])
    XCTAssertNil(service.currentMoment)
    service.handle(Self.frame("stream-up", extra: ",\"server_time\":101"))
    service.handle(Self.frame("stream-down", extra: ",\"server_time\":100"))
    XCTAssertEqual(updates, [.offline, .live])
    service.invalidateBroadcastStatus()
    XCTAssertEqual(updates, [.offline, .live, .unknown])
    XCTAssertEqual(service.broadcast.status, .unknown)
  }

  func testStoppedServiceAndMalformedEventsCannotPublishOffline() {
    let service = HermesEventService()
    var updates = 0
    service.onBroadcastStatusChanged = { _, _ in updates += 1 }
    service.prepareBroadcastFixture(channel: "fixture")
    service.handle(Self.frame("stream-down", extra: ",\"server_time\":\"broken\""))
    XCTAssertEqual(updates, 0)
    service.stop()
    service.handle(Self.frame("stream-down"))
    XCTAssertEqual(updates, 0)
  }

  static func frame(_ type: String, extra: String = "") -> String {
    let payload = "{\"type\":\"\(type)\"\(extra)}"
    let encoded = payload.replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"type\":\"notification\",\"notification\":{\"pubsub\":\"\(encoded)\"}}"
  }
}
