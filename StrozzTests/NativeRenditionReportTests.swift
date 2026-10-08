import XCTest
#if os(tvOS)
@testable import Strozz
#else
@testable import StrozzMobile
#endif

final class NativeRenditionReportTests: XCTestCase {
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
