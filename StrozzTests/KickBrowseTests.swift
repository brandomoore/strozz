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
    let kick = Data(#"{"current_page":1,"data":[{"id":15,"name":"Chatting","viewers":100,"banner":{"url":"https://files.kick.com/poster.webp"}}],"next_page_url":null}"#.utf8)
    let twitch = Data(#"{"data":{"games":{"edges":[{"node":{"id":"15","name":"Chatting","viewersCount":200}}]}}}"#.utf8)
    let service = BrowseService { request in
      Self.response(request, data: request.url?.host == "kick.com" ? kick : twitch)
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
    }, loadKickSearch: { _ in .init(channels: [kick.followedChannel], categories: []) })
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
      loadData: { Self.response($0, data: twitch) },
      loadKickSearch: { _ in .init(channels: [kick.followedChannel], categories: []) })
    await service.search("xqc")
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["xqc"])
    XCTAssertEqual(service.channelResults.first?.combinedViewerCount, 150)
    await service.search("xqc", filter: .twitch)
    XCTAssertNil(service.channelResults.first?.kick)
    XCTAssertEqual(service.channelResults.first?.combinedViewerCount, 50)
    await service.search("xqc", filter: .kick)
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["kick:xqc"])
  }

  func testRealCategoryCataloguePreservesArtworkTotalsAndSafePagination() throws {
    let data = Data(#"{"current_page":2,"data":[{"id":15,"name":"Chatting","viewers":1234,"banner":{"url":"https://files.kick.com/art.webp"}}],"next_page_url":"https://untrusted.invalid/page"}"#.utf8)
    let page = try KickBrowseService.decodeCategories(data)
    XCTAssertEqual(page.nextPage, 3)
    XCTAssertEqual(page.categories.first?.sourceID, "15")
    XCTAssertEqual(page.categories.first?.viewerCount, 1234)
    XCTAssertEqual(page.categories.first?.boxArtURL?.host, "files.kick.com")
    XCTAssertThrowsError(try KickBrowseService.decodeCategories(Data(#"{"data":[]}"#.utf8)))
  }

  func testCategoryPaginationKeepsExistingCardsAndUsesOwnedEndpoint() async {
    let service = BrowseService { request in
      XCTAssertEqual(request.url?.host, "kick.com")
      let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "page" }?.value ?? ""
      let data = page == "1"
        ? #"{"current_page":1,"data":[{"id":1,"name":"One"}],"next_page_url":"https://untrusted.invalid"}"#
        : #"{"current_page":2,"data":[{"id":1,"name":"One"},{"id":2,"name":"Two"}],"next_page_url":null}"#
      return Self.response(request, data: Data(data.utf8))
    }
    await service.loadCategories(filter: .kick)
    await service.loadMoreCategories()
    XCTAssertEqual(service.categories.map(\.id), ["kick:1", "kick:2"])
    XCTAssertNil(service.nextKickCategoryPage)
    XCTAssertNil(service.moreCategoriesErrorMessage)
  }

  func testLateCategoryPageCannotAppendAfterSwitchingProvider() async {
    let started = expectation(description: "Category next page requested")
    let pending = PendingBrowseResponse(started: started)
    let service = BrowseService { request in
      if request.url?.host == "gql.twitch.tv" {
        return Self.response(request, data: Data(#"{"data":{"games":{"edges":[]}}}"#.utf8))
      }
      let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "page" }?.value
      if page == "2" { return try await pending.load(request) }
      return Self.response(request, data: Data(#"{"current_page":1,"data":[{"id":1,"name":"One"}],"next_page_url":"next"}"#.utf8))
    }
    await service.loadCategories(filter: .kick)
    let more = Task { await service.loadMoreCategories() }
    await fulfillment(of: [started], timeout: 2)
    await service.loadCategories(filter: .twitch)
    pending.finish(data: Data(#"{"current_page":2,"data":[{"id":2,"name":"Late"}],"next_page_url":null}"#.utf8))
    await more.value
    XCTAssertTrue(service.categories.isEmpty)
    XCTAssertNil(service.nextKickCategoryPage)
    XCTAssertFalse(service.isLoadingMoreCategories)
  }

  func testFailedCategoryNextPageRetainsCardsAndCanRetry() async {
    let service = BrowseService { request in
      let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "page" }?.value
      if page == "2" { throw URLError(.timedOut) }
      return Self.response(request, data: Data(#"{"current_page":1,"data":[{"id":1,"name":"One"}],"next_page_url":"next"}"#.utf8))
    }
    await service.loadCategories(filter: .kick)
    await service.loadMoreCategories()
    XCTAssertEqual(service.categories.map(\.id), ["kick:1"])
    XCTAssertEqual(service.nextKickCategoryPage, 2)
    XCTAssertNotNil(service.moreCategoriesErrorMessage)
  }

  func testFullTextSearchIncludesOfflineChannelsAndCategoryArtwork() throws {
    let data = Data(#"{"channels":[{"slug":"one","user":{"username":"One"},"isLive":false},{"slug":"banned","user":{"username":"Banned"},"isLive":true,"is_banned":true}],"categories":[{"id":15,"name":"Chatting","banner":{"src":"https://files.kick.com/category.webp"}}],"livestreams":{"tags":[]}}"#.utf8)
    let result = try KickBrowseService.decodeSearch(data)
    XCTAssertEqual(result.channels.map(\.channelKey), ["kick:one"])
    XCTAssertFalse(result.channels[0].isLive)
    XCTAssertNil(result.channels[0].viewerCount)
    XCTAssertEqual(result.categories.first?.boxArtURL?.host, "files.kick.com")
  }

  func testSearchEnrichmentFailureRetainsBasicRowAndReportsWarning() async throws {
    let result = try await KickBrowseService.search("just chat") { request in
      guard request.url?.path == "/api/search" else { throw URLError(.timedOut) }
      XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first?.value, "just chat")
      return Self.response(request, data: Data(#"{"channels":[{"slug":"one","user":{"username":"One"},"isLive":true}],"categories":[]}"#.utf8))
    }
    XCTAssertEqual(result.channels.map(\.channelKey), ["kick:one"])
    XCTAssertNotNil(result.warning)
    XCTAssertNil(result.channels.first?.viewerCount)
  }

  func testSearchReportsBothProviderFailures() async {
    let service = SearchService(loadData: { _ in throw URLError(.timedOut) }, loadKickSearch: { _ in
      .init(channels: [], categories: [], warning: "Kick details unavailable")
    })
    await service.search("some channel")
    XCTAssertTrue(service.errorMessage?.contains("Could not search") == true)
    XCTAssertTrue(service.errorMessage?.contains("Kick details unavailable") == true)
  }

  func testFailedKickReturnRefreshPreservesItsExistingResults() async {
    let attempts = KickSearchAttempts()
    let channel = KickChannel(slug: "one", displayName: "One", title: "Live", category: "",
      viewerCount: 10, isLive: true, chatroomID: nil, imageURL: nil).followedChannel
    let service = SearchService(loadKickSearch: { _ in
      guard await attempts.next() == 1 else { throw URLError(.timedOut) }
      return .init(channels: [channel], categories: [])
    })
    await service.search("one", filter: .kick)
    await service.search("one", preservingResultsOnFailure: true, filter: .kick)
    XCTAssertEqual(service.channelResults.map(\.channelKey), ["kick:one"])
    XCTAssertNotNil(service.errorMessage)
  }

  func testShortKickSearchExplainsMinimumWithoutSendingInvalidRequest() async {
    let service = SearchService(loadKickSearch: { term in
      try await KickBrowseService.search(term) { _ in
        XCTFail("Kick rejects queries shorter than three characters")
        throw URLError(.badURL)
      }
    })
    await service.search("xq", filter: .kick)
    XCTAssertTrue(service.channelResults.isEmpty)
    XCTAssertEqual(service.errorMessage, KickBrowseService.Failure.searchTooShort.localizedDescription)
  }

  func testHomeRecommendationsContainGlobalKickAndMergeCostreamers() async {
    let kick = directory(slugs: ["xqc", "exclusive"])
    let twitch = twitchDirectory(logins: ["xqc"])
    let service = RecommendationsService(creatorLinks: ["xqc": "xqc"]) { request in
      if request.url?.host == "web.kick.com" { return Self.response(request, data: kick) }
      if request.url?.host == "kick.com" {
        return Self.response(request, data: Data(#"{"current_page":1,"data":[{"id":15,"name":"Chatting"}],"next_page_url":null}"#.utf8))
      }
      let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
      return Self.response(request, data: body.contains("TopGames")
        ? Data(#"{"data":{"games":{"edges":[]}}}"#.utf8) : twitch)
    }
    await service.refresh()
    XCTAssertEqual(service.channels.map(\.channelKey), ["xqc", "kick:exclusive"])
    XCTAssertEqual(service.channels.first?.combinedViewerCount, 150)
    XCTAssertEqual(service.categories.first?.platform, .kick)
    XCTAssertNil(service.errorMessage)
  }

  func testMixedHomeCategoryResolvesNativeKickIDAndKeepsItForPagination() async {
    let body = directory()
    let service = BrowseService { request in
      if request.url?.path == "/api/search" {
        return Self.response(request, data: Data(#"{"channels":[],"categories":[{"id":15,"name":"Chatting"}]}"#.utf8))
      }
      if request.url?.host == "web.kick.com" {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "category_id" }?.value, "15")
        return Self.response(request, data: body)
      }
      return Self.response(request, data: Data(#"{"data":{"game":{"streams":{"edges":[]}}}}"#.utf8))
    }
    let category = TwitchCategory(id: "509658", name: "Chatting", boxArtURL: nil, viewerCount: nil)
    await service.loadStreams(for: category, mixCategoryPlatforms: true)
    await service.loadMoreStreams()
    XCTAssertEqual(service.categoryStreams.map(\.channelKey), ["kick:one", "kick:two"])
    XCTAssertNil(service.streamsErrorMessage)
  }

  func testKickPersonalizedCandidatesUseExactCategoryMappings() async {
    let body = directory()
    let candidates = await KickBrowseService.recommendationCandidates(for: ["Chatting", "Unknown"]) { request in
      if request.url?.path == "/api/search" {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        let categories = query?.lowercased() == "chatting" ? #"{"id":15,"name":"Chatting"}"# : #"{"id":2,"name":"Not the same category"}"#
        return Self.response(request, data: Data("{\"channels\":[],\"categories\":[\(categories)]}".utf8))
      }
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      XCTAssertEqual(query.first { $0.name == "category_id" }?.value, "15")
      return Self.response(request, data: body)
    }
    XCTAssertEqual(candidates.map(\.channelKey), ["kick:one", "kick:two"])
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

private actor KickSearchAttempts {
  private var count = 0
  func next() -> Int { count += 1; return count }
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
