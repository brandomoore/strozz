import CloudKit
import Foundation
import OSLog

@MainActor
final class TwitchCloudRenewalDiagnostics {
  enum Stage: String, Codable, Sendable {
    case processStarted, reservationRequested, reservationSaved
    case applicationBackgrounded, applicationForegrounded
    case exchangeRequested, exchangeReceived, credentialsJournaled
    case publicationRequested, publicationSaved, renewalCompleted
    case pendingPublicationFound, pendingPublicationSuperseded, pendingPublicationCompleted
    case reservationObservedWithoutJournal, renewalFailed, syncFailed
    case freshSignInRequested, signInPublicationRequested, signInPublicationFailed, freshSignInPublished
  }

  struct Event: Codable {
    let date: Date
    let process: UUID
    let platform: String
    let build: String
    let stage: Stage
    let attempt: UUID?
    let failedStage: Stage?
    let errorKind: String?
    let errorCode: Int?
    let oauthReason: String?
  }

  static let capacity = 256
  #if os(tvOS)
  static let directory = URL.cachesDirectory.appendingPathComponent("AccountDiagnostics", isDirectory: true)
  #else
  static let directory = URL.applicationSupportDirectory.appendingPathComponent("AccountDiagnostics", isDirectory: true)
  #endif
  let file: URL
  private(set) var events: [Event] = []
  private let process = UUID()
  private static let logger = Logger(subsystem: "com.thatcube.Strozz", category: "account-renewal")

  init(directory: URL = TwitchCloudRenewalDiagnostics.directory) {
    file = directory.appendingPathComponent("renewal.json")
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 256 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: file)
        events = Array(try JSONDecoder().decode([Event].self, from: data).suffix(Self.capacity))
      }
    } catch {
      Self.logger.error("Cannot read renewal diagnostics: code=\((error as NSError).code)")
    }
    record(.processStarted)
  }

  func record(_ stage: Stage, attempt: UUID? = nil, failedStage: Stage? = nil, error: Error? = nil) {
    let failure = error.map(Self.failure)
    #if os(tvOS)
    let platform = "tvOS"
    #else
    let platform = "iOS"
    #endif
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    events.append(.init(date: Date(), process: process, platform: platform, build: "\(version) (\(build))",
      stage: stage, attempt: attempt, failedStage: failedStage, errorKind: failure?.kind, errorCode: failure?.code,
      oauthReason: Self.oauthReason(error)))
    events = Array(events.suffix(Self.capacity))
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(events).write(to: file, options: .atomic)
    } catch {
      Self.logger.error("Cannot persist renewal diagnostics: stage=\(stage.rawValue, privacy: .public) code=\((error as NSError).code)")
    }
    Self.logger.info("Renewal stage=\(stage.rawValue, privacy: .public) failure=\(failure?.kind ?? "none", privacy: .public) code=\(failure?.code ?? 0)")
  }

  // Never persist error descriptions, response bodies, URLs, tokens or account identifiers.
  private static func failure(_ error: Error) -> (kind: String, code: Int) {
    if error is CancellationError { return ("cancelled", 0) }
    if let error = error as? TwitchAuthHTTPError { return ("http", error.status) }
    if let error = error as? CKError { return ("cloudkit", error.code.rawValue) }
    if let error = error as? CredentialKeychain.StorageError { return ("keychain", Int(error.status)) }
    if let error = error as? URLError { return ("network", error.code.rawValue) }
    if error is TwitchSyncError { return ("sync", (error as NSError).code) }
    return ("other", (error as NSError).code)
  }

  private static func oauthReason(_ error: Error?) -> String? {
    guard let error = error as? TwitchAuthHTTPError else { return nil }
    switch error.message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "invalid refresh token", "invalid refresh token.", "invalid_grant": return "invalid_refresh"
    case "invalid client", "invalid client secret", "invalid_client": return "invalid_client"
    default: return nil
    }
  }
}
