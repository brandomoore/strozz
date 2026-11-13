import Foundation

/// Helix omits encryption status. Resolve only the current live candidates in
/// batches during their existing refresh; never probe playlists or persist a ban.
enum TwitchStreamProtection {
  typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static func encryptedLogins(
    _ logins: [String], clientID: String, load: Loader
  ) async throws -> Set<String> {
    let logins = Array(Set(logins.map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
    var encrypted = Set<String>()
    for offset in stride(from: 0, to: logins.count, by: 100) {
      try Task.checkCancellation()
      let batch = Array(logins[offset..<min(offset + 100, logins.count)])
      var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 6
      request.setValue(clientID, forHTTPHeaderField: "Client-ID")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "query": """
          query StreamProtection($logins: [String!]) {
            users(logins: $logins) { login stream { isEncrypted } }
          }
          """,
        "variables": ["logins": batch],
      ])
      let (data, response) = try await load(request)
      try Task.checkCancellation()
      guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let envelope = try JSONDecoder().decode(Envelope.self, from: data)
      guard envelope.errors?.isEmpty != false, let users = envelope.data?.users else {
        throw URLError(.cannotParseResponse)
      }
      let requested = Set(batch)
      for user in users.compactMap({ $0 }) where user.stream?.isEncrypted == true {
        let login = user.login.lowercased()
        if requested.contains(login) { encrypted.insert(login) }
      }
    }
    return encrypted
  }

  private struct Envelope: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?
  }
  private struct GraphQLError: Decodable { let message: String }
  private struct Payload: Decodable { let users: [User?]? }
  private struct User: Decodable {
    let login: String
    let stream: Stream?
  }
  private struct Stream: Decodable { let isEncrypted: Bool? }
}
