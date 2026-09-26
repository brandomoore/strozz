import XCTest

@testable import Strozz

final class AltSourceServiceTests: XCTestCase {
  private let liveID = "abcdefghijk"

  private func playerResponse(
    videoID: String = "abcdefghijk",
    details: [String: Any] = ["isLive": true],
    broadcast: [String: Any]? = nil,
    streaming: [String: Any] = ["hlsManifestUrl": "https://manifest.googlevideo.com/master.m3u8?a=1&b=2"]
  ) throws -> Data {
    var response: [String: Any] = [
      "playabilityStatus": ["status": "OK"],
      "videoDetails": details.merging(["videoId": videoID]) { _, new in new },
      "streamingData": streaming,
    ]
    if let broadcast {
      response["microformat"] = ["playerMicroformatRenderer": ["liveBroadcastDetails": broadcast]]
    }
    return try JSONSerialization.data(withJSONObject: response)
  }

  private func assertNoLiveVideo(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(
      try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID), file: file, line: line
    ) { error in
      XCTAssertEqual(
        AltSourceService.errorAttributes(error)["resolver_outcome"], "no_live_video",
        file: file, line: line)
    }
  }

  func testNativeClientUsesSameIdentityForAPIAndMedia() throws {
    let request = try AltSourceService.nativePlayerRequest(forVideoID: "abcdefghijk", visitor: "private-visitor")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    let context = try XCTUnwrap(body["context"] as? [String: Any])
    let client = try XCTUnwrap(context["client"] as? [String: Any])
    XCTAssertEqual(client["clientName"] as? String, "VISIONOS")
    XCTAssertEqual(client["clientVersion"] as? String, "1.02")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "101")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.02")
    XCTAssertEqual(client["userAgent"] as? String, AltSourceService.mediaHTTPHeaders["User-Agent"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), AltSourceService.mediaHTTPHeaders["User-Agent"])
    XCTAssertEqual(body["videoId"] as? String, "abcdefghijk")
    XCTAssertEqual(client["visitorData"] as? String, "private-visitor")
    XCTAssertNil(client["androidSdkVersion"])
    XCTAssertFalse(AltSourceService.resolverAttributes.values.joined().contains("private"))
  }

  func testNativeClientCanBuildRequestWithoutVisitorContext() throws {
    let request = try AltSourceService.nativePlayerRequest(forVideoID: "abcdefghijk", visitor: nil)
    XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
  }

  func testNativeHLSIsReturnedUnmodified() throws {
    let data = try playerResponse()
    XCTAssertEqual(
      try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID).absoluteString,
      "https://manifest.googlevideo.com/master.m3u8?a=1&b=2"
    )
  }

  func testDeniedResponseCannotUseAnIncludedManifest() {
    let data = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED"},"streamingData":{"hlsManifestUrl":"https://example.com/master.m3u8"}}"#.utf8)
    XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID)) { error in
      XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "not_playable")
      XCTAssertEqual(AltSourceService.errorAttributes(error)["playability_status"], "LOGIN_REQUIRED")
    }
  }

  func testSABROrProgressiveResponseDoesNotPretendToBeNativeHLS() throws {
    let data = try playerResponse(streaming: ["serverAbrStreamingUrl": "https://example.com/sabr", "formats": []])
    XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID)) { error in
      XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "no_native_hls")
    }
  }

  func testInvalidManifestIsRejected() throws {
    for manifest in ["relative.m3u8", "file:///private/video", "http://example.com/video"] {
      let data = try playerResponse(streaming: ["hlsManifestUrl": manifest])
      XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID)) { error in
        XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "invalid_manifest")
      }
    }
  }

  func testRegularUploadWithPlayableHLSIsRejected() throws {
    assertNoLiveVideo(try playerResponse(details: ["isLiveContent": false]))
  }

  func testArchivedBroadcastIsNotMistakenForLiveContent() throws {
    assertNoLiveVideo(try playerResponse(details: ["isLiveContent": true]))
    assertNoLiveVideo(try playerResponse(details: ["isLiveContent": true, "isLive": false]))
    assertNoLiveVideo(try playerResponse(
      details: ["isLiveContent": true],
      broadcast: ["isLiveNow": false, "endTimestamp": "2026-09-16T20:00:00Z"]))
  }

  func testUpcomingBroadcastWithHLSIsRejected() throws {
    assertNoLiveVideo(try playerResponse(
      details: ["isLiveContent": true, "isUpcoming": true],
      broadcast: ["isLiveNow": false, "startTimestamp": "2099-09-16T20:00:00Z"]))
    assertNoLiveVideo(try playerResponse(details: ["isLive": true, "isUpcoming": true]))
  }

  func testPostLiveDVRIsRejectedEvenIfNativeLiveFlagRemainsTrue() throws {
    assertNoLiveVideo(try playerResponse(
      details: ["isLiveContent": true, "isLive": true, "isPostLiveDvr": true]))
  }

  func testMissingLiveMetadataDoesNotCountAsConfirmation() throws {
    assertNoLiveVideo(try playerResponse(details: [:]))
  }

  func testExplicitEndOrOfflineStatusOverridesLiveFlag() throws {
    assertNoLiveVideo(try playerResponse(broadcast: ["isLiveNow": false]))
    assertNoLiveVideo(try playerResponse(
      broadcast: ["isLiveNow": true, "endTimestamp": "2026-09-16T20:00:00Z"]))
    assertNoLiveVideo(try playerResponse(details: ["isLive": false], broadcast: ["isLiveNow": true]))
  }

  func testMicroformatCanConfirmCurrentBroadcastWithoutNativeFlag() throws {
    let data = try playerResponse(details: ["isLiveContent": true], broadcast: ["isLiveNow": true])
    XCTAssertNoThrow(try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID))
  }

  func testDifferentOrMissingVideoIdentityIsRejected() throws {
    for data in [
      try playerResponse(videoID: "differentID"),
      Data(#"{"playabilityStatus":{"status":"OK"},"videoDetails":{"isLive":true}}"#.utf8),
    ] {
      XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(in: data, forVideoID: liveID)) { error in
        XCTAssertEqual(AltSourceService.errorAttributes(error)["resolver_outcome"], "video_mismatch")
      }
    }
  }

  func testChannelLookupSelectsPrimaryLivePlayerNotEarlierRecommendation() throws {
    let data = try playerResponse(
      details: ["isLiveContent": true, "title": #"Braces }; and an escaped quote " are title text"#],
      broadcast: ["isLiveNow": true])
    let html = """
      <script>var ytInitialData = {"videoId":"oldvideo123","isLiveNow":true};</script>
      <script>var ytInitialPlayerResponse = \(String(decoding: data, as: UTF8.self)); var next = {};</script>
      """
    XCTAssertEqual(try AltSourceService.liveVideoID(in: html, finalURL: nil), liveID)
  }

  func testWindowPlayerAssignmentIsSupported() throws {
    let html = "window[\"ytInitialPlayerResponse\"] = \(String(decoding: try playerResponse(), as: UTF8.self));"
    XCTAssertEqual(try AltSourceService.liveVideoID(in: html, finalURL: nil), liveID)
  }

  func testOfflineChannelCannotSelectAnUploadOrRecommendedLiveVideo() throws {
    let data = try playerResponse(details: ["isLiveContent": true])
    let html = """
      <script>var ytInitialPlayerResponse = \(String(decoding: data, as: UTF8.self));</script>
      <script>var ytInitialData = {"videoId":"otherlive12","isLiveNow":true};</script>
      """
    XCTAssertThrowsError(try AltSourceService.liveVideoID(in: html, finalURL: nil))
    XCTAssertThrowsError(try AltSourceService.liveVideoID(
      in: #"{"videoId":"otherlive12","isLiveNow":true}"#, finalURL: nil))
  }

  func testMalformedOrUnterminatedPrimaryPlayerCannotUseOtherVideoIDs() {
    for html in [
      #"var ytInitialPlayerResponse = {"videoDetails":{"videoId":"abcdefghijk","isLive":true}"#,
      #"var ytInitialPlayerResponse = {broken}; {"videoId":"otherlive12"}"#,
    ] {
      XCTAssertThrowsError(try AltSourceService.liveVideoID(in: html, finalURL: nil))
    }
  }

  func testWatchRedirectCandidateStillRequiresNativeLiveConfirmation() throws {
    let id = try AltSourceService.liveVideoID(
      in: #"{"videoId":"otherlive12"}"#,
      finalURL: URL(string: "https://www.youtube.com/watch?v=\(liveID)"))
    XCTAssertEqual(id, liveID)
    XCTAssertThrowsError(try AltSourceService.nativeHLSMaster(
      in: playerResponse(details: ["isLiveContent": true]), forVideoID: id))
  }

  func testDiagnosticsDoNotExposeUntrustedResponseProse() {
    let error = AltSourceService.ResolutionError.notPlayable("private-token https://example.com/signed")
    XCTAssertEqual(AltSourceService.errorAttributes(error)["playability_status"], "unknown")
    XCTAssertEqual(
      AltSourceService.errorAttributes(AltSourceService.ResolutionError.httpStatus(403))["http_status"], "403"
    )
    let network = NSError(domain: NSURLErrorDomain, code: -1009,
                          userInfo: [NSLocalizedDescriptionKey: "private-token https://example.com/signed"])
    let attributes = AltSourceService.errorAttributes(network)
    XCTAssertEqual(attributes["error_code"], "-1009")
    XCTAssertFalse(attributes.values.joined().contains("private-token"))
    XCTAssertFalse(attributes.values.joined().contains("https://"))
  }
}
