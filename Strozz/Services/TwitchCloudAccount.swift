import Foundation

struct TwitchCredential: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var userID: String
  var clientID: String
  var login: String
  var displayName: String
  var imageURL: URL?
  var cloudOwner: String?
}

struct TwitchCloudAccount: Codable, Equatable, Sendable {
  var owner: String
  var revision = UUID()
  var credential: TwitchCredential?
  var rewards: TwitchWatchRewardsAPI.Credential?
  var refreshID: UUID?

  func validated() throws -> Self {
    guard !owner.isEmpty, rewards == nil || rewards?.userID == credential?.userID else {
      throw TwitchSyncError.invalidAccount
    }
    if let credential {
      guard !credential.accessToken.isEmpty, !credential.userID.isEmpty, !credential.clientID.isEmpty,
        credential.cloudOwner == owner else { throw TwitchSyncError.invalidAccount }
    }
    return self
  }
}

struct TwitchCloudSnapshot: Sendable {
  var account: TwitchCloudAccount
  var version: Data
}

protocol TwitchCloudDatabase: Sendable {
  func owner() async throws -> String
  func fetch(owner: String) async throws -> TwitchCloudSnapshot?
  func save(_ account: TwitchCloudAccount, replacing: TwitchCloudSnapshot?) async throws -> TwitchCloudSnapshot
}

enum TwitchSyncError: LocalizedError, Equatable {
  case unavailable, conflict, invalidAccount, accountChanged, accountConflict, refreshPending, busy

  var errorDescription: String? {
    switch self {
    case .unavailable: "Sign in to iCloud and enable iCloud access to sync your Twitch connection."
    case .conflict: "Your iCloud connection changed on another device. Try syncing again."
    case .invalidAccount: "The saved connection could not be verified. Sign in to Twitch again."
    case .accountChanged: "The Apple Account changed. Sync again before using this connection."
    case .accountConflict: "This device and iCloud use different Twitch accounts. Choose which connection to keep."
    case .refreshPending: "Another device is finishing Twitch sign-in renewal. Open Strozz there, or sign in again if renewal was interrupted."
    case .busy: "An account update is already in progress. Try again shortly."
    }
  }
}

struct TwitchPendingPublication: Codable, Sendable {
  let owner: String
  let refreshID: UUID
  let credential: TwitchCredential
}

struct TwitchRewardsChange: Codable, Sendable {
  let owner: String?
  let userID: String
  let credential: TwitchWatchRewardsAPI.Credential?
}

/// Reserving the refresh ID is a compare-and-swap operation. No timeout permits
/// another device to spend the same single-use Twitch refresh token.
enum TwitchCloudRefresh {
  static func reserve(_ snapshot: TwitchCloudSnapshot, id: UUID) throws -> TwitchCloudAccount {
    guard snapshot.account.refreshID == nil else { throw TwitchSyncError.refreshPending }
    guard snapshot.account.credential?.refreshToken != nil else { throw TwitchSyncError.invalidAccount }
    var reserved = snapshot.account
    reserved.refreshID = id
    return reserved
  }

  static func publication(_ pending: TwitchPendingPublication, into snapshot: TwitchCloudSnapshot) throws -> TwitchCloudAccount {
    guard snapshot.account.owner == pending.owner, snapshot.account.refreshID == pending.refreshID,
      snapshot.account.credential?.userID == pending.credential.userID,
      snapshot.account.credential?.clientID == pending.credential.clientID else { throw TwitchSyncError.conflict }
    var updated = snapshot.account
    updated.credential = pending.credential
    updated.refreshID = nil
    updated.revision = UUID()
    return try updated.validated()
  }
}
