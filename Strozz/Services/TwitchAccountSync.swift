import CloudKit
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class TwitchAccountSync {
  private(set) var isBusy = false
  private(set) var status = "Checking iCloud..."
  private(set) var errorMessage: String?
  private(set) var isSignedOutLocally: Bool
  private(set) var hasAccountConflict = false
  private(set) var hasCompletedInitialSync = false
  @ObservationIgnored private let database: any TwitchCloudDatabase
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private weak var auth: TwitchAuthSession?
  @ObservationIgnored private weak var rewards: TwitchWatchRewardsSession?
  @ObservationIgnored private var rewardsDirty = false
  @ObservationIgnored private var rewardChange: TwitchRewardsChange?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var initialSync: Task<Void, Never>?
  @ObservationIgnored private var accountObserver: NSObjectProtocol?
  @ObservationIgnored private let pendingService: String
  @ObservationIgnored private let rewardsChangeService: String
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "account-sync")

  init(database: any TwitchCloudDatabase = CloudKitTwitchDatabase(), defaults: UserDefaults = .standard,
       storagePrefix: String = "com.thatcube.Strozz") {
    self.database = database
    self.defaults = defaults
    pendingService = "\(storagePrefix).pending-token-publication"
    rewardsChangeService = "\(storagePrefix).pending-rewards-change"
    isSignedOutLocally = defaults.bool(forKey: PersistenceKey.icloudAccountSignedOut)
    do {
      if let data = try CredentialKeychain.read(service: rewardsChangeService) {
        rewardChange = try JSONDecoder().decode(TwitchRewardsChange.self, from: data)
        rewardsDirty = true
      }
    } catch { report(error) }
  }

  func start(auth: TwitchAuthSession, rewards: TwitchWatchRewardsSession) async {
    if let initialSync {
      await initialSync.value
      return
    }
    self.auth = auth
    self.rewards = rewards
    auth.cloudSync = self
    auth.restore()
    rewards.onCredentialChange = { [weak self] in
      guard let self, let userID = self.auth?.userID else { return }
      let change = TwitchRewardsChange(owner: self.auth?.credentialCloudOwner, userID: userID,
                                      credential: self.rewards?.credential)
      do {
        try CredentialKeychain.write(JSONEncoder().encode(change), service: self.rewardsChangeService)
        self.rewardChange = change
        self.rewardsDirty = true
        Task { await self.synchronize() }
      } catch { self.report(error) }
    }
    accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.auth?.clearStoredAuthState()
        self.rewards?.clearLocalConnection()
        self.status = "Apple Account changed. Checking iCloud..."
        await self.synchronize()
      }
    }
    let startup = Task { [weak self] in
      guard let self else { return }
      await self.synchronize()
      guard !Task.isCancelled else { return }
      self.hasCompletedInitialSync = true
      auth.startSessionValidation()
    }
    initialSync = startup
    await startup.value
    guard !startup.isCancelled, loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        await self?.synchronize()
      }
    }
  }

  var shouldOfferInitialSignIn: Bool {
    hasCompletedInitialSync && !isBusy && !isSignedOutLocally
      && errorMessage == nil && !hasAccountConflict && auth?.isAuthenticated == false
  }

  /// A user-selected Sign in first adopts a saved connection. Automatic sync
  /// never clears the local sign-out choice or replaces a different account.
  func restoreBeforeSignIn() async -> Bool {
    if let initialSync { await initialSync.value }
    guard !Task.isCancelled else { return false }
    if auth?.isAuthenticated == true { return false }
    guard !isBusy, auth != nil else { report(TwitchSyncError.busy); return false }
    isSignedOutLocally = false
    defaults.set(false, forKey: PersistenceKey.icloudAccountSignedOut)
    await synchronize()
    return !Task.isCancelled && auth?.isAuthenticated == false
      && errorMessage == nil && !hasAccountConflict
  }

  func stop() {
    initialSync?.cancel()
    loop?.cancel()
    initialSync = nil
    loop = nil
    if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    accountObserver = nil
    hasCompletedInitialSync = false
  }

  func signedOutLocally() {
    isSignedOutLocally = true
    defaults.set(true, forKey: PersistenceKey.icloudAccountSignedOut)
    rewards?.clearLocalConnection()
    clearRewardChange()
    status = "Signed out on this device"
    errorMessage = nil
  }

  func useICloudAccount() async {
    guard !isBusy else { return }
    auth?.cancelSignIn()
    isSignedOutLocally = false
    status = "Checking iCloud..."
    defaults.set(false, forKey: PersistenceKey.icloudAccountSignedOut)
    await synchronize(preferCloud: true)
  }

  func signedIn(_ credential: TwitchCredential) async {
    isSignedOutLocally = false
    defaults.set(false, forKey: PersistenceKey.icloudAccountSignedOut)
    await publishSignIn(credential, replacingAccount: false)
  }

  func replaceICloudAccount() async {
    guard let credential = auth?.storedCredential else { return }
    await publishSignIn(credential, replacingAccount: true)
  }

  private func publishSignIn(_ credential: TwitchCredential, replacingAccount: Bool) async {
    guard !isBusy, let auth, auth.refreshInFlight == nil else { report(TwitchSyncError.busy); return }
    isBusy = true
    defer { isBusy = false }
    let generation = auth.sessionGeneration
    do {
      let owner = try await database.owner()
      let snapshot = try await database.fetch(owner: owner)
      try check(generation)
      rewards?.accountChanged(to: credential.userID)
      if let existing = snapshot?.account.credential, existing.userID != credential.userID, !replacingAccount {
        throw TwitchSyncError.accountConflict
      }
      var shared = credential
      if let localOwner = shared.cloudOwner, localOwner != owner { throw TwitchSyncError.accountChanged }
      shared.cloudOwner = owner
      let reward = rewards?.credential.flatMap { $0.userID == shared.userID ? $0 : nil }
        ?? snapshot?.account.rewards.flatMap { $0.userID == shared.userID && !rewardsDirty ? $0 : nil }
      let account = TwitchCloudAccount(owner: owner, credential: shared, rewards: reward)
      // Bind before publishing: an ambiguous save response must not leave a
      // locally refreshable token that another device can also spend.
      try auth.useCredential(shared)
      _ = try await database.save(account, replacing: snapshot)
      try check(generation)
      try auth.useCredential(shared)
      try CredentialKeychain.remove(service: pendingService)
      clearRewardChange()
      succeeded()
    } catch is CancellationError {
      return
    } catch { report(error) }
  }

  func synchronize(preferCloud: Bool = false) async {
    guard !isSignedOutLocally, !isBusy, let auth, !auth.isAuthenticating, auth.refreshInFlight == nil else { return }
    isBusy = true
    defer { isBusy = false }
    let generation = auth.sessionGeneration
    do {
      let owner = try await database.owner()
      if let localOwner = auth.credentialCloudOwner, localOwner != owner {
        auth.clearStoredAuthState()
        rewards?.clearLocalConnection()
        throw TwitchSyncError.accountChanged
      }
      var snapshot = try await finishPending(owner: owner)
      try check(generation)
      if snapshot == nil {
        if var local = auth.storedCredential {
          guard local.cloudOwner == nil else {
            auth.isAuthenticated = false
            try auth.saveTopShelf(nil)
            throw TwitchSyncError.invalidAccount
          }
          local.cloudOwner = owner
          let reward = rewards?.credential.flatMap { $0.userID == local.userID ? $0 : nil }
          try auth.useCredential(local)
          snapshot = try await database.save(.init(owner: owner, credential: local, rewards: reward), replacing: nil)
          try check(generation)
          try auth.useCredential(local)
        } else {
          status = "Sign in once to connect your devices"
          errorMessage = nil
          return
        }
      }
      guard var snapshot else { throw TwitchSyncError.invalidAccount }
      guard var credential = snapshot.account.credential else {
        if auth.storedCredential != nil { auth.clearStoredAuthState() }
        rewards?.clearLocalConnection()
        status = "Signed out in iCloud"
        errorMessage = nil
        return
      }
      if let local = auth.storedCredential, local.userID != credential.userID, !preferCloud {
        throw TwitchSyncError.accountConflict
      }
      if auth.storedCredential != credential || !auth.isAuthenticated {
        do {
          try await auth.validateSyncedCredential(credential)
        } catch let error as TwitchAuthHTTPError where error.status == 401 {
          credential = try await rotate(snapshot: snapshot, generation: generation)
          guard let updated = try await database.fetch(owner: owner) else { throw TwitchSyncError.conflict }
          snapshot = updated
        }
        try check(generation)
        rewards?.accountChanged(to: credential.userID)
        try auth.useCredential(credential)
        auth.startSessionValidation()
      }
      if rewardsDirty {
        guard snapshot.account.refreshID == nil else { throw TwitchSyncError.refreshPending }
        if let change = rewardChange, change.userID == credential.userID,
          change.owner == nil || change.owner == owner {
          var updated = snapshot.account
          updated.rewards = change.credential
          updated.revision = UUID()
          snapshot = try await database.save(updated, replacing: snapshot)
          try check(generation)
        }
        clearRewardChange()
      }
      if let rewards, !rewards.isConnecting {
        try await rewards.importSyncedCredential(snapshot.account.rewards, expectedUserID: credential.userID)
        try check(generation)
      }
      if snapshot.account.refreshID != nil { throw TwitchSyncError.refreshPending }
      succeeded()
    } catch is CancellationError {
      return
    } catch { report(error) }
  }

  func renew(rejectedAccessToken: String?) async throws -> String {
    guard !isBusy, !isSignedOutLocally, let auth, let local = auth.storedCredential,
      let owner = local.cloudOwner else { throw TwitchSyncError.busy }
    isBusy = true
    defer { isBusy = false }
    let generation = auth.sessionGeneration
    do {
      guard try await database.owner() == owner else { throw TwitchSyncError.accountChanged }
      guard let snapshot = try await finishPending(owner: owner),
        let shared = snapshot.account.credential, shared.userID == local.userID,
        shared.clientID == local.clientID else { throw TwitchSyncError.invalidAccount }
      try check(generation)
      if shared.accessToken != (rejectedAccessToken ?? local.accessToken) {
        try auth.useCredential(shared)
        succeeded()
        return shared.accessToken
      }
      let updated = try await rotate(snapshot: snapshot, generation: generation)
      try check(generation)
      try auth.useCredential(updated)
      succeeded()
      return updated.accessToken
    } catch {
      report(error)
      throw error
    }
  }

  private func rotate(snapshot: TwitchCloudSnapshot, generation: UUID) async throws -> TwitchCredential {
    guard let auth else { throw CancellationError() }
    try check(generation)
    let id = UUID()
    let reserved = try await database.save(TwitchCloudRefresh.reserve(snapshot, id: id), replacing: snapshot)
    try check(generation)
    guard let previous = reserved.account.credential else { throw TwitchSyncError.invalidAccount }
    // A failed/ambiguous exchange deliberately leaves the reservation in place.
    // A second device must never guess that the single-use token is unspent.
    let fresh = try await auth.refreshSyncedCredential(previous)
    let pending = TwitchPendingPublication(owner: reserved.account.owner, refreshID: id, credential: fresh)
    try CredentialKeychain.write(JSONEncoder().encode(pending), service: pendingService)
    guard try await database.owner() == pending.owner else { throw TwitchSyncError.accountChanged }
    let latest = try await database.fetch(owner: pending.owner)
    guard let latest else { throw TwitchSyncError.conflict }
    _ = try await database.save(TwitchCloudRefresh.publication(pending, into: latest), replacing: latest)
    try CredentialKeychain.remove(service: pendingService)
    try check(generation)
    return fresh
  }

  private func finishPending(owner: String) async throws -> TwitchCloudSnapshot? {
    let snapshot = try await database.fetch(owner: owner)
    guard let data = try CredentialKeychain.read(service: pendingService) else { return snapshot }
    let pending = try JSONDecoder().decode(TwitchPendingPublication.self, from: data)
    guard pending.owner == owner else {
      try CredentialKeychain.remove(service: pendingService)
      throw TwitchSyncError.accountChanged
    }
    guard let snapshot, snapshot.account.refreshID == pending.refreshID else {
      try CredentialKeychain.remove(service: pendingService)
      return snapshot
    }
    let saved = try await database.save(TwitchCloudRefresh.publication(pending, into: snapshot), replacing: snapshot)
    try CredentialKeychain.remove(service: pendingService)
    return saved
  }

  func signOutAllDevices() async {
    guard !isBusy, let auth else { report(TwitchSyncError.busy); return }
    isBusy = true
    defer { isBusy = false }
    let generation = auth.sessionGeneration
    do {
      let owner = try await database.owner()
      let snapshot = try await database.fetch(owner: owner)
      try Task.checkCancellation()
      guard auth.sessionGeneration == generation else { throw CancellationError() }
      _ = try await database.save(.init(owner: owner), replacing: snapshot)
      try Task.checkCancellation()
      guard auth.sessionGeneration == generation else { throw CancellationError() }
      try CredentialKeychain.remove(service: pendingService)
      auth.signOut()
      status = "Signed out everywhere"
    } catch { report(error) }
  }

  private func check(_ generation: UUID) throws {
    try Task.checkCancellation()
    guard !isSignedOutLocally, auth?.sessionGeneration == generation else { throw CancellationError() }
  }

  private func succeeded() {
    status = "Connected through iCloud"
    errorMessage = nil
    hasAccountConflict = false
  }

  private func clearRewardChange() {
    do {
      try CredentialKeychain.remove(service: rewardsChangeService)
      rewardsDirty = false
      rewardChange = nil
    } catch { report(error) }
  }

  private func report(_ error: Error) {
    if error is CancellationError { return }
    status = isSignedOutLocally ? "Signed out on this device" : "Connection needs attention"
    hasAccountConflict = error as? TwitchSyncError == .accountConflict
    if let error = error as? TwitchSyncError { errorMessage = error.localizedDescription }
    else if error is CredentialKeychain.StorageError { errorMessage = error.localizedDescription }
    else { errorMessage = "iCloud account sync is unavailable right now. Retry when you are online." }
    Self.logger.error("Account sync failed: \((error as NSError).domain, privacy: .public) code=\((error as NSError).code)")
  }
}
