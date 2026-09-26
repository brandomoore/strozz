import XCTest

@testable import Strozz

final class PlaybackServiceLiveStatusTests: XCTestCase {
  func testActiveBroadcastIsLive() {
    XCTAssertEqual(status(#"{"data":{"user":{"stream":{"id":"123","type":"live"}}}}"#), .live)
  }

  func testExplicitlyNullStreamConfirmsOffline() {
    XCTAssertEqual(status(#"{"data":{"user":{"stream":null}}}"#), .offline)
  }

  func testExplicitlyNullUserConfirmsUnavailableChannel() {
    XCTAssertEqual(status(#"{"data":{"user":null}}"#), .offline)
  }

  func testGraphQLErrorIsUnknownEvenWithNullStream() {
    XCTAssertEqual(
      status(#"{"data":{"user":{"stream":null}},"errors":[{"message":"Lookup failed"}]}"#),
      .unknown)
  }

  func testMissingOrMalformedFieldsCannotConfirmOffline() {
    let responses = [
      "not json",
      "null",
      "{}",
      #"{"data":null}"#,
      #"{"data":{}}"#,
      #"{"data":{"user":{}}}"#,
      #"{"data":{"user":false}}"#,
      #"{"data":{"user":[]}}"#,
      #"{"data":{"user":"unavailable"}}"#,
      #"{"data":{"user":{"stream":false}}}"#,
      #"{"data":{"user":{"stream":[]}}}"#,
      #"{"data":{"user":{"stream":"unavailable"}}}"#,
      #"{"data":{"user":{"stream":{}}}}"#,
      #"{"data":{"user":{"stream":{"id":""}}}}"#,
    ]
    for response in responses {
      XCTAssertEqual(status(response), .unknown, response)
    }
  }

  private func status(_ json: String) -> StreamLiveStatus {
    PlaybackService.parseStreamLiveStatus(Data(json.utf8))
  }
}
