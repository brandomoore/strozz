import Foundation

extension TwitchWatchRewardsAPI {
  /// The caller must confirm the relationship through Helix before publishing success.
  func setFollowing(_ follow: Bool, channelID: String, token: String) async throws {
    struct Result: Decodable {
      struct Operation: Decodable {
        struct OperationError: Decodable { let code: String? }
        let error: OperationError?

        private enum CodingKeys: String, CodingKey { case error, follow }

        init(from decoder: Decoder) throws {
          let values = try decoder.container(keyedBy: CodingKeys.self)
          guard values.contains(.follow) || values.contains(.error) else {
            throw FollowActionError.invalidResponse
          }
          error = try values.decodeIfPresent(OperationError.self, forKey: .error)
        }
      }
      let followUser: Operation?
      let unfollowUser: Operation?
    }
    guard !channelID.isEmpty else { throw FollowActionError.invalidResponse }
    var input: [String: Any] = ["targetID": channelID]
    if follow { input["disableNotifications"] = true }
    let result: Result = try await graphQL([
      "operationName": follow ? "FollowButton_FollowUser" : "FollowButton_UnfollowUser",
      "variables": ["input": input],
      "extensions": ["persistedQuery": [
        "version": 1,
        "sha256Hash": follow
          ? "800e7346bdf7e5278a3c1d3f21b2b56e2639928f86815677a7126b093b2fdd08"
          : "f7dae976ebf41c755ae2d758546bfd176b4eeb856656098bb40e0a672ca0d880",
      ]],
    ], token: token)
    guard let operation = follow ? result.followUser : result.unfollowUser else {
      throw FollowActionError.invalidResponse
    }
    guard operation.error == nil else { throw FollowActionError.unavailable }
  }
}
