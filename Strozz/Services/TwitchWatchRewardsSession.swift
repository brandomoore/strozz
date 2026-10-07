import Foundation
import Observation
import OSLog
import Security

@MainActor
@Observable
final class TwitchWatchRewardsSession {
  private(set) var credential: TwitchWatchRewardsAPI.Credential?
  private(set) var deviceCode: TwitchWatchRewardsAPI.DeviceCode?
  private(set) var isConnecting = false
  private(set) var errorMessage: String?
  var isConnected: Bool { credential != nil }
  var autoClaimBonuses: Bool {
    didSet { preferences.set(autoClaimBonuses, forKey: PersistenceKey.autoClaimWatchBonuses) }
  }

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var validatedAt: Date?
  @ObservationIgnored private let api: TwitchWatchRewardsAPI
  @ObservationIgnored private let store: TwitchWatchRewardsStore
  @ObservationIgnored private let preferences: UserDefaults
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "WatchRewards")

  init(
    api: TwitchWatchRewardsAPI = TwitchWatchRewardsAPI(),
    store: TwitchWatchRewardsStore = .keychain,
    preferences: UserDefaults = .standard
  ) {
    self.api = api
    self.store = store
    self.preferences = preferences
    autoClaimBonuses = preferences.object(forKey: PersistenceKey.autoClaimWatchBonuses) as? Bool ?? true
    do {
      if let data = try store.read() {
        credential = try JSONDecoder().decode(TwitchWatchRewardsAPI.Credential.self, from: data)
      }
    } catch {
      report(error)
    }
  }

  func connect(expectedUserID: String) async {
    guard !isConnecting else { return }
    guard !expectedUserID.isEmpty else {
      report(TwitchWatchRewardsAPI.Failure.accountMismatch)
      return
    }
    generation = UUID()
    let attempt = generation
    isConnecting = true
    errorMessage = nil
    deviceCode = nil
    defer {
      if generation == attempt {
        isConnecting = false
        deviceCode = nil
      }
    }
    do {
      let code = try await api.deviceCode()
      try check(attempt)
      deviceCode = code
      let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
      var interval = max(2, code.interval)
      while Date() < deadline {
        try await Task.sleep(for: .seconds(interval))
        try check(attempt)
        let token: String
        do {
          token = try await api.exchange(code.device_code)
        } catch TwitchWatchRewardsAPI.Failure.authorizationPending {
          continue
        } catch TwitchWatchRewardsAPI.Failure.slowDown {
          interval += 5
          continue
        }
        let credential = try await api.validate(token, expectedUserID: expectedUserID)
        try check(attempt)
        try store.write(JSONEncoder().encode(credential))
        self.credential = credential
        validatedAt = Date()
        Self.logger.info("Watch rewards account connected")
        return
      }
      throw TwitchWatchRewardsAPI.Failure.expiredCode
    } catch is CancellationError {
      return
    } catch {
      guard generation == attempt else { return }
      report(error)
    }
  }

  func cancelConnection() {
    generation = UUID()
    isConnecting = false
    deviceCode = nil
  }

  func disconnect() {
    cancelConnection()
    credential = nil
    validatedAt = nil
    errorMessage = nil
    do { try store.remove() }
    catch { report(error) }
  }

  func accountChanged(to userID: String?) {
    cancelConnection()
    if let credential, credential.userID != userID { disconnect() }
  }

  func validatedCredential(expectedUserID: String) async throws -> TwitchWatchRewardsAPI.Credential {
    guard let saved = credential else { throw TwitchWatchRewardsAPI.Failure.unauthorized }
    guard saved.userID == expectedUserID else { throw TwitchWatchRewardsAPI.Failure.accountMismatch }
    if let expiresAt = saved.expiresAt, expiresAt <= Date() {
      invalidate()
      throw TwitchWatchRewardsAPI.Failure.unauthorized
    }
    if let validatedAt, Date().timeIntervalSince(validatedAt) < 3600 { return saved }
    let attempt = generation
    do {
      let validated = try await api.validate(saved.token, expectedUserID: expectedUserID)
      try check(attempt)
      guard credential == saved else { throw CancellationError() }
      credential = validated
      validatedAt = Date()
      return validated
    } catch TwitchWatchRewardsAPI.Failure.unauthorized {
      if generation == attempt { invalidate() }
      throw TwitchWatchRewardsAPI.Failure.unauthorized
    }
  }

  func invalidate() {
    disconnect()
    if errorMessage == nil { report(TwitchWatchRewardsAPI.Failure.unauthorized) }
  }

  private func check(_ attempt: UUID) throws {
    try Task.checkCancellation()
    guard generation == attempt else { throw CancellationError() }
  }

  private func report(_ error: Error) {
    if isConnecting, error as? TwitchWatchRewardsAPI.Failure == .unauthorized {
      errorMessage = String(localized: "Twitch did not accept this rewards sign-in. Choose Try Again to request a new code.")
    } else {
      errorMessage = error.localizedDescription
    }
    Self.logger.error("Watch rewards error: \(self.errorMessage ?? "", privacy: .public)")
  }
}

/// A separate, non-synchronizing Keychain item; never shared with Top Shelf or UserDefaults.
@MainActor
struct TwitchWatchRewardsStore {
  static let keychainService = "com.thatcube.Strozz.watch-rewards"
  let read: () throws -> Data?
  let write: (Data) throws -> Void
  let remove: () throws -> Void

  static let keychain = TwitchWatchRewardsStore(
    read: {
      var query = keychainQuery
      query[kSecReturnData] = true
      query[kSecMatchLimit] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = result as? Data else {
        throw TwitchWatchRewardsAPI.Failure.secureStorage(Int(status))
      }
      return data
    },
    write: { data in
      let attributes: [CFString: Any] = [
        kSecValueData: data,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        let add = keychainQuery.merging(attributes) { _, new in new }
        let result = SecItemAdd(add as CFDictionary, nil)
        guard result == errSecSuccess else {
          throw TwitchWatchRewardsAPI.Failure.secureStorage(Int(result))
        }
      } else if status != errSecSuccess {
        throw TwitchWatchRewardsAPI.Failure.secureStorage(Int(status))
      }
    },
    remove: {
      let status = SecItemDelete(keychainQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw TwitchWatchRewardsAPI.Failure.secureStorage(Int(status))
      }
    }
  )

  private static var keychainQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: keychainService,
      kSecAttrAccount: "twitch-session",
      kSecAttrSynchronizable: false,
    ]
  }
}
