import Foundation
import XCTest
@testable import Strozz

@MainActor
final class VODChatReplayTests: XCTestCase {
  private func page(_ comments: [(Double, String)], hasMore: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "data": ["video": ["comments": [
        "edges": comments.map { offset, text in
          ["node": [
            "contentOffsetSeconds": offset,
            "commenter": ["login": "viewer", "displayName": "Viewer"],
            "message": ["fragments": [["text": text]]]
          ]]
        },
        "pageInfo": ["hasNextPage": hasMore]
      ]]]
    ])
  }

  private func finishFetch(_ replay: VODChatReplayService) async throws {
    for _ in 0..<200 {
      if !replay.diagnostics.fetching { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Replay fetch did not finish")
  }

  func testGrowingRecordingPollsCurrentLastPageAndDeduplicatesExistingComments() async throws {
    var now = Date(timeIntervalSince1970: 100)
    let loader = ReplayLoader(pages: [
      try page([(10, "first")]), try page([(10, "first"), (12, "newly archived")])
    ])
    let replay = VODChatReplayService(loadData: { try await loader.load($0) }, now: { now })
    defer { replay.stop() }
    replay.start(vodID: "recording", channelLogin: nil, isGrowing: true)
    try await finishFetch(replay)
    replay.update(toOffset: 12)
    XCTAssertEqual(replay.messages.map(\.text), ["first"])
    now = now.addingTimeInterval(4)
    replay.update(toOffset: 13)
    XCTAssertFalse(replay.diagnostics.fetching)
    now = now.addingTimeInterval(1)
    replay.update(toOffset: 13)
    try await finishFetch(replay)
    XCTAssertEqual(replay.messages.map(\.text), ["first", "newly archived"])
    let offsets = await loader.offsets
    XCTAssertEqual(offsets, [0, 10])
  }

  func testCompletedRecordingDoesNotPollItsFinalPage() async throws {
    var now = Date(timeIntervalSince1970: 100)
    let loader = ReplayLoader(pages: [try page([(10, "last comment")])])
    let replay = VODChatReplayService(loadData: { try await loader.load($0) }, now: { now })
    defer { replay.stop() }
    replay.start(vodID: "completed", channelLogin: nil)
    try await finishFetch(replay)
    now = now.addingTimeInterval(30)
    replay.update(toOffset: 20)
    XCTAssertEqual(replay.messages.map(\.text), ["last comment"])
    XCTAssertFalse(replay.diagnostics.fetching)
    let offsets = await loader.offsets
    XCTAssertEqual(offsets, [0])
  }

  func testMissingFirstCommentsDoNotCauseRepeatedBackwardWindowResets() async throws {
    let loader = ReplayLoader(pages: [try page([(10, "later")])])
    let replay = VODChatReplayService(loadData: { try await loader.load($0) })
    defer { replay.stop() }
    replay.start(vodID: "quiet-start", channelLogin: nil)
    try await finishFetch(replay)
    for offset in 0..<10 { replay.update(toOffset: Double(offset)) }
    XCTAssertFalse(replay.diagnostics.fetching)
    XCTAssertTrue(replay.messages.isEmpty)
    let offsets = await loader.offsets
    XCTAssertEqual(offsets, [0])
  }

  func testNetworkFailureIsVisibleAndRetriesWithoutReportingReadyOrHammering() async throws {
    var now = Date(timeIntervalSince1970: 100)
    let loader = ReplayLoader(pages: [try page([(0, "recovered")])], failures: 1)
    let replay = VODChatReplayService(loadData: { try await loader.load($0) }, now: { now })
    defer { replay.stop() }
    replay.start(vodID: "network", channelLogin: nil, isGrowing: true)
    try await finishFetch(replay)
    XCTAssertFalse(replay.isReady)
    XCTAssertNotNil(replay.errorMessage)
    for _ in 0..<10 { replay.update(toOffset: 1) }
    XCTAssertFalse(replay.diagnostics.fetching)
    now = now.addingTimeInterval(5)
    replay.update(toOffset: 1)
    try await finishFetch(replay)
    XCTAssertTrue(replay.isReady)
    XCTAssertNil(replay.errorMessage)
    XCTAssertEqual(replay.messages.map(\.text), ["recovered"])
    let offsets = await loader.offsets
    XCTAssertEqual(offsets, [0, 0])
  }

  func testMalformedResponseIsNotAnEmptySuccessfulReplay() async throws {
    let loader = ReplayLoader(pages: [Data(#"{"data":{"video":null}}"#.utf8)])
    let replay = VODChatReplayService(loadData: { try await loader.load($0) })
    defer { replay.stop() }
    replay.start(vodID: "bad-response", channelLogin: nil)
    try await finishFetch(replay)
    XCTAssertFalse(replay.isReady)
    XCTAssertNotNil(replay.errorMessage)
  }
}

private actor ReplayLoader {
  let pages: [Data]
  var failures: Int
  private(set) var offsets: [Int] = []
  private var index = 0

  init(pages: [Data], failures: Int = 0) {
    self.pages = pages
    self.failures = failures
  }

  func load(_ request: URLRequest) throws -> (Data, URLResponse) {
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    let variables = body?["variables"] as? [String: Any]
    offsets.append(variables?["o"] as? Int ?? -1)
    if failures > 0 {
      failures -= 1
      throw URLError(.timedOut)
    }
    guard index < pages.count else { throw URLError(.badServerResponse) }
    defer { index += 1 }
    return (pages[index], HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
