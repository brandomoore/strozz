import Foundation

struct TwitchChannelPoints: Equatable {
  let channelID: String
  var balance: Int
  let name: String
  var claimID: String?
  let rewards: [TwitchChannelReward]
  let emotes: [TwitchRewardEmote]
}

struct TwitchRewardEmote: Equatable, Identifiable {
  let id: String
  let token: String
  var modifications: [TwitchRewardEmote] = []
}

struct TwitchChannelReward: Equatable, Identifiable {
  enum Kind: String {
    case custom
    case highlightedMessage = "SEND_HIGHLIGHTED_MESSAGE"
    case subOnlyMessage = "SINGLE_MESSAGE_BYPASS_SUB_MODE"
    case randomEmote = "RANDOM_SUB_EMOTE_UNLOCK"
    case chosenEmote = "CHOSEN_SUB_EMOTE_UNLOCK"
    case modifiedEmote = "CHOSEN_MODIFIED_SUB_EMOTE_UNLOCK"
  }

  let id: String
  let title: String
  let cost: Int
  let prompt: String?
  let kind: Kind
  let requiresInput: Bool
  let enabled: Bool
  let inStock: Bool
  let paused: Bool
  let cooldownUntil: Date?

  var isAvailable: Bool {
    enabled && inStock && !paused && (cooldownUntil.map { $0 <= Date() } ?? true)
  }

  var needsEmote: Bool { kind == .chosenEmote || kind == .modifiedEmote }
}

enum TwitchRewardsActionError: Error, LocalizedError, Equatable {
  case unavailable, changed, insufficientPoints, invalidInput, rejected, alreadyOwned
  case pollClosed, alreadyVoted, uncertain

  var errorDescription: String? {
    switch self {
    case .unavailable: String(localized: "This reward is not available right now.")
    case .changed: String(localized: "This reward changed. Refresh and review its cost again.")
    case .insufficientPoints: String(localized: "Not enough channel points.")
    case .invalidInput: String(localized: "Enter a message of up to 500 characters or choose an emote.")
    case .rejected: String(localized: "Twitch did not accept this action.")
    case .alreadyOwned: String(localized: "You already have this emote.")
    case .pollClosed: String(localized: "This poll has ended.")
    case .alreadyVoted: String(localized: "You have already voted in this poll.")
    case .uncertain: String(localized: "Twitch did not confirm the result. Check Twitch before trying again.")
    }
  }
}

extension TwitchWatchRewardsAPI {
  private struct PointsResponse: Decodable {
    struct Community: Decodable {
      struct Channel: Decodable {
        struct Viewer: Decodable {
          struct Points: Decodable {
            struct Claim: Decodable { let id: String }
            let balance: Int
            let availableClaim: Claim?
          }
          let communityPoints: Points?
        }
        let id: String
        let viewer: Viewer?
        let communityPointsSettings: PointsSettings?
        enum CodingKeys: String, CodingKey {
          case id, communityPointsSettings
          case viewer = "self"
        }
      }
      let channel: Channel
    }
    let community: Community
  }

  private struct PointsSettings: Decodable {
    struct Variant: Decodable {
      struct Emote: Decodable { let id: String; let token: String }
      struct Modification: Decodable { let emote: Emote }
      let isUnlockable: Bool
      let emote: Emote
      let modifications: [Modification]
    }
    let isEnabled: Bool
    let name: String?
    let customRewards: [RawReward]
    let automaticRewards: [RawReward]
    let emoteVariants: [Variant]
  }

  private struct RawReward: Decodable {
    let id: String
    let title: String?
    let type: String?
    let cost: Int?
    let defaultCost: Int?
    let pricingType: String?
    let prompt: String?
    let isEnabled: Bool
    let isInStock: Bool
    let isPaused: Bool?
    let isUserInputRequired: Bool?
    let cooldownExpiresAt: String?

    func reward(custom: Bool) throws -> TwitchChannelReward? {
      guard !id.isEmpty else { throw Failure.malformedResponse }
      let kind: TwitchChannelReward.Kind
      let resolvedTitle: String
      if custom {
        guard pricingType == nil || pricingType == "POINTS" else { return nil }
        guard let title, !title.isEmpty, isPaused != nil, isUserInputRequired != nil else {
          throw Failure.malformedResponse
        }
        kind = .custom
        resolvedTitle = title
      } else {
        // Bits and unfamiliar future reward types must never become point redemptions.
        guard pricingType == "POINTS", let type,
          let known = TwitchChannelReward.Kind(rawValue: type), known != .custom else { return nil }
        kind = known
        switch known {
        case .highlightedMessage: resolvedTitle = String(localized: "Highlight a message")
        case .subOnlyMessage: resolvedTitle = String(localized: "Send a message in sub-only chat")
        case .randomEmote: resolvedTitle = String(localized: "Unlock a random emote")
        case .chosenEmote: resolvedTitle = String(localized: "Unlock an emote")
        case .modifiedEmote: resolvedTitle = String(localized: "Modify an emote")
        case .custom: throw Failure.malformedResponse
        }
      }
      guard let price = cost ?? (custom ? nil : defaultCost), price >= 0 else {
        throw Failure.malformedResponse
      }
      var cooldown: Date?
      if let raw = cooldownExpiresAt {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        cooldown = formatter.date(from: raw)
        if cooldown == nil {
          formatter.formatOptions = [.withInternetDateTime]
          cooldown = formatter.date(from: raw)
        }
        guard cooldown != nil else { throw Failure.malformedResponse }
      }
      return TwitchChannelReward(
        id: id, title: resolvedTitle, cost: price, prompt: prompt, kind: kind,
        requiresInput: custom ? isUserInputRequired == true
          : kind == .highlightedMessage || kind == .subOnlyMessage,
        enabled: isEnabled, inStock: isInStock, paused: custom && isPaused == true,
        cooldownUntil: cooldown)
    }
  }

  func channelPoints(login: String, token: String) async throws -> TwitchChannelPoints {
    let response: PointsResponse = try await graphQL(Self.persisted(
      "ChannelPointsContext",
      hash: "374314de591e69925fce3ddc2bcf085796f56ebb8cad67a0daa3165c03adc345",
      variables: ["channelLogin": login.lowercased(), "includeGoalTypes": ["CREATOR", "BOOST"]]),
      token: token)
    let channel = response.community.channel
    guard let settings = channel.communityPointsSettings, settings.isEnabled,
      let points = channel.viewer?.communityPoints else { throw TwitchRewardsActionError.unavailable }
    guard !channel.id.isEmpty, points.balance >= 0,
      points.availableClaim?.id.isEmpty != true else { throw Failure.malformedResponse }
    let custom = try settings.customRewards.compactMap { try $0.reward(custom: true) }
    let automatic = try settings.automaticRewards.compactMap { try $0.reward(custom: false) }
    let emotes = try settings.emoteVariants.filter(\.isUnlockable).map { variant in
      guard !variant.emote.id.isEmpty, !variant.emote.token.isEmpty else { throw Failure.malformedResponse }
      let modifications = try variant.modifications.map { value in
        guard !value.emote.id.isEmpty, !value.emote.token.isEmpty else { throw Failure.malformedResponse }
        return TwitchRewardEmote(id: value.emote.id, token: value.emote.token)
      }
      return TwitchRewardEmote(
        id: variant.emote.id, token: variant.emote.token, modifications: modifications)
    }
    return TwitchChannelPoints(
      channelID: channel.id, balance: points.balance,
      name: settings.name ?? String(localized: "Channel points"),
      claimID: points.availableClaim?.id,
      rewards: (custom + automatic).sorted { ($0.cost, $0.title) < ($1.cost, $1.title) },
      emotes: emotes)
  }

  private struct MutationResult: Decodable {
    struct Rejection: Decodable { let code: String }
    let error: Rejection?
    let currentPoints: Int?
    let balance: Int?

    enum CodingKeys: String, CodingKey { case error, currentPoints, balance }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // An empty/malformed object is not a successful mutation acknowledgement.
      guard container.contains(.error) else { throw Failure.malformedResponse }
      error = try container.decodeIfPresent(Rejection.self, forKey: .error)
      currentPoints = try container.decodeIfPresent(Int.self, forKey: .currentPoints)
      balance = try container.decodeIfPresent(Int.self, forKey: .balance)
    }

    func requireSuccess() throws {
      if let error {
        switch error.code {
        case "INSUFFICIENT_POINTS": throw TwitchRewardsActionError.insufficientPoints
        case "PROPERTIES_MISMATCH", "REWARD_COST_MISMATCH": throw TwitchRewardsActionError.changed
        case "EMOTE_ALREADY_ENTITLED", "ALREADY_UNLOCKED": throw TwitchRewardsActionError.alreadyOwned
        case "ALREADY_VOTED": throw TwitchRewardsActionError.alreadyVoted
        case "POLL_ENDED", "POLL_NOT_ACTIVE": throw TwitchRewardsActionError.pollClosed
        case "NOT_AVAILABLE", "COOLDOWN", "MAX_PER_STREAM_EXCEEDED", "MAX_PER_USER_PER_STREAM_EXCEEDED":
          throw TwitchRewardsActionError.unavailable
        default: throw TwitchRewardsActionError.rejected
        }
      }
      if let value = currentPoints ?? balance, value < 0 { throw Failure.malformedResponse }
    }
  }

  func claimWatchBonus(channelID: String, claimID: String, token: String) async throws -> Int {
    let response: [String: MutationResult] = try await graphQL([
      "query": "mutation StrozzClaimBonus($input: ClaimCommunityPointsInput!) { claimCommunityPoints(input: $input) { currentPoints error { code } } }",
      "variables": ["input": ["channelID": channelID, "claimID": claimID]],
    ], token: token)
    guard let result = response["claimCommunityPoints"] else { throw Failure.malformedResponse }
    try result.requireSuccess()
    guard let balance = result.currentPoints else { throw Failure.malformedResponse }
    return balance
  }

  func vote(pollID: String, choiceID: String, voteID: String, credential: Credential) async throws {
    let response: [String: MutationResult] = try await graphQL(Self.persisted(
      "ChannelPollContext_VoteInPoll",
      hash: "1280e27b0f3c7ae60b5714bd569771ea50635778473182e6e959e2dcfcc16e3c",
      variables: ["input": [
        "pollID": pollID, "choiceID": choiceID, "userID": credential.userID,
        "voteID": voteID, "tokens": NSNull(),
      ]]), token: credential.token)
    guard let result = response["voteInPoll"] else { throw Failure.malformedResponse }
    try result.requireSuccess()
  }

  func redeem(
    _ reward: TwitchChannelReward, channelID: String, message: String, emoteID: String?,
    transactionID: String, token: String
  ) async throws {
    var input: [String: Any] = [
      "channelID": channelID, "cost": reward.cost, "transactionID": transactionID,
    ]
    let body: [String: Any]
    let key: String
    switch reward.kind {
    case .custom:
      input["rewardID"] = reward.id
      input["title"] = reward.title
      input["prompt"] = message
      input["pricingType"] = "POINTS"
      key = "redeemCommunityPointsCustomReward"
      body = Self.persisted("RedeemCustomReward",
        hash: "d56249a7adb4978898ea3412e196688d4ac3cea1c0c2dfd65561d229ea5dcc42",
        variables: ["input": input])
    case .highlightedMessage:
      input["message"] = message
      key = "sendHighlightedChatMessage"
      body = Self.persisted("SendHighlightedChatMessage",
        hash: "bb187d763156dc5c25c6457e1b32da6c5033cb7504854e6d33a8b876d10444b6",
        variables: ["input": input])
    case .randomEmote:
      key = "unlockRandomSubscriberEmote"
      body = Self.persisted("UnlockRandomSubscriberEmote",
        hash: "f548e89966b21d0094f3dc35233232eb6ec76d63e02594c8a494407712a85350",
        variables: ["input": input])
    case .chosenEmote:
      guard let emoteID, !emoteID.isEmpty else { throw TwitchRewardsActionError.invalidInput }
      input["emoteID"] = emoteID
      key = "unlockChosenSubscriberEmote"
      body = [
        "query": "mutation StrozzUnlockEmote($input: UnlockChosenSubscriberEmoteInput!) { unlockChosenSubscriberEmote(input: $input) { balance error { code } } }",
        "variables": ["input": input],
      ]
    case .modifiedEmote:
      guard let emoteID, !emoteID.isEmpty else { throw TwitchRewardsActionError.invalidInput }
      input["emoteID"] = emoteID
      key = "unlockChosenModifiedSubscriberEmote"
      body = Self.persisted("UnlockModifiedEmote",
        hash: "30e8cc29b1d6d96809f5e35f5e7a550ae8bf5d26966a9637d919477ffd0bfc52",
        variables: ["input": input])
    case .subOnlyMessage:
      throw TwitchRewardsActionError.unavailable
    }
    let response: [String: MutationResult] = try await graphQL(body, token: token)
    guard let result = response[key] else { throw Failure.malformedResponse }
    try result.requireSuccess()
  }

  private static func persisted(
    _ name: String, hash: String, variables: [String: Any]
  ) -> [String: Any] {
    [
      "operationName": name, "variables": variables,
      "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
    ]
  }
}
