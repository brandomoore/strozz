import CloudKit
import Foundation

struct KickCloudSnapshot: Sendable {
  let document: KickFollowDocument
  let version: Data
}

protocol KickFollowingDatabase: Sendable {
  func owner() async throws -> String
  func fetch(owner: String) async throws -> KickCloudSnapshot?
  func save(_ document: KickFollowDocument, owner: String, replacing: KickCloudSnapshot?) async throws -> KickCloudSnapshot
}

actor CloudKitKickFollowingDatabase: KickFollowingDatabase {
  private let container = CKContainer(identifier: "iCloud.com.thatcube.Strozz")
  private let zoneID = CKRecordZone.ID(zoneName: "StrozzAccounts", ownerName: CKCurrentUserDefaultName)

  func owner() async throws -> String {
    guard try await container.accountStatus() == .available else { throw KickFollowingError.unavailable }
    return try await container.userRecordID().recordName
  }

  func fetch(owner expected: String) async throws -> KickCloudSnapshot? {
    try await checkOwner(expected)
    let database = container.privateCloudDatabase
    do {
      _ = try await database.recordZone(for: zoneID)
    } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
      _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }
    try await checkOwner(expected)
    do {
      let record = try await database.record(for: .init(recordName: "kick-follows", zoneID: zoneID))
      try await checkOwner(expected)
      return try decode(record)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  func save(_ document: KickFollowDocument, owner: String, replacing: KickCloudSnapshot?) async throws -> KickCloudSnapshot {
    try await checkOwner(owner)
    let document = try document.validated()
    let record: CKRecord
    if let replacing {
      let decoder = try NSKeyedUnarchiver(forReadingFrom: replacing.version)
      decoder.requiresSecureCoding = true
      defer { decoder.finishDecoding() }
      guard let decoded = CKRecord(coder: decoder) else { throw KickFollowingError.invalidResponse }
      record = decoded
    } else {
      record = CKRecord(recordType: "KickFollowing", recordID: .init(recordName: "kick-follows", zoneID: zoneID))
    }
    record.encryptedValues["payload"] = try JSONEncoder().encode(document) as NSData
    do {
      let result = try await container.privateCloudDatabase.modifyRecords(
        saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
      guard let saved = result.saveResults[record.recordID] else { throw KickFollowingError.invalidResponse }
      let value = try saved.get()
      try await checkOwner(owner)
      return try decode(value)
    } catch let error as CKError where error.code == .serverRecordChanged {
      throw KickFollowingError.conflict
    }
  }

  private func checkOwner(_ expected: String) async throws {
    try Task.checkCancellation()
    guard try await owner() == expected else { throw KickFollowingError.accountChanged }
    try Task.checkCancellation()
  }

  private func decode(_ record: CKRecord) throws -> KickCloudSnapshot {
    guard let data = record.encryptedValues["payload"] as? Data, data.count <= 900_000 else {
      throw KickFollowingError.invalidResponse
    }
    let document = try JSONDecoder().decode(KickFollowDocument.self, from: data).validated()
    let encoder = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: encoder)
    encoder.finishEncoding()
    return KickCloudSnapshot(document: document, version: encoder.encodedData)
  }
}
