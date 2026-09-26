import XCTest
@testable import Strozz

private actor EmoteCatalogTransport {
    var requests: [URLRequest] = []
    var names = ["Existing"]
    var sevenTVStatus = 200
    var sevenTVFailures = 0
    var sevenTVOverride: String?
    var identityStatus = 200
    var blockSevenTV = false
    var continuation: CheckedContinuation<Void, Never>?

    func setNames(_ names: [String]) { self.names = names }
    func setStatus(_ status: Int) { sevenTVStatus = status }
    func setFailures(_ count: Int) { sevenTVFailures = count }
    func setOverride(_ body: String?) { sevenTVOverride = body }
    func setIdentityStatus(_ status: Int) { identityStatus = status }
    func block() { blockSevenTV = true }
    var blocked: Bool { continuation != nil }
    func release() {
        blockSevenTV = false
        continuation?.resume()
        continuation = nil
    }
    var sevenTVRequests: Int { requests.filter { $0.url?.path == "/v3/users/twitch/53430798" }.count }
    var otherRequests: Int { requests.count - sevenTVRequests }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        var status = 200
        let body: String
        switch url.host {
        case "gql.twitch.tv":
            let query = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if query.contains("query UserID") {
                status = identityStatus
                body = #"{"data":{"user":{"id":"53430798"}}}"#
            } else if query.contains("ChannelEmotes") {
                body = #"{"data":{"user":{"subscriptionProducts":[{"emotes":[{"id":"twitch-channel","token":"Subscriber"}]}]}}}"#
            } else {
                body = #"{"data":{"emoteSet":{"emotes":[{"id":"twitch-global","token":"Kappa"}]}}}"#
            }
        case "7tv.io":
            if url.path == "/v3/emote-sets/global" {
                body = #"{"emotes":[{"id":"global","name":"Global7TV"}]}"#
            } else {
                if blockSevenTV { await withCheckedContinuation { continuation = $0 } }
                status = sevenTVStatus
                if sevenTVFailures > 0 {
                    sevenTVFailures -= 1
                    status = 503
                }
                if let sevenTVOverride { body = sevenTVOverride }
                else {
                    let emotes = names.enumerated().map { index, name in
                        ["id": name == "AUUUGGHHH" ? "01M3BEKCCS43B2PZSFBQWE2H4H" : "id-\(index)",
                         "name": name]
                    }
                    body = String(decoding: try JSONSerialization.data(
                        withJSONObject: ["emote_set": ["emotes": emotes]]), as: UTF8.self)
                }
            }
        case "api.betterttv.net":
            body = url.path.hasSuffix("global") ? "[]" : #"{"channelEmotes":[],"sharedEmotes":[]}"#
        case "api.frankerfacez.com":
            body = #"{"sets":{}}"#
        default: throw URLError(.unsupportedURL)
        }
        return (Data(body.utf8), HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class EmoteCatalogTests: XCTestCase {
    private func catalog(_ transport: EmoteCatalogTransport) -> EmoteCatalogService {
        EmoteCatalogService(load: { try await transport.load($0) })
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true")
    }

    func testBurnThousandEntrySetIncludesExactNewestEmote() async throws {
        let transport = EmoteCatalogTransport()
        await transport.setNames((0..<999).map { "Emote\($0)" } + ["AUUUGGHHH"])
        let snapshot = await catalog(transport).snapshot(for: "Burn")
        XCTAssertFalse(snapshot.needsRetry)
        XCTAssertEqual(snapshot.urls.count, 1003)
        let url = try XCTUnwrap(snapshot.urls["AUUUGGHHH"])
        XCTAssertEqual(url.absoluteString, "https://cdn.7tv.app/emote/01M3BEKCCS43B2PZSFBQWE2H4H/2x.webp")
        let segments = ChatLineTokenizer.segments(
            text: "AUUUGGHHH", twitchEmoteURLs: [:], youtubeEmoteURLs: [:],
            globalEmoteURLs: snapshot.urls, cheermotes: [], shouldRenderCheers: false)
        XCTAssertEqual(segments, [.emote(name: "AUUUGGHHH", url: url)])
    }

    func testRefreshBypassesChannelCacheWithoutRefetchingOtherProviders() async throws {
        let transport = EmoteCatalogTransport()
        let service = catalog(transport)
        let initial = await service.snapshot(for: "burn")
        XCTAssertNotNil(initial.urls["Existing"])
        let otherRequests = await transport.otherRequests
        await transport.setNames(["AUUUGGHHH"])
        let cached = await service.snapshot(for: "BURN")
        XCTAssertNil(cached.urls["AUUUGGHHH"])
        let refreshed = await service.snapshot(for: "burn", refreshChannelEmotes: true)
        XCTAssertNotNil(refreshed.urls["AUUUGGHHH"])
        XCTAssertNil(refreshed.urls["Existing"])
        let after = await transport.otherRequests
        XCTAssertEqual(after, otherRequests)
        let request = await transport.requests.last { $0.url?.host == "7tv.io" }
        XCTAssertEqual(request?.cachePolicy, .reloadRevalidatingCacheData)
    }

    func testTransientHTTPFailureRetriesBeforePublishingCatalog() async {
        let transport = EmoteCatalogTransport()
        await transport.setFailures(2)
        let result = await catalog(transport).snapshot(for: "burn")
        XCTAssertFalse(result.needsRetry)
        XCTAssertNotNil(result.urls["Existing"])
        let count = await transport.sevenTVRequests
        XCTAssertEqual(count, 3)
    }

    func testExhaustedFailureIsNotCachedAsAnEmptySet() async {
        let transport = EmoteCatalogTransport()
        await transport.setStatus(503)
        let service = catalog(transport)
        let failed = await service.snapshot(for: "burn")
        XCTAssertTrue(failed.needsRetry)
        XCTAssertNil(failed.urls["Existing"])
        XCTAssertNotNil(failed.urls["Kappa"])
        let otherRequests = await transport.otherRequests
        await transport.setStatus(200)
        let recovered = await service.snapshot(for: "burn")
        XCTAssertFalse(recovered.needsRetry)
        XCTAssertNotNil(recovered.urls["Existing"])
        let after = await transport.otherRequests
        XCTAssertEqual(after, otherRequests)
        let attempts = await transport.sevenTVRequests
        XCTAssertEqual(attempts, 4)
    }

    func testMissingSevenTVAccountIsAValidEmptyCatalog() async {
        let transport = EmoteCatalogTransport()
        await transport.setStatus(404)
        let service = catalog(transport)
        let first = await service.snapshot(for: "burn")
        let second = await service.snapshot(for: "burn")
        XCTAssertFalse(first.needsRetry)
        XCTAssertFalse(second.needsRetry)
        let count = await transport.sevenTVRequests
        XCTAssertEqual(count, 1)
    }

    func testNoSelectedSetIsEmptyButMissingFieldsAreRetried() async {
        for body in [#"{"emote_set":null}"#, "{}", #"{"emote_set":{}}"#, "not json"] {
            let transport = EmoteCatalogTransport()
            await transport.setOverride(body)
            let service = catalog(transport)
            let initial = await service.snapshot(for: "burn")
            XCTAssertEqual(initial.needsRetry, body != #"{"emote_set":null}"#)
            await transport.setOverride(nil)
            let recovered = await service.snapshot(for: "burn", refreshChannelEmotes: true)
            XCTAssertFalse(recovered.needsRetry)
            XCTAssertNotNil(recovered.urls["Existing"])
        }
    }

    func testFailedIdentityLookupCannotCacheMissingChannelEmotes() async {
        let transport = EmoteCatalogTransport()
        await transport.setIdentityStatus(403)
        let service = catalog(transport)
        let failed = await service.snapshot(for: "burn")
        XCTAssertTrue(failed.needsRetry)
        let skipped = await transport.sevenTVRequests
        XCTAssertEqual(skipped, 0)
        await transport.setIdentityStatus(200)
        let recovered = await service.snapshot(for: "burn")
        XCTAssertFalse(recovered.needsRetry)
        XCTAssertNotNil(recovered.urls["Existing"])
    }

    func testChannelAliasAndNestedIDRemainSupported() async {
        let transport = EmoteCatalogTransport()
        await transport.setOverride(#"{"emote_set":{"emotes":[{"name":"Alias","data":{"id":"asset-id","name":"OriginalName"}}]}}"#)
        let result = await catalog(transport).snapshot(for: "burn")
        XCTAssertFalse(result.needsRetry)
        XCTAssertEqual(result.urls["Alias"]?.absoluteString, "https://cdn.7tv.app/emote/asset-id/2x.webp")
        XCTAssertNil(result.urls["OriginalName"])
    }

    func testLiveChatRefreshRetokenizesAlreadyVisibleWords() async throws {
        let transport = EmoteCatalogTransport()
        let service = catalog(transport)
        let chat = ChatService()
        defer { chat.disconnect() }
        chat.messages = [try XCTUnwrap(ChatMessage(ircLine: ":viewer!viewer@host PRIVMSG #burn :AUUUGGHHH"))]
        chat.startEmoteCatalogLoading(for: "burn", catalog: service) {
            try await Task.sleep(for: .milliseconds(30))
        }
        try await waitFor { chat.emoteURLs["Existing"] != nil }
        await transport.setNames(["Existing", "AUUUGGHHH"])
        try await waitFor {
            guard let url = chat.emoteURLs["AUUUGGHHH"] else { return false }
            return chat.messages.first?.segments == [.emote(name: "AUUUGGHHH", url: url)]
        }
        XCTAssertFalse(chat.emoteCatalogNeedsRetry)
        let parsed = await chat.ingestPipeline.parseAndTokenize([
            ":viewer!viewer@host PRIVMSG #burn :AUUUGGHHH",
        ])
        XCTAssertEqual(parsed.first?.segments, chat.messages.first?.segments)
    }

    func testOutageDuringRefreshPreservesKnownEmotesThenRecovers() async throws {
        let transport = EmoteCatalogTransport()
        let chat = ChatService()
        defer { chat.disconnect() }
        chat.startEmoteCatalogLoading(for: "burn", catalog: catalog(transport)) {
            try await Task.sleep(for: .milliseconds(40))
        }
        try await waitFor { chat.emoteURLs["Existing"] != nil }
        // A non-retryable response avoids spending the test in HTTP backoff.
        await transport.setStatus(403)
        try await waitFor { chat.emoteCatalogNeedsRetry }
        XCTAssertNotNil(chat.emoteURLs["Existing"])
        await transport.setNames(["AUUUGGHHH"])
        await transport.setStatus(200)
        try await waitFor { chat.emoteURLs["AUUUGGHHH"] != nil && !chat.emoteCatalogNeedsRetry }
        XCTAssertNil(chat.emoteURLs["Existing"])
    }

    func testDisconnectCancelsPollingAndRejectsLateCatalog() async throws {
        let transport = EmoteCatalogTransport()
        await transport.block()
        let chat = ChatService()
        chat.startEmoteCatalogLoading(for: "burn", catalog: catalog(transport)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitFor { await transport.blocked }
        let task = try XCTUnwrap(chat.emoteCatalogTask)
        chat.disconnect()
        await transport.release()
        await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(chat.emoteCatalogTask)
        XCTAssertTrue(chat.emoteURLs.isEmpty)
        XCTAssertFalse(chat.emoteCatalogNeedsRetry)
        let before = await transport.sevenTVRequests
        try await Task.sleep(for: .milliseconds(50))
        let after = await transport.sevenTVRequests
        XCTAssertEqual(after, before)
    }
}
