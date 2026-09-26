import XCTest

@testable import Strozz

@MainActor
final class StreamListRefreshTests: XCTestCase {
  private let category = TwitchCategory(id: "game", name: "Game", boxArtURL: nil, viewerCount: nil)

  func testCategoryRefreshKeepsCardsAndRejectsOlderSameCategoryResponse() async {
    let started = (0..<3).map { expectation(description: "Request \($0)") }
    let loader = ListResponseLoader(started: started)
    let service = BrowseService(loadData: { try await loader.load($0) })
    let initial = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[0]], timeout: 2)
    loader.succeed(0, json: categoryJSON(id: "stream-1", title: "Original"))
    await initial.value
    let original = service.categoryStreams

    let older = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[1]], timeout: 2)
    XCTAssertEqual(service.categoryStreams, original)
    let newest = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[2]], timeout: 2)
    loader.succeed(1, json: categoryJSON(id: "stale", title: "Stale"))
    await older.value
    XCTAssertEqual(service.categoryStreams, original)
    XCTAssertTrue(service.isLoadingStreams)

    loader.succeed(2, json: categoryJSON(id: "stream-2", title: "Fresh"))
    await newest.value
    XCTAssertEqual(service.categoryStreams.first?.title, "Fresh")
    XCTAssertEqual(service.categoryStreams.first?.channelKey, original.first?.channelKey)
    XCTAssertFalse(service.isLoadingStreams)
    XCTAssertNil(service.streamsErrorMessage)
  }

  func testChangingCategoryClearsPreviousCategoryAndCanReturnEmpty() async {
    let started = (0..<2).map { expectation(description: "Request \($0)") }
    let loader = ListResponseLoader(started: started)
    let service = BrowseService(loadData: { try await loader.load($0) })
    let initial = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[0]], timeout: 2)
    loader.succeed(0, json: categoryJSON(id: "stream-1", title: "Original"))
    await initial.value
    XCTAssertEqual(service.categoryStreams.count, 1)

    let other = TwitchCategory(id: "other", name: "Other", boxArtURL: nil, viewerCount: nil)
    let refresh = Task { await service.loadStreams(for: other) }
    await fulfillment(of: [started[1]], timeout: 2)
    XCTAssertTrue(service.categoryStreams.isEmpty)
    loader.succeed(1, json: #"{"data":{"game":{"streams":{"edges":[]}}}}"#)
    await refresh.value
    XCTAssertTrue(service.categoryStreams.isEmpty)
    XCTAssertFalse(service.isLoadingStreams)
    XCTAssertNil(service.streamsErrorMessage)
  }

  func testFailedCategoryRefreshKeepsExistingCardsAndReportsError() async {
    let started = (0..<2).map { expectation(description: "Request \($0)") }
    let loader = ListResponseLoader(started: started)
    let service = BrowseService(loadData: { try await loader.load($0) })
    let initial = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[0]], timeout: 2)
    loader.succeed(0, json: categoryJSON(id: "stream-1", title: "Original"))
    await initial.value
    let original = service.categoryStreams

    let refresh = Task { await service.loadStreams(for: category) }
    await fulfillment(of: [started[1]], timeout: 2)
    loader.fail(1)
    await refresh.value
    XCTAssertEqual(service.categoryStreams, original)
    XCTAssertNotNil(service.streamsErrorMessage)
    XCTAssertFalse(service.isLoadingStreams)
  }

  func testSearchReturnRefreshKeepsResultsDuringRequestAndFailure() async {
    let started = (0..<2).map { expectation(description: "Request \($0)") }
    let loader = ListResponseLoader(started: started)
    let service = SearchService(loadData: { try await loader.load($0) })
    let initial = Task { await service.search("example") }
    await fulfillment(of: [started[0]], timeout: 2)
    loader.succeed(0, json: searchJSON(title: "Original"))
    await initial.value
    let original = service.channelResults
    XCTAssertEqual(original.count, 1)

    let refresh = Task { await service.search("example", preservingResultsOnFailure: true) }
    await fulfillment(of: [started[1]], timeout: 2)
    XCTAssertEqual(service.channelResults, original)
    XCTAssertTrue(service.isSearching)
    loader.fail(1)
    await refresh.value
    XCTAssertEqual(service.channelResults, original)
    XCTAssertNotNil(service.errorMessage)
    XCTAssertFalse(service.isSearching)
  }

  func testClearingAndRepeatingSearchRejectsOlderSameQueryResponse() async {
    let started = (0..<2).map { expectation(description: "Request \($0)") }
    let loader = ListResponseLoader(started: started)
    let service = SearchService(loadData: { try await loader.load($0) })
    let old = Task { await service.search("example") }
    await fulfillment(of: [started[0]], timeout: 2)
    service.clear()
    let newest = Task { await service.search("example") }
    await fulfillment(of: [started[1]], timeout: 2)
    loader.succeed(0, json: searchJSON(title: "Stale"))
    await old.value
    XCTAssertTrue(service.channelResults.isEmpty)
    XCTAssertTrue(service.isSearching)

    loader.succeed(1, json: searchJSON(title: "Fresh"))
    await newest.value
    XCTAssertEqual(service.channelResults.first?.title, "Fresh")
    XCTAssertFalse(service.isSearching)
    XCTAssertNil(service.errorMessage)
  }

  func testCancelledSearchCannotPublishLateSuccess() async {
    let started = [expectation(description: "Request")]
    let loader = ListResponseLoader(started: started)
    let service = SearchService(loadData: { try await loader.load($0) })
    let request = Task { await service.search("example") }
    await fulfillment(of: started, timeout: 2)
    request.cancel()
    loader.succeed(0, json: searchJSON(title: "Cancelled"))
    await request.value
    XCTAssertTrue(service.channelResults.isEmpty)
    XCTAssertFalse(service.isSearching)
    XCTAssertNil(service.errorMessage)
  }

  func testCancelledCategoryRefreshCannotPublishLateSuccess() async {
    let started = [expectation(description: "Request")]
    let loader = ListResponseLoader(started: started)
    let service = BrowseService(loadData: { try await loader.load($0) })
    let request = Task { await service.loadStreams(for: category) }
    await fulfillment(of: started, timeout: 2)
    request.cancel()
    loader.succeed(0, json: categoryJSON(id: "cancelled", title: "Cancelled"))
    await request.value
    XCTAssertTrue(service.categoryStreams.isEmpty)
    XCTAssertFalse(service.isLoadingStreams)
    XCTAssertNil(service.streamsErrorMessage)
  }

  private func categoryJSON(id: String, title: String) -> String {
    """
    {"data":{"game":{"streams":{"edges":[{"node":{"id":"\(id)","title":"\(title)",
    "viewersCount":100,"broadcaster":{"login":"example","displayName":"Example"}}}]}}}}
    """
  }

  private func searchJSON(title: String) -> String {
    """
    {"data":{"searchFor":{"channels":{"edges":[{"item":{"id":"user","login":"example",
    "displayName":"Example","stream":{"id":"stream","title":"\(title)","viewersCount":100}}}]},
    "games":{"edges":[]}}}}
    """
  }
}

@MainActor
private final class ListResponseLoader {
  private let started: [XCTestExpectation]
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]

  init(started: [XCTestExpectation]) {
    self.started = started
  }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    let id = nextID
    nextID += 1
    return try await withCheckedThrowingContinuation {
      pending[id] = $0
      started[id].fulfill()
    }
  }

  func succeed(_ id: Int, json: String) {
    let response = HTTPURLResponse(
      url: URL(string: "https://example.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    pending.removeValue(forKey: id)?.resume(returning: (Data(json.utf8), response))
  }

  func fail(_ id: Int) {
    pending.removeValue(forKey: id)?.resume(throwing: URLError(.notConnectedToInternet))
  }
}
