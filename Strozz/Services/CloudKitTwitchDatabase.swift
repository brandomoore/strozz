import CloudKit
import Foundation

actor CloudKitTwitchDatabase: TwitchCloudDatabase {
  static let containerID = "iCloud.com.thatcube.Strozz"
  private let container = CKContainer(identifier: containerID)
  private let zoneID = CKRecordZone.ID(zoneName: "StrozzAccounts", ownerName: CKCurrentUserDefaultName)
  private let recordName: String

  init(recordName: String = "twitch") { self.recordName = recordName }

  func owner() async throws -> String {
    guard try await container.accountStatus() == .available else { throw TwitchSyncError.unavailable }
    return try await container.userRecordID().recordName
  }

  func fetch(owner expectedOwner: String) async throws -> TwitchCloudSnapshot? {
    try await checkOwner(expectedOwner)
    let database = container.privateCloudDatabase
    do {
      _ = try await database.recordZone(for: zoneID)
    } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
      _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }
    try await checkOwner(expectedOwner)
    do {
      let record = try await database.record(for: CKRecord.ID(recordName: recordName, zoneID: zoneID))
      try await checkOwner(expectedOwner)
      let snapshot = try decode(record)
      guard snapshot.account.owner == expectedOwner else { throw TwitchSyncError.accountChanged }
      return snapshot
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  func save(_ account: TwitchCloudAccount, replacing snapshot: TwitchCloudSnapshot?) async throws -> TwitchCloudSnapshot {
    try await checkOwner(account.owner)
    let validated = try account.validated()
    let record: CKRecord
    if let snapshot {
      guard snapshot.account.owner == account.owner else { throw TwitchSyncError.accountChanged }
      let decoder = try NSKeyedUnarchiver(forReadingFrom: snapshot.version)
      decoder.requiresSecureCoding = true
      defer { decoder.finishDecoding() }
      guard let decoded = CKRecord(coder: decoder) else { throw TwitchSyncError.invalidAccount }
      record = decoded
    } else {
      record = CKRecord(recordType: "TwitchAccount", recordID: .init(recordName: recordName, zoneID: zoneID))
    }
    record.encryptedValues["payload"] = try JSONEncoder().encode(validated) as NSData
    do {
      let result = try await container.privateCloudDatabase.modifyRecords(
        saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
      guard let saved = result.saveResults[record.recordID] else { throw TwitchSyncError.invalidAccount }
      let value = try saved.get()
      try await checkOwner(account.owner)
      return try decode(value)
    } catch let error as CKError where error.code == .serverRecordChanged {
      throw TwitchSyncError.conflict
    }
  }

  private func checkOwner(_ expected: String) async throws {
    try Task.checkCancellation()
    guard try await owner() == expected else { throw TwitchSyncError.accountChanged }
    try Task.checkCancellation()
  }

  #if DEBUG
  func removeProbe(owner: String) async throws {
    guard recordName.hasPrefix("probe-") else { throw TwitchSyncError.invalidAccount }
    try await checkOwner(owner)
    _ = try await container.privateCloudDatabase.deleteRecord(withID: .init(recordName: recordName, zoneID: zoneID))
  }
  #endif

  private func decode(_ record: CKRecord) throws -> TwitchCloudSnapshot {
    guard let data = record.encryptedValues["payload"] as? Data else { throw TwitchSyncError.invalidAccount }
    let account = try JSONDecoder().decode(TwitchCloudAccount.self, from: data).validated()
    let encoder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: encoder)
    encoder.finishEncoding()
    return TwitchCloudSnapshot(account: account, version: encoder.encodedData)
  }
}
