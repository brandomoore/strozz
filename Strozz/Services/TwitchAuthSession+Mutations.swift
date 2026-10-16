import Foundation

extension TwitchAuthSession {
    // MARK: - Sending chat

    /// Send a chat message to `channelLogin` on behalf of the signed-in user via
    /// the Helix "Send Chat Message" endpoint. Requires the `user:write:chat`
    /// scope. The message echoes back through the anonymous IRC read connection,
    /// so callers don't need to insert it locally.
    func sendChatMessage(_ rawText: String, toChannel channelLogin: String) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard isAuthenticated,
              let clientID,
              let accessToken,
              let senderID = userID else {
            throw ChatSendError.notSignedIn
        }

        let broadcasterID = try await resolveBroadcasterID(
            forLogin: channelLogin,
            clientID: clientID,
            accessToken: accessToken
        )
        try await postChatMessage(
            text: text,
            broadcasterID: broadcasterID,
            senderID: senderID,
            clientID: clientID,
            accessToken: accessToken
        )
    }

    private func postChatMessage(
        text: String,
        broadcasterID: String,
        senderID: String,
        clientID: String,
        accessToken: String
    ) async throws {
        var req = TwitchAPIClient.helixRequest(
            url: URL(string: "https://api.twitch.tv/helix/chat/messages")!,
            method: "POST", accessToken: accessToken, clientID: clientID,
            contentType: "application/json")

        let body: [String: String] = [
            "broadcaster_id": broadcasterID,
            "sender_id": senderID,
            "message": text,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await NetworkClient.api.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "sending message", status: status, data: data)
        }

        let payload = try TwitchAPIClient.decode(SendChatMessageEnvelope.self, from: data)
        guard let result = payload.data.first else { return }
        if result.isSent == false {
            throw ChatSendError.dropped(reason: result.dropReason?.message ?? result.dropReason?.code)
        }
    }

    // MARK: - Follow / unfollow

    /// The official Helix endpoint supplies both initial state and mutation confirmation.
    func isFollowing(channelLogin: String) async throws -> Bool {
        guard isAuthenticated, let clientID, let userID else {
            throw FollowActionError.notSignedIn
        }
        return try await withUserTokenRefreshRetry { accessToken in
            let broadcasterID = try await resolveBroadcasterID(
                forLogin: channelLogin,
                clientID: clientID,
                accessToken: accessToken
            )
            return try await fetchFollowState(
                broadcasterID: broadcasterID,
                userID: userID,
                clientID: clientID,
                accessToken: accessToken
            )
        }
    }

    func setFollowing(
        _ shouldFollow: Bool, login: String, rewards: TwitchWatchRewardsSession,
        api: TwitchWatchRewardsAPI = TwitchWatchRewardsAPI()
    ) async throws {
        guard isAuthenticated, let clientID, let userID else {
            throw FollowActionError.notSignedIn
        }
        let generation = sessionGeneration
        let credential: TwitchWatchRewardsAPI.Credential
        do {
            credential = try await rewards.validatedCredential(expectedUserID: userID)
        } catch TwitchWatchRewardsAPI.Failure.unauthorized {
            throw FollowActionError.connectionRequired
        }
        let broadcasterID = try await withUserTokenRefreshRetry { accessToken in
            try await resolveBroadcasterID(
                forLogin: login, clientID: clientID, accessToken: accessToken)
        }
        try Task.checkCancellation()
        guard sessionGeneration == generation, self.userID == userID, isAuthenticated,
              rewards.credential == credential else { throw CancellationError() }
        guard broadcasterID != userID else { throw FollowActionError.ownChannel }
        do {
            try await api.setFollowing(shouldFollow, channelID: broadcasterID, token: credential.token)
        } catch TwitchWatchRewardsAPI.Failure.unauthorized {
            if rewards.credential == credential { rewards.invalidate() }
            throw FollowActionError.connectionRequired
        } catch TwitchWatchRewardsAPI.Failure.unsupported {
            throw FollowActionError.unavailable
        } catch TwitchWatchRewardsAPI.Failure.malformedResponse {
            throw FollowActionError.invalidResponse
        }
    }

    private func fetchFollowState(
        broadcasterID: String,
        userID: String,
        clientID: String,
        accessToken: String
    ) async throws -> Bool {
        var components = URLComponents(string: "https://api.twitch.tv/helix/channels/followed")!
        components.queryItems = [
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "broadcaster_id", value: broadcasterID),
        ]
        let req = TwitchAPIClient.helixRequest(
            url: components.url!, accessToken: accessToken, clientID: clientID)
        let (data, response) = try await loadAuthData(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw makeHTTPError(context: "checking follow status", status: status, data: data)
        }
        let payload = try TwitchAPIClient.decode(FollowedStateEnvelope.self, from: data)
        // `total` can represent the overall count rather than this relationship.
        return payload.data.contains { $0.broadcasterID == broadcasterID }
    }
}

private struct FollowedStateEnvelope: Decodable {
    let data: [FollowedStateEntry]
}

private struct FollowedStateEntry: Decodable {
    let broadcasterID: String

    private enum CodingKeys: String, CodingKey {
        case broadcasterID = "broadcaster_id"
    }
}

private struct SendChatMessageEnvelope: Decodable {
    let data: [SendChatMessageResult]
}

private struct SendChatMessageResult: Decodable {
    let messageID: String?
    let isSent: Bool?
    let dropReason: DropReason?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case isSent = "is_sent"
        case dropReason = "drop_reason"
    }

    struct DropReason: Decodable {
        let code: String?
        let message: String?
    }
}
