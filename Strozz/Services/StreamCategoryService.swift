import Foundation

struct StreamCategoryTarget: Hashable {
  let name: String
  let platform: LivePlatform

  init?(channel: FollowedChannel) {
    let name = channel.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, channel.platform != .youtube else { return nil }
    self.name = name
    self.platform = channel.platform
  }
}

struct StreamCategoryService {
  var loadData: NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }

  enum Failure: LocalizedError {
    case unavailable
    var errorDescription: String? {
      String(localized: "This category is no longer available.")
    }
  }

  func resolve(_ target: StreamCategoryTarget) async throws -> TwitchCategory {
    if target.platform == .kick {
      let matches = try await KickBrowseService.searchCategories(target.name, load: loadData)
        .filter { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }
      guard matches.count == 1, let category = matches.first else { throw Failure.unavailable }
      return category
    }
    let query = """
      query StreamCategory($name: String!) {
        game(name: $name) { id name displayName boxArtURL(width: 285, height: 380) }
      }
      """
    var request = TwitchAPIClient.graphQLRequest()
    request.httpBody = try JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["name": target.name]))
    let (data, response) = try await loadData(request)
    let envelope = try TwitchAPIClient.decode(Envelope.self, from: data, response: response)
    guard envelope.errors?.isEmpty != false, let result = envelope.data else {
      throw URLError(.badServerResponse)
    }
    guard let game = result.game, !game.id.isEmpty,
      [game.name, game.displayName].contains(where: {
        $0?.caseInsensitiveCompare(target.name) == .orderedSame
      }) else { throw Failure.unavailable }
    return TwitchCategory(id: game.id, name: game.displayName ?? game.name,
      boxArtURL: game.boxArtURL.flatMap(URL.init(string:)), viewerCount: nil)
  }

  private struct Envelope: Decodable {
    let data: ResultData?
    let errors: [GraphQLError]?
  }
  private struct GraphQLError: Decodable { let message: String }
  private struct ResultData: Decodable { let game: Game? }
  private struct Game: Decodable {
    let id: String
    let name: String
    let displayName: String?
    let boxArtURL: String?
  }
}
