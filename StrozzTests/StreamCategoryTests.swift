import XCTest
#if os(iOS)
@testable import StrozzMobile
#else
@testable import Strozz
#endif

final class StreamCategoryTests: XCTestCase {
  private func target(_ name: String, platform: LivePlatform = .twitch) -> StreamCategoryTarget? {
    var channel = FollowedChannel(id: "1", login: "example", displayName: "Example",
      title: "", gameName: name, viewerCount: nil, thumbnailURL: nil,
      profileImageURL: nil, isLive: true)
    channel.platform = platform
    return StreamCategoryTarget(channel: channel)
  }

  func testMenuRequiresCategoryAndSupportedPlatform() {
    XCTAssertNil(target(" \n "))
    XCTAssertNil(target("Gaming", platform: .youtube))
    XCTAssertEqual(target(" Just Chatting\n")?.name, "Just Chatting")
    XCTAssertEqual(target("Just Chatting", platform: .kick)?.platform, .kick)
  }

  func testTwitchResolvesExactNameWithoutUsingNameAsID() async throws {
    let service = StreamCategoryService { request in
      XCTAssertEqual(request.url?.host, "gql.twitch.tv")
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual((body["variables"] as? [String: String])?["name"], "Just Chatting")
      return Self.response(request, #"{"data":{"game":{"id":"509658","name":"Just Chatting","displayName":"Just Chatting"}}}"#)
    }
    let category = try await service.resolve(XCTUnwrap(target("Just Chatting")))
    XCTAssertEqual(category.sourceID, "509658")
    XCTAssertEqual(category.platform, .twitch)
    XCTAssertEqual(category.name, "Just Chatting")
  }

  func testKickUsesExactCategoryOnOriginalPlatform() async throws {
    let service = StreamCategoryService { request in
      XCTAssertNotEqual(request.url?.host, "gql.twitch.tv")
      return Self.response(request, """
        {"channels":[],"categories":[
          {"id":15,"name":"Just Chatting","banner":null},
          {"id":16,"name":"Just Chatting Extra","banner":null}]}
        """)
    }
    let category = try await service.resolve(XCTUnwrap(target("Just Chatting", platform: .kick)))
    XCTAssertEqual(category.id, "kick:15")
    XCTAssertEqual(category.platform, .kick)
  }

  func testMissingPartialAndWrongCategoryResponsesFail() async throws {
    for json in [
      #"{"data":{"game":null}}"#,
      #"{"data":{"game":{"id":"1","name":"Wrong game"}}}"#,
      #"{"data":{"game":{"id":"1","name":"Just Chatting"}},"errors":[{"message":"Partial failure"}]}"#,
    ] {
      let service = StreamCategoryService { Self.response($0, json) }
      do {
        _ = try await service.resolve(XCTUnwrap(target("Just Chatting")))
        XCTFail("Must not navigate to a guessed category")
      } catch {}
    }
  }

  func testHTTPFailureIsSurfaced() async throws {
    let service = StreamCategoryService { Self.response($0, "{}", status: 503) }
    do {
      _ = try await service.resolve(XCTUnwrap(target("Just Chatting")))
      XCTFail("Expected failure")
    } catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
  }

  func testTwitchPassesQuotedNameAsVariable() async throws {
    let name = "Game \"quoted\" \\ category"
    let service = StreamCategoryService { request in
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
      XCTAssertEqual((body["variables"] as? [String: String])?["name"], name)
      XCTAssertFalse(try XCTUnwrap(body["query"] as? String).contains(name))
      let data = try JSONSerialization.data(withJSONObject: ["data": ["game": ["id": "42", "name": name]]])
      return (data, Self.response(request, "{}").1)
    }
    let category = try await service.resolve(XCTUnwrap(target(name)))
    XCTAssertEqual(category.sourceID, "42")
  }

  func testKickDoesNotGuessMissingOrAmbiguousCategories() async throws {
    for categories in [
      #"[]"#,
      #"[{"id":1,"name":"Just Chatting Extra"}]"#,
      #"[{"id":1,"name":"Just Chatting"},{"id":2,"name":"just chatting"}]"#,
    ] {
      let service = StreamCategoryService {
        Self.response($0, #"{"channels":[],"categories":\#(categories)}"#)
      }
      do {
        _ = try await service.resolve(XCTUnwrap(target("Just Chatting", platform: .kick)))
        XCTFail("Must not navigate to an ambiguous or unrelated category")
      } catch {
        XCTAssertTrue(error is StreamCategoryService.Failure)
      }
    }
  }

  private static func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, URLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
      httpVersion: nil, headerFields: nil)!)
  }
}
