import XCTest
@testable import Strozz

final class TwitchCloudAccountTests: XCTestCase {
  private func credential(owner: String = "owner", user: String = "user") -> TwitchCredential {
    .init(accessToken: "test-access", refreshToken: "test-refresh", userID: user,
      clientID: "test-client", login: "fixture", displayName: "Fixture", cloudOwner: owner)
  }

  func testAccountRejectsCrossOwnerAndCrossTwitchRewards() throws {
    let credential = credential()
    XCTAssertNoThrow(try TwitchCloudAccount(owner: "owner", credential: credential).validated())
    XCTAssertThrowsError(try TwitchCloudAccount(owner: "different", credential: credential).validated())
    let reward = TwitchWatchRewardsAPI.Credential(token: "test-reward", userID: "other", login: "other", expiresAt: nil)
    XCTAssertThrowsError(try TwitchCloudAccount(owner: "owner", credential: credential, rewards: reward).validated())
    XCTAssertThrowsError(try TwitchCloudAccount(owner: "owner", rewards: reward).validated())
    XCTAssertNoThrow(try TwitchCloudAccount(owner: "owner").validated())
  }

  func testRefreshReservationCannotBeReusedEvenAfterTimePasses() throws {
    let snapshot = TwitchCloudSnapshot(account: .init(owner: "owner", credential: credential()), version: Data())
    let reserved = try TwitchCloudRefresh.reserve(snapshot, id: UUID())
    XCTAssertThrowsError(try TwitchCloudRefresh.reserve(.init(account: reserved, version: Data()), id: UUID())) {
      XCTAssertEqual($0 as? TwitchSyncError, .refreshPending)
    }
  }

  func testPublicationPreservesRewardsAndRejectsChangedOwnerUserOrReservation() throws {
    let reward = TwitchWatchRewardsAPI.Credential(token: "test-reward", userID: "user", login: "fixture", expiresAt: nil)
    let id = UUID()
    let snapshot = TwitchCloudSnapshot(account: .init(owner: "owner", credential: credential(), rewards: reward,
                                                    refreshID: id), version: Data())
    var fresh = credential()
    fresh.accessToken = "next-access"
    fresh.refreshToken = "next-refresh"
    let pending = TwitchPendingPublication(owner: "owner", refreshID: id, credential: fresh)
    let result = try TwitchCloudRefresh.publication(pending, into: snapshot)
    XCTAssertEqual(result.rewards, reward)
    XCTAssertEqual(result.credential, fresh)
    XCTAssertNil(result.refreshID)
    XCTAssertNotEqual(result.revision, snapshot.account.revision)
    for changed in [
      TwitchCloudAccount(owner: "other", credential: credential(owner: "other"), refreshID: id),
      TwitchCloudAccount(owner: "owner", credential: credential(user: "other"), refreshID: id),
      TwitchCloudAccount(owner: "owner", credential: credential(), refreshID: UUID()),
      TwitchCloudAccount(owner: "owner")
    ] {
      XCTAssertThrowsError(try TwitchCloudRefresh.publication(pending, into: .init(account: changed, version: Data())))
    }
  }

  func testTwoDevicesCannotBothReserveTheSameSingleUseToken() async throws {
    let database = MemoryCloudDatabase(account: .init(owner: "owner", credential: credential()))
    let fetched = await database.fetch(owner: "owner")
    let snapshot = try XCTUnwrap(fetched)
    let first = try TwitchCloudRefresh.reserve(snapshot, id: UUID())
    let second = try TwitchCloudRefresh.reserve(snapshot, id: UUID())
    let wins = await withTaskGroup(of: Bool.self) { group in
      for candidate in [first, second] {
        group.addTask {
          do { _ = try await database.save(candidate, replacing: snapshot); return true }
          catch { return false }
        }
      }
      var count = 0
      for await won in group { if won { count += 1 } }
      return count
    }
    XCTAssertEqual(wins, 1)
  }

  func testSignOutTombstonePreventsPendingRefreshFromResurrectingAccount() async throws {
    let database = MemoryCloudDatabase(account: .init(owner: "owner", credential: credential()))
    let fetched = await database.fetch(owner: "owner")
    let original = try XCTUnwrap(fetched)
    let id = UUID()
    let reserved = try await database.save(TwitchCloudRefresh.reserve(original, id: id), replacing: original)
    let pending = TwitchPendingPublication(owner: "owner", refreshID: id, credential: credential())
    _ = try await database.save(.init(owner: "owner"), replacing: reserved)
    do {
      _ = try await database.save(TwitchCloudRefresh.publication(pending, into: reserved), replacing: reserved)
      XCTFail("An old refresh must not overwrite a completed sign-out")
    } catch { XCTAssertEqual(error as? TwitchSyncError, .conflict) }
    let result = await database.fetch(owner: "owner")
    XCTAssertNil(result?.account.credential)
  }

  func testPendingRotatedCredentialsSurviveRoundTripWithoutRepeatingExchange() throws {
    let id = UUID()
    let pending = TwitchPendingPublication(owner: "owner", refreshID: id, credential: credential())
    let decoded = try JSONDecoder().decode(TwitchPendingPublication.self, from: JSONEncoder().encode(pending))
    XCTAssertEqual(decoded.refreshID, id)
    XCTAssertEqual(decoded.credential, pending.credential)
    let snapshot = TwitchCloudSnapshot(account: .init(owner: "owner", credential: credential(), refreshID: id), version: Data())
    XCTAssertEqual(try TwitchCloudRefresh.publication(decoded, into: snapshot).credential, credential())
  }
}

private actor MemoryCloudDatabase: TwitchCloudDatabase {
  private var account: TwitchCloudAccount
  private var counter = 0
  init(account: TwitchCloudAccount) { self.account = account }
  func owner() -> String { account.owner }
  func fetch(owner: String) -> TwitchCloudSnapshot? {
    guard owner == account.owner else { return nil }
    return .init(account: account, version: Data(String(counter).utf8))
  }
  func save(_ updated: TwitchCloudAccount, replacing snapshot: TwitchCloudSnapshot?) throws -> TwitchCloudSnapshot {
    guard snapshot?.version == Data(String(counter).utf8) else { throw TwitchSyncError.conflict }
    account = try updated.validated()
    counter += 1
    return .init(account: account, version: Data(String(counter).utf8))
  }
}
