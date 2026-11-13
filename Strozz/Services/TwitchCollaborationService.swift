import Foundation

struct TwitchCollaborationParticipant: Decodable, Hashable, Identifiable {
  let id: String
  let login: String
  let displayName: String?

  var name: String {
    let display = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return display.isEmpty ? login : display
  }
}

/// Public Stream Together participants, not inferred from titles or shared names.
struct TwitchCollaborationService {
  var loadData: NetworkClient.DataLoader = { try await NetworkClient.api.data(for: $0) }

  func fetch(channelID: String) async throws -> [TwitchCollaborationParticipant] {
    let query = """
      query StrozzStreamingTogether($id: ID!) {
        user(id: $id) { stream { id } }
        guestStarChannelCollaboration(options: {channelIDs: [$id]}) {
          id
          session {
            host { id login displayName }
            guests { user { id login displayName } }
          }
        }
      }
      """
    var request = TwitchAPIClient.graphQLRequest()
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpBody = try JSONSerialization.data(
      withJSONObject: TwitchAPIClient.graphQLBody(query: query, variables: ["id": channelID]))
    let (data, response) = try await loadData(request)
    try TwitchAPIClient.validatedData(data, response)
    return try Self.participants(from: data, channelID: channelID)
  }

  static func participants(from data: Data, channelID: String) throws -> [TwitchCollaborationParticipant] {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.errors?.isEmpty != false, let result = envelope.data else {
      throw URLError(.badServerResponse)
    }
    guard result.user?.stream != nil,
      let collaboration = result.guestStarChannelCollaboration.first(where: { $0.id == channelID }),
      let session = collaboration.session else { return [] }

    var ids = Set<String>()
    var logins = Set<String>()
    let people = ([session.host] + session.guests.compactMap { $0?.user }).filter {
      !$0.id.isEmpty && !$0.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && ids.insert($0.id).inserted && logins.insert($0.login.lowercased()).inserted
    }
    // Put the page's broadcaster first without changing anyone's channel identity.
    guard people.count > 1, let current = people.first(where: { $0.id == channelID }) else { return [] }
    return [current] + people.filter { $0.id != channelID }
  }

  private struct Envelope: Decodable {
    let data: ResultData?
    let errors: [GraphQLError]?
  }
  private struct GraphQLError: Decodable { let message: String }
  private struct ResultData: Decodable {
    let user: User?
    let guestStarChannelCollaboration: [Collaboration]
  }
  private struct User: Decodable { let stream: Stream? }
  private struct Stream: Decodable { let id: String }
  private struct Collaboration: Decodable {
    let id: String
    let session: Session?
  }
  private struct Session: Decodable {
    let host: TwitchCollaborationParticipant
    let guests: [Guest?]
  }
  private struct Guest: Decodable { let user: TwitchCollaborationParticipant? }
}
