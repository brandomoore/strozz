import Foundation

extension TwitchAuthSession {
  static let credentialService = "com.thatcube.Strozz.twitch-auth"

  var storedCredential: TwitchCredential? {
    guard let accessToken, let userID, let clientID else { return nil }
    return TwitchCredential(accessToken: accessToken, refreshToken: refreshToken, userID: userID,
      clientID: clientID, login: userLogin ?? "", displayName: userDisplayName ?? userLogin ?? "",
      imageURL: profileImageURL, cloudOwner: credentialCloudOwner)
  }

  func readSecureCredential() throws -> TwitchCredential? {
    guard let data = try CredentialKeychain.read(service: secureService) else { return nil }
    return try JSONDecoder().decode(TwitchCredential.self, from: data)
  }

  func persistCredential(_ credential: TwitchCredential) throws {
    try CredentialKeychain.write(JSONEncoder().encode(credential), service: secureService)
    try saveTopShelf(.init(clientID: credential.clientID, accessToken: credential.accessToken,
                                         userID: credential.userID))
    removeLegacyCredentials()
  }

  func useCredential(_ credential: TwitchCredential) throws {
    guard credential.clientID == clientID else { throw TwitchSyncError.invalidAccount }
    try persistCredential(credential)
    accessToken = credential.accessToken
    refreshToken = credential.refreshToken
    userID = credential.userID
    userLogin = credential.login
    userDisplayName = credential.displayName
    profileImageURL = credential.imageURL
    credentialCloudOwner = credential.cloudOwner
    isAuthenticated = true
    errorMessage = nil
  }

  func removeSecureCredentials() {
    do {
      try CredentialKeychain.remove(service: secureService)
      try saveTopShelf(nil)
      removeLegacyCredentials()
    } catch { errorMessage = error.localizedDescription }
    credentialCloudOwner = nil
  }

  private func removeLegacyCredentials() {
    let stores = secureService == Self.credentialService ? [userDefaults, UserDefaults.standard] : [userDefaults]
    for defaults in stores {
      for key in [StorageKey.accessToken, StorageKey.refreshToken, StorageKey.userID, StorageKey.clientID,
                  StorageKey.userLogin, StorageKey.userDisplayName, StorageKey.profileImageURL, StorageKey.lastValidatedAt] {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
