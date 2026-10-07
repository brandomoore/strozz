#if DEBUG
import CryptoKit
import Foundation
import OSLog

enum TwitchCloudProbe {
  static func runIfRequested() async {
    let environment = ProcessInfo.processInfo.environment
    guard let action = environment["STROZZ_ICLOUD_PROBE"],
      let id = environment["STROZZ_ICLOUD_PROBE_ID"], UUID(uuidString: id) != nil else { return }
    var result: [String: String] = ["action": action, "probe": id]
    do {
      let database = CloudKitTwitchDatabase(recordName: "probe-\(id)")
      let owner = try await database.owner()
      result["owner_hash"] = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
      if action == "write" {
        let old = try await database.fetch(owner: owner)
        guard old == nil else { throw TwitchSyncError.conflict }
        let credential = TwitchCredential(accessToken: "synthetic-probe", refreshToken: "synthetic-probe",
          userID: "synthetic-user", clientID: "synthetic-client", login: "probe", displayName: "Probe", cloudOwner: owner)
        _ = try await database.save(.init(owner: owner, credential: credential), replacing: nil)
      }
      guard let snapshot = try await database.fetch(owner: owner),
        snapshot.account.credential?.accessToken == "synthetic-probe" else { throw TwitchSyncError.invalidAccount }
      if action == "cleanup" {
        var updated = snapshot.account
        updated.revision = UUID()
        _ = try await database.save(updated, replacing: snapshot)
        do {
          _ = try await database.save(snapshot.account, replacing: snapshot)
          throw TwitchSyncError.invalidAccount
        } catch TwitchSyncError.conflict {
          result["compare_and_swap"] = "verified"
        }
      }
      let group = TopShelf.appGroupID
      let service = "com.thatcube.Strozz.probe.\(id)"
      try CredentialKeychain.write(Data(id.utf8), service: service, group: group)
      guard try CredentialKeychain.read(service: service, group: group) == Data(id.utf8) else {
        throw TwitchSyncError.invalidAccount
      }
      try CredentialKeychain.remove(service: service, group: group)
      if action == "cleanup" { try await database.removeProbe(owner: owner) }
      result["result"] = "success"
      result["shared_keychain"] = "verified"
    } catch {
      result["result"] = "failed"
      result["error_domain"] = (error as NSError).domain
      result["error_code"] = String((error as NSError).code)
      Logger(subsystem: "com.thatcube.Strozz", category: "icloud-probe").error("Probe failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
    }
    do {
      let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        .write(to: directory.appendingPathComponent("icloud-probe.json"), options: .atomic)
    } catch {
      Logger(subsystem: "com.thatcube.Strozz", category: "icloud-probe").error("Cannot save probe result")
    }
  }
}
#endif
