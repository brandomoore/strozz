import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

final class TwitchCollaborationTests: XCTestCase {
  private let host = #"{"id":"1","login":"burn","displayName":"Burn"}"#
  private let guest = #"{"id":"2","login":"willneff","displayName":"willneff"}"#

  private func response(channelID: String = "1", live: Bool = true, session: String) -> Data {
    Data("""
      {"data":{"user":{"stream":\(live ? #"{"id":"live"}"# : "null")},
       "guestStarChannelCollaboration":[{"id":"\(channelID)","session":\(session)}]}}
      """.utf8)
  }

  func testHostIsListedOnceAndGuestsDoNotNeedTheirOwnBroadcast() throws {
    let data = response(session: """
      {"host":\(host),"guests":[{"user":\(host)},{"user":\(guest)},{"user":\(guest)},null,{"user":null}]}
      """)
    let people = try TwitchCollaborationService.participants(from: data, channelID: "1")
    XCTAssertEqual(people.map(\.id), ["1", "2"])
    XCTAssertEqual(people.map(\.name).joined(separator: " + "), "Burn + willneff")
  }

  func testGuestPageStartsWithItsOwnBroadcaster() throws {
    let data = response(channelID: "2", session: """
      {"host":\(host),"guests":[{"user":\(host)},{"user":\(guest)}]}
      """)
    let people = try TwitchCollaborationService.participants(from: data, channelID: "2")
    XCTAssertEqual(people.map(\.id), ["2", "1"])
  }

  func testEndedSoloOfflineAndMismatchedSessionsAreHidden() throws {
    let session = #"{"host":\#(host),"guests":[{"user":\#(guest)}]}"#
    for data in [
      response(session: "null"),
      response(session: #"{"host":\#(host),"guests":[{"user":\#(host)}]}"#),
      response(live: false, session: session),
      response(channelID: "3", session: session),
      response(session: #"{"host":\#(guest),"guests":[]}"#),
    ] {
      XCTAssertTrue(try TwitchCollaborationService.participants(from: data, channelID: "1").isEmpty)
    }
  }

  func testDisplayNameFallbackAndEmptyLogins() throws {
    let data = response(session: """
      {"host":\(host),"guests":[
        {"user":{"id":"2","login":"willneff","displayName":"  "}},
        {"user":{"id":"3","login":"  ","displayName":"Bad"}},
        {"user":{"id":"4","login":"WILLNEFF","displayName":null}}]}
      """)
    XCTAssertEqual(try TwitchCollaborationService.participants(from: data, channelID: "1")
      .map(\.name), ["Burn", "willneff"])
  }

  func testGraphQLErrorsAreNotReportedAsNoCollaboration() {
    for json in [
      #"{"errors":[{"message":"Unavailable"}]}"#,
      #"{"data":{"user":{"stream":null},"guestStarChannelCollaboration":[]},"errors":[{"message":"Partial"}]}"#,
      #"{"data":{"user":{"stream":null}}}"#,
    ] {
      XCTAssertThrowsError(try TwitchCollaborationService.participants(
        from: Data(json.utf8), channelID: "1"))
    }
  }

  func testRequestUsesPublicMetadataWithoutAuthorization() async throws {
    let data = response(session: #"{"host":\#(host),"guests":[{"user":\#(guest)}]}"#)
    let service = TwitchCollaborationService(loadData: { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual((body["variables"] as? [String: String])?["id"], "1")
      return (data, try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200,
        httpVersion: nil, headerFields: nil)))
    })
    let people = try await service.fetch(channelID: "1")
    XCTAssertEqual(people.map(\.id), ["1", "2"])
  }

  func testHTTPFailureIsSurfaced() async {
    let service = TwitchCollaborationService(loadData: { request in
      (Data(), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 503,
        httpVersion: nil, headerFields: nil)))
    })
    do {
      _ = try await service.fetch(channelID: "1")
      XCTFail("Expected a server error")
    } catch {
      XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
    }
  }
}
