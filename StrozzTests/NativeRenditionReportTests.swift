import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeRenditionReportTests: XCTestCase {
  func testFailedUnusedRenditionDoesNotCancelHealthyPlaybackOrRestartOnProbe() async throws {
    for failure in [NativeHLSFailureDetail.httpStatus(503), .timestampInterval(24_390)] {
      let fixture = FailingRenditionFixture(failure: failure)
      let diagnostics = NativeFailureCapture()
      let origin = try await makeFailingOrigin(fixture: fixture, diagnostics: diagnostics) { _ in
        XCTFail("An unused rendition failure must not restart healthy playback")
      }
      for _ in 0..<3 {
        do {
          _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8")!)
          XCTFail("Failed rendition must report an error, not an empty success")
        } catch {
          XCTAssertEqual(NativeHLSError.classify(error), failure.reason)
        }
        do {
          guard case .playlist(let data) = try await origin.response(
            URL(string: "strozz-native-ll://fixture/media/0.m3u8")!) else {
            XCTFail("Expected the healthy playlist"); continue
          }
          let text = String(decoding: data, as: UTF8.self)
          XCTAssertTrue(text.contains("#EXT-X-PART:"))
          XCTAssertFalse(text.contains("#EXT-X-RENDITION-REPORT:"),
            "Do not direct an adaptive switch to a quarantined rendition")
        } catch {
          XCTFail("Healthy playback was poisoned by another rendition: \(error)")
        }
      }
      let count = await fixture.count
      XCTAssertEqual(count, 1, "A failed rendition must not enter a retry loop or keep refreshing reports")
      XCTAssertEqual(diagnostics.values.count, 1)
      XCTAssertEqual(diagnostics.values.first?.attributes["scope"], "rendition")
      XCTAssertEqual(diagnostics.values.first?.attributes["detail"], failure.code)
      XCTAssertEqual(diagnostics.values.first?.counters["rendition"], 1)
      XCTAssertEqual(diagnostics.values.first?.counters["active_rendition"], 0)
      if case .httpStatus = failure {
        XCTAssertEqual(diagnostics.values.first?.counters["http_status"], 503)
      }
      await origin.stop()
    }
  }

  func testActiveRenditionStillEscalatesOnceAndMissingPreloadDoesNotStealOwnership() async throws {
    let fixture = FailingRenditionFixture(failure: .timestampInterval(24_390))
    let diagnostics = NativeFailureCapture()
    let failed = expectation(description: "Active failure reaches bounded native recovery once")
    failed.assertForOverFulfill = true
    let origin = try await makeFailingOrigin(fixture: fixture, diagnostics: diagnostics) { reason in
      XCTAssertEqual(reason, .transition)
      failed.fulfill()
    }
    let media = await origin.media("/part/1/11/0.ts")
    XCTAssertEqual(media, Data([1, 2, 3]))
    let missing = await origin.media("/part/0/11/99.ts")
    XCTAssertNil(missing)
    do {
      _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8")!)
      XCTFail("The active rendition's invalid media must not be ignored")
    } catch { XCTAssertEqual(NativeHLSError.classify(error), .transition) }
    await fulfillment(of: [failed], timeout: 1)
    for _ in 0..<3 {
      do {
        _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8")!)
        XCTFail("The old engine must stop once active recovery owns replacement")
      } catch { XCTAssertEqual(NativeHLSError.classify(error), .transition) }
    }
    XCTAssertEqual(diagnostics.values.count, 1)
    XCTAssertEqual(diagnostics.values.first?.attributes["scope"], "engine")
    XCTAssertEqual(diagnostics.values.first?.counters["active_rendition"], 1)
    await origin.stop()
  }

  func testFailureDiagnosticsExcludeUnderlyingSensitiveErrorData() {
    let error = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [
      NSURLErrorFailingURLErrorKey: URL(string: "https://example.test/live?token=secret")!,
      NSLocalizedDescriptionKey: "private server response",
    ])
    let value = NativeHLSFailureDiagnostic(error: error, operation: "media", rendition: 1, active: 0, fatal: false)
    XCTAssertEqual(value.attributes["error_domain"], NSURLErrorDomain)
    XCTAssertEqual(value.attributes["error_code"], "-1001")
    XCTAssertFalse(value.attributes.values.joined().contains("secret"))
    XCTAssertFalse(value.attributes.values.joined().contains("private"))
    XCTAssertTrue(value.metrics.isEmpty)
  }

  private func makeFailingOrigin(fixture: FailingRenditionFixture, diagnostics: NativeFailureCapture,
                                failure: @escaping @Sendable (NativeHLSError) -> Void) async throws -> NativeHLSOrigin {
    let root = URL(string: "https://example.test/current.m3u8")!
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 30,
      loadData: { try await fixture.load($0) }, diagnostic: { diagnostics.append($0) }, failure: failure)
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4,
      independent: true, media: Data([1, 2, 3]))
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root,
        date: Date(timeIntervalSince1970: Double(1000 + number * 2)), discontinuity: 0, tags: [],
        parts: Array(repeating: part, count: 5), complete: true)
    }
    _ = try await origin.renderForTesting(segments, otherRenditions: [
      1: .init(url: URL(string: "https://example.test/failed.m3u8")!, segments: segments,
        reportedCompleteSequence: 11)
    ], readyToServe: true)
    return origin
  }

  func testPlaylistProbesDoNotExtendAnUnusedMediaDownloadLifetime() async throws {
    let root = URL(string: "https://example.test/current.m3u8")!
    let old = Date(timeIntervalSince1970: 1000)
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 30,
      loadData: { _ in XCTFail("Seeded playlists must not fetch upstream"); throw URLError(.badURL) }) { _ in
      XCTFail("A metadata-only request must not fail playback")
    }

    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root,
        date: old.addingTimeInterval(Double(number * 2)), discontinuity: 0, tags: [],
        parts: Array(repeating: part, count: 5), complete: true)
    }
    _ = try await origin.renderForTesting(segments, otherRenditions: [
      1: .init(url: root, segments: segments, task: Task {}, lastMediaRequest: old, reachedLiveEdge: true)
    ], readyToServe: true)
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8")!)
    let probed = await origin.timelineDiagnostics()
    XCTAssertEqual(probed.first(where: { $0["rendition"] == "1" })?["last_media_request"], "1000.0")
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/part/1/11/0.mp4")!)
    let consumed = await origin.timelineDiagnostics()
    let mediaTime = try XCTUnwrap(consumed.first(where: { $0["rendition"] == "1" })?["last_media_request"])
    XCTAssertGreaterThan(try XCTUnwrap(Double(mediaTime)), old.timeIntervalSince1970)
    await origin.stop()
  }

  func testMasterPreparationCoalescesAndDiscoversOneTargetForAllRenditions() async throws {
    let fixture = MasterTargetFixture()
    let origin = NativeHLSOrigin(root: URL(string: "https://example.test/master.m3u8")!,
      headers: [:], history: 30, loadData: { try await fixture.load($0) }) { _ in
      XCTFail("Valid mixed target durations must be normalized before playback")
    }
    let requests = (0..<5).map { _ in
      Task { try await origin.response(URL(string: "strozz-native-ll://fixture/root.m3u8")!) }
    }
    for request in requests {
      guard case .playlist(let data) = try await request.value else { return XCTFail("Expected master") }
      XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("media/1.m3u8"))
    }
    let target = await origin.advertisedTargetDuration
    XCTAssertEqual(target, 6)
    let counts = await fixture.requests
    XCTAssertEqual(counts, ["master.m3u8": 1, "high.m3u8": 1, "low.m3u8": 1])
    await origin.stop()
  }

  func testAllRenditionsAdvertiseCommonTargetWithoutChangingPartHoldBack() async throws {
    let url = URL(string: "https://example.test/segment.ts")!
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: url,
        date: Date(timeIntervalSince1970: Double(1000 + number * 2)), discontinuity: 0, tags: [],
        parts: Array(repeating: part, count: 5), complete: true)
    }
    let origin = NativeHLSOrigin(root: url, headers: [:], history: 30) { _ in }
    let text = try await origin.renderForTesting(segments, target: 2,
      otherRenditions: [1: .init(url: url, target: 6)])
    XCTAssertTrue(text.contains("#EXT-X-TARGETDURATION:6"))
    XCTAssertTrue(text.contains("PART-HOLD-BACK=1.5"))
    XCTAssertTrue(text.contains("#EXT-X-PART-INF:PART-TARGET=0.45"))
    await origin.stop()
  }

  func testColdIndexerRetainsTheTimelineSeenBeforeSelection() async throws {
    let root = URL(string: "https://example.test/current.m3u8")!
    let map = URL(string: "https://example.test/init.mp4")!
    let earlier = (0..<20).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root,
        date: Date(timeIntervalSince1970: Double(1000 + number * 2)),
        initialization: map, discontinuity: 0, tags: [], complete: true, declaredDuration: 2)
    }
    let manifest = """
      #EXTM3U
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:20
      #EXT-X-MAP:URI="init.mp4"
      #EXT-X-PROGRAM-DATE-TIME:1970-01-01T00:17:20.000Z
      """ + "\n" + (20..<31).map { "#EXTINF:2,\n\($0).mp4" }.joined(separator: "\n")
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 1800, loadData: { request in
      let url = try XCTUnwrap(request.url)
      if url == map {
        // Keep startup before media transfer so this test performs no networking.
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
      }
      return (Data(manifest.utf8),
        try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }) { _ in XCTFail("Cancelling a cold indexer must not fail playback") }
    _ = try await origin.renderForTesting(earlier, otherRenditions: [
      1: .init(url: URL(string: "https://example.test/unused.m3u8")!, reportedSegments: earlier)
    ], readyToServe: true)
    let request = Task {
      try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8")!)
    }
    var firstSequence: String?
    for _ in 0..<100 {
      let timeline = await origin.timelineDiagnostics()
      firstSequence = timeline.first(where: { $0["rendition"] == "1" })?["sequence"]
      if firstSequence != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertEqual(firstSequence, "0", "Selecting a new rendition must not move its timeline origin to 20")
    request.cancel()
    await origin.stop()
    do { _ = try await request.value }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testColdRenditionMetadataPreservesEarlierTimelineWithoutRetainingMedia() {
    let url = URL(string: "https://example.test/live.m3u8")!
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 2,
      independent: true, media: Data(repeating: 0, count: 188))
    let earlier = (0..<30).map { sequence in
      NativeHLSOrigin.Segment(sequence: sequence, url: url,
        date: Date(timeIntervalSince1970: Double(sequence * 2)), discontinuity: 0, tags: [],
        parts: [part], complete: true)
    }
    let later = (20..<60).map { sequence in
      NativeHLSOrigin.Segment(sequence: sequence, url: url,
        date: Date(timeIntervalSince1970: Double(sequence * 2)), discontinuity: 0, tags: [],
        complete: true, declaredDuration: 2)
    }
    let metadata = NativeHLSOrigin.retainedMetadata(earlier + later, history: 1800)
    XCTAssertEqual(metadata.map(\.sequence), Array(0..<60))
    XCTAssertEqual(metadata.first?.date, earlier.first?.date)
    XCTAssertTrue(metadata.allSatisfy { $0.parts.isEmpty && $0.duration == 2 })
    let bounded = NativeHLSOrigin.retainedMetadata(metadata, history: 12)
    XCTAssertEqual(bounded.map(\.sequence), Array(54..<60))
    let interrupted = NativeHLSOrigin.retainedMetadata(Array(metadata.prefix(20)) + Array(metadata.suffix(10)),
      history: 1800)
    XCTAssertEqual(interrupted.map(\.sequence), Array(50..<60),
      "A missing metadata window must not renumber later media as if no segments were missed")
  }

  func testRestartedRenditionDoesNotServeItsOldEdgeAsCurrentLive() async throws {
    let fixture = RenditionReportFixture()
    let root = URL(string: "https://example.test/current.m3u8")!
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 30,
      loadData: { try await fixture.load($0) }) { _ in XCTFail("Stopping must not fail playback") }
    defer { Task { await fixture.release(); await origin.stop() } }
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root,
        date: Date(timeIntervalSince1970: Double(1000 + number * 2)), discontinuity: 0, tags: [],
        parts: Array(repeating: part, count: 5), complete: true)
    }
    _ = try await origin.renderForTesting(segments, otherRenditions: [
      1: .init(url: URL(string: "https://example.test/unused.m3u8")!, segments: segments,
        reachedLiveEdge: true)
    ], readyToServe: true)
    let stale = expectation(description: "A dormant rendition's old edge is not current live")
    stale.isInverted = true
    let request = Task {
      _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8")!)
      stale.fulfill()
    }
    await fulfillment(of: [stale], timeout: 0.2)
    request.cancel()
    do { try await request.value }
    catch { XCTAssertTrue(error is CancellationError) }
    await origin.stop()
  }

  func testColdRenditionServesRequestedCachedPartsBeforeReachingLiveEdge() async throws {
    let origin = try await makeColdOrigin()
    let available = expectation(description: "A quality switch must not wait for unrelated future media")
    let request = Task {
      let response = try await origin.response(
        URL(string: "strozz-native-ll://fixture/media/1.m3u8?_HLS_msn=11&_HLS_part=0")!)
      available.fulfill()
      return response
    }
    await fulfillment(of: [available], timeout: 0.3)
    request.cancel()
    do {
      guard case .playlist(let data) = try await request.value else { return XCTFail("Expected cached playlist") }
      XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("#EXT-X-PART:"))
    } catch {
      XCTAssertTrue(error is CancellationError, "Only cleanup cancellation is expected after a failed deadline")
    }
    await origin.stop()
  }

  func testColdRenditionStillWaitsForInitialLiveEdgeAndUnpublishedParts() async throws {
    for suffix in ["", "?_HLS_msn=11&_HLS_part=4"] {
      let origin = try await makeColdOrigin()
      let unavailable = expectation(description: "Startup and an unreleased part must still wait")
      unavailable.isInverted = true
      let request = Task {
        _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/1.m3u8\(suffix)")!)
        unavailable.fulfill()
      }
      await fulfillment(of: [unavailable], timeout: 0.2)
      request.cancel()
      do {
        try await request.value
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      await origin.stop()
    }
  }

  private func makeColdOrigin() async throws -> NativeHLSOrigin {
    let root = URL(string: "https://example.test/current.m3u8")!
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 30,
      loadData: { _ in XCTFail("Seeded cache must not need networking"); throw URLError(.badURL) }) { _ in
      XCTFail("Cancelling a cached request must not fail the engine")
    }
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root,
        date: Date(timeIntervalSince1970: Double(1000 + number * 2)), discontinuity: 0, tags: [],
        parts: Array(repeating: part, count: 5), complete: true)
    }
    _ = try await origin.renderForTesting(segments, otherRenditions: [
      1: .init(url: root, segments: segments, task: Task {}, reachedLiveEdge: false)
    ], readyToServe: true)
    return origin
  }

  func testSlowUnusedRenditionCannotHoldAnAlreadyAvailablePlaylist() async throws {
    let fixture = RenditionReportFixture()
    let origin = try await makeOrigin(fixture: fixture)
    let available = expectation(description: "Cached active playlist is returned before unused metadata finishes")
    available.expectedFulfillmentCount = 5
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    let requests = (0..<5).map { _ in
      Task {
        let response = try await origin.response(url)
        available.fulfill()
        return response
      }
    }
    defer {
      requests.forEach { $0.cancel() }
      Task { await fixture.release(); await origin.stop() }
    }
    for _ in 0..<100 {
      if await fixture.unusedStarted { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let unusedStarted = await fixture.unusedStarted
    XCTAssertTrue(unusedStarted)
    await fulfillment(of: [available], timeout: 0.3)
    let counts = await fixture.requestCounts
    XCTAssertEqual(counts["unused.m3u8"], 1, "Concurrent reloads must coalesce optional report work")
    XCTAssertNil(counts["current.m3u8"], "The running indexer already has the active rendition's metadata")
    await fixture.release()
    for request in requests {
      guard case .playlist(let data) = try await request.value else { return XCTFail("Expected a playlist") }
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertTrue(text.contains("#EXT-X-PART:"))
      XCTAssertFalse(text.contains("#EXT-X-RENDITION-REPORT:"), "Do not invent metadata before it arrives")
    }
    var verifiedReport = false
    for _ in 0..<100 {
      if case .playlist(let data) = try await origin.response(url),
        String(decoding: data, as: UTF8.self).contains(
          "#EXT-X-RENDITION-REPORT:URI=\"1.m3u8\",LAST-MSN=90,LAST-PART=0") {
        verifiedReport = true
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTAssertTrue(verifiedReport, "Completed metadata must still be published for quality switching")
    await origin.stop()
  }

  func testFailedUnusedMetadataDoesNotFailPlaybackOrAdvertiseStaleSequence() async throws {
    let fixture = RenditionReportFixture(shouldFail: true)
    let origin = try await makeOrigin(fixture: fixture, previousSequence: 88)
    defer { Task { await fixture.release(); await origin.stop() } }
    let url = URL(string: "strozz-native-ll://fixture/media/0.m3u8")!
    _ = try await origin.response(url)
    await fixture.release()
    for _ in 0..<100 {
      if await origin.snapshot().reportRefreshSeconds != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let duration = await origin.snapshot().reportRefreshSeconds
    XCTAssertNotNil(duration)
    guard case .playlist(let data) = try await origin.response(url) else { return XCTFail("Expected active playlist") }
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(text.contains("#EXT-X-PART:"))
    XCTAssertFalse(text.contains("#EXT-X-RENDITION-REPORT:"), "Failed metadata must not keep advertising an old edge")
    await origin.stop()
  }

  func testStopCancelsPendingMetadataAndDrainsBeforeInvalidatingSession() async throws {
    let fixture = RenditionReportFixture()
    let origin = try await makeOrigin(fixture: fixture)
    defer { Task { await fixture.release(); await origin.stop() } }
    _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8")!)
    for _ in 0..<100 {
      if await fixture.unusedStarted { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let started = await fixture.unusedStarted
    XCTAssertTrue(started)
    let stopped = expectation(description: "Stopping cancels outstanding optional metadata")
    let stopping = Task { await origin.stop(); stopped.fulfill() }
    await fulfillment(of: [stopped], timeout: 0.3)
    await fixture.release()
    await stopping.value
    do {
      _ = try await origin.response(URL(string: "strozz-native-ll://fixture/media/0.m3u8")!)
      XCTFail("A stopped origin must not start new work")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  private func makeOrigin(fixture: RenditionReportFixture, previousSequence: Int? = nil) async throws -> NativeHLSOrigin {
    let root = URL(string: "https://example.test/current.m3u8")!
    let origin = NativeHLSOrigin(root: root, headers: [:], history: 30,
      loadData: { try await fixture.load($0) }) { _ in XCTFail("Optional metadata must not fail playback") }
    let part = NativeHLSOrigin.Part(offset: 0, length: 188, duration: 0.4, independent: true)
    let date = Date(timeIntervalSince1970: 1000)
    let segments = (0..<12).map { number in
      NativeHLSOrigin.Segment(sequence: number, url: root, date: date.addingTimeInterval(Double(number * 2)),
        discontinuity: 0, tags: [], parts: Array(repeating: part, count: 5), complete: true)
    }
    _ = try await origin.renderForTesting(segments, otherRenditions: [
      1: .init(url: URL(string: "https://example.test/unused.m3u8")!, reportedCompleteSequence: previousSequence)
    ], readyToServe: true)
    return origin
  }
}

private actor FailingRenditionFixture {
  private(set) var count = 0
  let failure: NativeHLSFailureDetail

  init(failure: NativeHLSFailureDetail) { self.failure = failure }

  func load(_ request: URLRequest) throws -> (Data, URLResponse) {
    count += 1
    guard case .httpStatus(let status) = failure else { throw failure }
    let url = try XCTUnwrap(request.url)
    return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
      httpVersion: nil, headerFields: nil)))
  }
}

private final class NativeFailureCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [NativeHLSFailureDiagnostic] = []
  var values: [NativeHLSFailureDiagnostic] { lock.withLock { storage } }
  func append(_ value: NativeHLSFailureDiagnostic) { lock.withLock { storage.append(value) } }
}

private actor MasterTargetFixture {
  private(set) var requests: [String: Int] = [:]

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    requests[url.lastPathComponent, default: 0] += 1
    try await Task.sleep(for: .milliseconds(20))
    let text: String
    if url.lastPathComponent == "master.m3u8" {
      text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2"
        high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4D401F,mp4a.40.2"
        low.m3u8
        """
    } else {
      text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:\(url.lastPathComponent == "low.m3u8" ? 6 : 2)
        #EXT-X-MEDIA-SEQUENCE:1
        #EXT-X-PROGRAM-DATE-TIME:2026-10-08T19:00:00.000Z
        #EXTINF:2.0,
        1.ts
        """
    }
    return (Data(text.utf8),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}

private actor RenditionReportFixture {
  private(set) var unusedStarted = false
  private(set) var requestCounts: [String: Int] = [:]
  private var released = false
  private let shouldFail: Bool

  init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

  func release() { released = true }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let url = try XCTUnwrap(request.url)
    requestCounts[url.lastPathComponent, default: 0] += 1
    if url.lastPathComponent == "unused.m3u8" {
      unusedStarted = true
      while !released { try await Task.sleep(for: .milliseconds(10)) }
      if shouldFail { throw URLError(.timedOut) }
    }
    let manifest = """
      #EXTM3U
      #EXT-X-TARGETDURATION:2
      #EXT-X-MEDIA-SEQUENCE:90
      #EXT-X-PROGRAM-DATE-TIME:2026-10-07T16:00:00.000Z
      #EXTINF:2.0,
      90.ts
      """
    return (Data(manifest.utf8),
      try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
