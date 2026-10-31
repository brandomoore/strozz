import XCTest

#if os(tvOS)
  @testable import Strozz
#else
  @testable import StrozzMobile
#endif

@MainActor
final class KickBrowseTests: XCTestCase {
  func testDirectoryDecodingPreservesPlatformAndHiddenViewerCounts() throws {
    let page = try KickBrowseService.decode(directory())
    XCTAssertEqual(page.channels.map(\.channelKey), ["kick:one", "kick:two"])
    XCTAssertTrue(page.channels.allSatisfy { $0.platform == .kick && $0.isLive })
    XCTAssertEqual(page.channels[0].viewerCount, 100)
    XCTAssertNil(page.channels[1].viewerCount)
    XCTAssertTrue(page.channels[1].isMature)
    XCTAssertEqual(page.channels[0].thumbnailURL?.absoluteString, "https://images.kick.com/one.webp")
    XCTAssertEqual(page.categories.map(\.id), ["kick:15"])
    XCTAssertNil(page.categories[0].viewerCount, "A sampled directory cannot supply total category viewers")
    XCTAssertEqual(page.nextCursor, "next-page")
  }

  func testMissingDirectoryIsAnErrorRatherThanAnEmptySuccess() {
    XCTAssertThrowsError(try KickBrowseService.decode(Data(#"{"data":{}}"#.utf8)))
    XCTAssertThrowsError(try KickBrowseService.decode(Data(#"{"data":{"livestreams":[{}]}}"#.utf8)))
  }

  func testRequestPreservesCategoryLanguageAndOpaqueCursor() async throws {
    let body = directory()
    let page = try await KickBrowseService.page(categoryID: "15", after: "opaque+/=", language: "EN") { request in
      XCTAssertEqual(request.url?.host, "web.kick.com")
      XCTAssertEqual(request.url?.path, "/api/v1/livestreams")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
      XCTAssertEqual(values["sort"], "viewer_count_desc")
      XCTAssertEqual(values["category_id"], "15")
      XCTAssertEqual(values["language"], "en")
      XCTAssertEqual(values["after"], "opaque+/=")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    XCTAssertEqual(page.channels.count, 2)
  }

  func testRestrictedDirectorySurfacesFailure() async {
    do {
      _ = try await KickBrowseService.page { request in
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
      }
      XCTFail("Restricted access must not look like an empty directory")
    } catch { XCTAssertEqual(error as? KickPlaybackService.Failure, .restricted) }
  }

  func testAllMixesStreamsWhileSinglePlatformOnlyCallsItsOwnAPI() async {
    let kick = directory()
    let twitch = twitchDirectory()
    let recorder = BrowseRequestRecorder()
    let service = BrowseService { request in
      await recorder.record(request)
      return Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await service.loadStreams(filter: .all)
    XCTAssertEqual(service.categoryStreams.map(\.platform), [.twitch, .kick, .kick])
    XCTAssertNil(service.streamsErrorMessage)
    await recorder.clear()
    await service.loadStreams(filter: .kick)
    XCTAssertTrue(service.categoryStreams.allSatisfy { $0.platform == .kick })
    let kickHosts = await recorder.hosts
    XCTAssertEqual(kickHosts, ["web.kick.com"])
    await recorder.clear()
    await service.loadStreams(filter: .twitch)
    XCTAssertEqual(service.categoryStreams.map(\.platform), [.twitch])
    let twitchHosts = await recorder.hosts
    XCTAssertEqual(twitchHosts, ["gql.twitch.tv"])
    XCTAssertNil(service.nextKickCursor)
  }

  func testOnePlatformFailureDoesNotDiscardTheOther() async {
    let kick = directory()
    let service = BrowseService { request in
      if request.url?.host != "web.kick.com" { throw URLError(.notConnectedToInternet) }
      return Self.response(request, data: kick)
    }
    await service.loadStreams(filter: .all)
    XCTAssertEqual(service.categoryStreams.count, 2)
    XCTAssertTrue(service.streamsErrorMessage?.contains("Twitch") == true)
    XCTAssertEqual(service.nextKickCursor, "next-page")
  }

  func testLoadMoreAppendsWithoutMovingOrDuplicatingExistingChannels() async {
    let first = directory()
    let second = directory(slugs: ["two", "three"], cursor: nil)
    let service = BrowseService { request in
      let isMore = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.contains(where: { $0.name == "after" }) == true
      return Self.response(request, data: isMore ? second : first)
    }
    await service.loadStreams(filter: .kick)
    let original = service.categoryStreams
    await service.loadMoreStreams()
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["kick:one", "kick:two", "kick:three"])
    XCTAssertEqual(Array(service.categoryStreams.prefix(2)), original)
    XCTAssertNil(service.nextKickCursor)
    XCTAssertFalse(service.isLoadingMore)
  }

  func testKickCategoryUsesItsNativeIDAndNotATwitchQuery() async {
    let body = directory()
    let service = BrowseService { request in
      XCTAssertEqual(request.url?.host, "web.kick.com")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(query.first { $0.name == "category_id" }?.value, "15")
      return Self.response(request, data: body)
    }
    let category = TwitchCategory(id: "15", name: "Chatting", boxArtURL: nil, viewerCount: nil, platform: .kick)
    await service.loadStreams(for: category)
    XCTAssertEqual(service.categoryStreams.count, 2)
  }

  func testSameNumericCategoryIDsStayDistinctAcrossPlatforms() async {
    let kick = directory()
    let twitch = Data(#"{"data":{"games":{"edges":[{"node":{"id":"15","name":"Chatting","viewersCount":200}}]}}}"#.utf8)
    let service = BrowseService { request in
      Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await service.loadCategories(filter: .all)
    XCTAssertEqual(service.categories.map(\.id), ["15", "kick:15"])
    XCTAssertEqual(service.categories.map(\.platform), [.twitch, .kick])
  }

  func testSupersededKickResponseCannotOverwriteTwitchFilter() async {
    let started = expectation(description: "Kick requested")
    let pending = PendingBrowseResponse(started: started)
    let twitch = twitchDirectory()
    let service = BrowseService { request in
      if request.url?.host == "web.kick.com" { return try await pending.load(request) }
      return Self.response(request, data: twitch)
    }
    let old = Task { await service.loadStreams(filter: .kick) }
    await fulfillment(of: [started], timeout: 2)
    await service.loadStreams(filter: .twitch)
    pending.finish(data: directory())
    await old.value
    XCTAssertEqual(service.categoryStreams.map(\.platform), [.twitch])
    XCTAssertNil(service.nextKickCursor)
    XCTAssertFalse(service.isLoadingStreams)
  }

  func testMobileSearchFilterSkipsDisabledPlatform() async {
    let kick = KickChannel(slug: "example", displayName: "Example", title: "Live", category: "",
                           viewerCount: 10, isLive: true, chatroomID: nil, imageURL: nil)
    let service = SearchService(loadData: { _ in
      XCTFail("Kick-only search must not query Twitch")
      throw URLError(.unsupportedURL)
    }, loadKick: { _ in kick })
    await service.search("example", filter: .kick)
    XCTAssertEqual(service.channelResults.map(\.platform), [.kick])
    XCTAssertTrue(service.categoryResults.isEmpty)
  }

  func testLateKickPageCannotAppendAfterChangingPlatform() async {
    let started = expectation(description: "Next page requested")
    let pending = PendingBrowseResponse(started: started)
    let first = directory()
    let twitch = twitchDirectory()
    let service = BrowseService { request in
      if request.url?.host != "web.kick.com" { return Self.response(request, data: twitch) }
      if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "after" }) == true {
        return try await pending.load(request)
      }
      return Self.response(request, data: first)
    }
    await service.loadStreams(filter: .kick)
    let more = Task { await service.loadMoreStreams() }
    await fulfillment(of: [started], timeout: 2)
    await service.loadStreams(filter: .twitch)
    pending.finish(data: directory(slugs: ["late"], cursor: nil))
    await more.value
    XCTAssertEqual(service.categoryStreams.map(\.platform), [.twitch])
    XCTAssertFalse(service.isLoadingMore)
    XCTAssertNil(service.nextKickCursor)
  }

  func testFailedNextPagePreservesCardsAndRetryCursor() async {
    let first = directory()
    let service = BrowseService { request in
      if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "after" }) == true { throw URLError(.timedOut) }
      return Self.response(request, data: first)
    }
    await service.loadStreams(filter: .kick)
    let original = service.categoryStreams
    await service.loadMoreStreams()
    XCTAssertEqual(service.categoryStreams, original)
    XCTAssertEqual(service.nextKickCursor, "next-page")
    XCTAssertNotNil(service.moreStreamsErrorMessage)
    XCTAssertFalse(service.isLoadingMore)
  }

  func testCancelledKickRequestCannotPublishLateResults() async {
    let started = expectation(description: "Kick requested")
    let pending = PendingBrowseResponse(started: started)
    let service = BrowseService { try await pending.load($0) }
    let request = Task { await service.loadStreams(filter: .kick) }
    await fulfillment(of: [started], timeout: 2)
    request.cancel()
    pending.finish(data: directory())
    await request.value
    XCTAssertTrue(service.categoryStreams.isEmpty)
    XCTAssertFalse(service.isLoadingStreams)
    XCTAssertNil(service.streamsErrorMessage)
    XCTAssertNil(service.nextKickCursor)
  }

  func testConfirmedCostreamAppearsOnceWithBothPlatformsAndCombinedViewers() async throws {
    let kick = directory(slugs: ["xqc"])
    let twitch = twitchDirectory(logins: ["xqc"])
    let service = BrowseService(creatorLinks: ["xqc": "xqc"]) { request in
      Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await service.loadStreams(filter: .all)
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["xqc"])
    let creator = try XCTUnwrap(service.categoryStreams.first)
    XCTAssertEqual(creator.platform, .twitch)
    XCTAssertEqual(creator.kick?.slug, "xqc")
    XCTAssertEqual(creator.kick?.thumbnailURL?.absoluteString, "https://images.kick.com/xqc.webp")
    XCTAssertEqual(creator.combinedViewerCount, 150)

    await service.loadStreams(filter: .kick)
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["kick:xqc"])
    XCTAssertEqual(service.categoryStreams.first?.combinedViewerCount, 100)
    await service.loadStreams(filter: .twitch)
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["xqc"])
    XCTAssertNil(service.categoryStreams.first?.kick)
    XCTAssertEqual(service.categoryStreams.first?.combinedViewerCount, 50)
  }

  func testConfirmedDifferentHandlesMergeWithoutLosingOtherDirectoryMetadata() async {
    let kick = directory(slugs: ["asmongold", "two"])
    let twitch = twitchDirectory(logins: ["zackrawrr"])
    let service = BrowseService(creatorLinks: ["zackrawrr": "asmongold"]) { request in
      Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await service.loadStreams(filter: .all)
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["zackrawrr", "kick:two"])
    XCTAssertEqual(service.categoryStreams.first?.kick?.slug, "asmongold")
    XCTAssertEqual(service.categoryStreams.last?.isMature, true)
    XCTAssertNil(service.categoryStreams.last?.viewerCount)
    XCTAssertNotNil(service.categoryStreams.last?.thumbnailURL)
  }

  func testUnconfirmedSameNameAndAmbiguousCreatorLinksRemainSeparate() async {
    let kick = directory(slugs: ["same"])
    let twitch = twitchDirectory(logins: ["same", "another"])
    let service = BrowseService(creatorLinks: [:]) { request in
      Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await service.loadStreams(filter: .all)
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["same", "kick:same", "another"])
    let ambiguous = BrowseService(creatorLinks: ["same": "same", "another": "same"]) { request in
      Self.response(request, data: request.url?.host == "web.kick.com" ? kick : twitch)
    }
    await ambiguous.loadStreams(filter: .all)
    XCTAssertEqual(ambiguous.categoryStreams.map(\.channelKey), ["same", "kick:same", "another"])
  }

  func testLaterPageEnrichesExistingCreatorWithoutDuplicatingOrMovingCards() async {
    let first = directory(slugs: ["one"])
    let second = directory(slugs: ["xqc", "three"], cursor: nil)
    let twitch = twitchDirectory(logins: ["xqc", "another"])
    let service = BrowseService(creatorLinks: ["xqc": "xqc"]) { request in
      if request.url?.host != "web.kick.com" { return Self.response(request, data: twitch) }
      let more = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .contains(where: { $0.name == "after" }) == true
      return Self.response(request, data: more ? second : first)
    }
    await service.loadStreams(filter: .all)
    let original = service.categoryStreams
    XCTAssertEqual(original.map(\.channelKey), ["xqc", "kick:one", "another"])
    await service.loadMoreStreams()
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["xqc", "kick:one", "another", "kick:three"])
    XCTAssertEqual(service.categoryStreams.first?.id, original.first?.id)
    XCTAssertEqual(service.categoryStreams.first?.combinedViewerCount, 150)
    XCTAssertEqual(service.categoryStreams.first?.kick?.slug, "xqc")
    XCTAssertEqual(service.categoryStreams[1], original[1])
    XCTAssertEqual(service.categoryStreams[2], original[2])
  }

  func testBrowseSearchMergesConfirmedCreatorAndKeepsSinglePlatformFiltering() async {
    let twitch = Data(#"{"data":{"searchFor":{"channels":{"edges":[{"item":{"id":"creator","login":"xqc","displayName":"xQc","stream":{"id":"live","title":"Live","viewersCount":50}}}]},"games":{"edges":[]}}}}"#.utf8)
    let kick = KickChannel(slug: "xqc", displayName: "xQc", title: "Live", category: "",
                           viewerCount: 100, isLive: true, chatroomID: nil, imageURL: nil)
    let service = SearchService(creatorLinks: ["xqc": "xqc"],
      loadData: { Self.response($0, data: twitch) }, loadKick: { _ in kick })
    await service.search("xqc")
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["xqc"])
    XCTAssertEqual(service.channelResults.first?.combinedViewerCount, 150)
    await service.search("xqc", filter: .twitch)
    XCTAssertNil(service.channelResults.first?.kick)
    XCTAssertEqual(service.channelResults.first?.combinedViewerCount, 50)
    await service.search("xqc", filter: .kick)
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["kick:xqc"])
  }

  private func directory(slugs: [String] = ["one", "two"], cursor: String? = "next-page") -> Data {
    let streams = slugs.map { slug in
      """
      {"title":"Live","channel":{"slug":"\(slug)","username":"\(slug)","profile_pic":null},
      "category":{"id":15,"name":"Chatting"},"thumbnail":{"src":"https://images.kick.com/\(slug).webp"},
      "viewer_count":100,"show_view_count":\(slug != "two"),"is_mature":\(slug == "two")}
      """
    }.joined(separator: ",")
    return Data("""
      {"data":{"livestreams":[\(streams)],"pagination":{"next_cursor":\(cursor.map { "\"\($0)\"" } ?? "null")}}}
      """.utf8)
  }

  private func twitchDirectory(logins: [String] = ["twitch-one"]) -> Data {
    let rows = logins.map { login in
      """
      {"node":{"id":"live-\(login)","title":"Live","viewersCount":50,
      "broadcaster":{"login":"\(login)","displayName":"\(login)"},"game":{"displayName":"Chatting"}}}
      """
    }.joined(separator: ",")
    return Data("""
      {"data":{"streams":{"edges":[\(rows)]}}}
      """.utf8)
  }

  nonisolated private static func response(_ request: URLRequest, data: Data) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

private actor BrowseRequestRecorder {
  private(set) var hosts: [String] = []
  func record(_ request: URLRequest) { hosts.append(request.url?.host ?? "") }
  func clear() { hosts = [] }
}

@MainActor
private final class PendingBrowseResponse {
  let started: XCTestExpectation
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  private var request: URLRequest?

  init(started: XCTestExpectation) { self.started = started }

  func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
    self.request = request
    return try await withCheckedThrowingContinuation {
      continuation = $0
      started.fulfill()
    }
  }

  func finish(data: Data) {
    continuation?.resume(returning: (data,
      HTTPURLResponse(url: request!.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    continuation = nil
  }
}
