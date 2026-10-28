import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class KickFollowingStore {
  private(set) var document: KickFollowDocument?
  private(set) var isBusy = false
  private(set) var hasLoaded = false
  private(set) var errorMessage: String?
  private(set) var cloudOwner: String?
  private var epoch = UUID()
  private var importer: Importer?
  private let database: any KickFollowingDatabase
  private let defaults: UserDefaults
  private static let cacheKey = "kickFollowing.cache.v1"
  private static let importerKey = "kickFollowing.importer.v1"
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "kick-following")

  private struct Cache: Codable { let owner: String; let document: KickFollowDocument }
  private struct Importer: Codable {
    let owner: String
    let connectionID: UUID
    let accountID: Int
  }

  init(database: any KickFollowingDatabase = CloudKitKickFollowingDatabase(), defaults: UserDefaults = .standard) {
    self.database = database
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.importerKey) {
      do { importer = try JSONDecoder().decode(Importer.self, from: data) }
      catch { report(error) }
    }
  }

  var isConnected: Bool { document?.account != nil }
  var isImporter: Bool {
    guard let importer, let document else { return false }
    return importer.owner == cloudOwner && importer.connectionID == document.connectionID
      && importer.accountID == document.account?.id
  }

  func accountChanged() {
    epoch = UUID()
    isBusy = false
    cloudOwner = nil
    document = nil
    hasLoaded = false
    importer = nil
    defaults.removeObject(forKey: Self.importerKey)
    defaults.removeObject(forKey: Self.cacheKey)
  }

  func synchronize() async {
    guard !isBusy else { return }
    isBusy = true
    let request = epoch
    defer { if epoch == request { isBusy = false; hasLoaded = true } }
    do {
      let owner = try await database.owner()
      guard current(request) else { return }
      if let cloudOwner, cloudOwner != owner {
        accountChanged()
        await synchronize()
        return
      }
      cloudOwner = owner
      if document == nil, let data = defaults.data(forKey: Self.cacheKey) {
        do {
          let cached = try JSONDecoder().decode(Cache.self, from: data)
          if cached.owner == owner { document = try cached.document.validated() }
        } catch {
          report(error)
          defaults.removeObject(forKey: Self.cacheKey)
        }
      }
      let snapshot = try await database.fetch(owner: owner)
      guard current(request) else { return }
      try apply(snapshot?.document, owner: owner)
      errorMessage = nil
    } catch {
      if current(request) { report(error) }
    }
  }

  func publish(_ imported: KickFollowImport, interactive: Bool) async throws {
    let request = try await beginOperation()
    defer { if epoch == request { isBusy = false } }
    do {
      let owner = try await database.owner()
      guard current(request), cloudOwner == nil || cloudOwner == owner else {
        throw KickFollowingError.accountChanged
      }
      let previous = try await database.fetch(owner: owner)
      guard current(request) else { throw CancellationError() }
      if !interactive {
        guard let importer, importer.owner == owner,
          importer.connectionID == previous?.document.connectionID,
          importer.accountID == imported.account.id,
          previous?.document.account?.id == imported.account.id else {
          throw KickFollowingError.accountChanged
        }
      } else if let account = previous?.document.account, account.id != imported.account.id {
        throw KickFollowingError.conflict
      }
      let existingConnection = previous.flatMap { $0.document.account == nil ? nil : $0.document.connectionID }
      let value = try KickFollowDocument(
        connectionID: existingConnection ?? UUID(),
        account: imported.account, follows: imported.follows, importedAt: Date()).validated()
      let saved = try await database.save(value, owner: owner, replacing: previous)
      guard current(request) else { throw CancellationError() }
      let binding = Importer(owner: owner, connectionID: saved.document.connectionID, accountID: imported.account.id)
      defaults.set(try JSONEncoder().encode(binding), forKey: Self.importerKey)
      importer = binding
      cloudOwner = owner
      try apply(saved.document, owner: owner)
      hasLoaded = true
      errorMessage = nil
    } catch {
      if current(request) { report(error) }
      throw error
    }
  }

  func disconnect() async throws {
    let request = try await beginOperation()
    defer { if epoch == request { isBusy = false } }
    do {
      let owner = try await database.owner()
      guard current(request), owner == cloudOwner else { throw KickFollowingError.accountChanged }
      let previous = try await database.fetch(owner: owner)
      guard current(request), previous?.document.connectionID == document?.connectionID else {
        throw KickFollowingError.conflict
      }
      let tombstone = KickFollowDocument(connectionID: UUID(), account: nil, follows: [], importedAt: Date())
      let saved = try await database.save(tombstone, owner: owner, replacing: previous)
      guard current(request) else { throw CancellationError() }
      try apply(saved.document, owner: owner)
      errorMessage = nil
    } catch {
      if current(request) { report(error) }
      throw error
    }
  }

  func report(_ error: Error) {
    guard !(error is CancellationError) else { return }
    errorMessage = error.localizedDescription
    Self.logger.error("Kick following failed: \((error as NSError).domain) \((error as NSError).code)")
  }

  private func current(_ request: UUID) -> Bool { epoch == request && !Task.isCancelled }

  private func beginOperation() async throws -> UUID {
    let request = epoch
    let deadline = Date().addingTimeInterval(30)
    while isBusy {
      guard Date() < deadline else { throw KickFollowingError.conflict }
      try await Task.sleep(for: .milliseconds(50))
      guard current(request) else { throw CancellationError() }
    }
    guard current(request) else { throw CancellationError() }
    isBusy = true
    return request
  }

  private func apply(_ value: KickFollowDocument?, owner: String) throws {
    document = value
    if let value {
      defaults.set(try JSONEncoder().encode(Cache(owner: owner, document: value)), forKey: Self.cacheKey)
    } else { defaults.removeObject(forKey: Self.cacheKey) }
    if !isImporter {
      importer = nil
      defaults.removeObject(forKey: Self.importerKey)
    }
  }
}
