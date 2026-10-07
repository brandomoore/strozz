import Foundation
import Security

enum CredentialKeychain {
  struct StorageError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Secure credential storage is unavailable (\(status))." }
  }

  static func read(service: String, group: String? = nil) throws -> Data? {
    var query = query(service: service, group: group)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw StorageError(status: status) }
    return data
  }

  static func write(_ data: Data, service: String, group: String? = nil) throws {
    let query = query(service: service, group: group)
    let attributes: [CFString: Any] = [
      kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard result == errSecSuccess else { throw StorageError(status: result) }
    } else if status != errSecSuccess { throw StorageError(status: status) }
  }

  static func remove(service: String, group: String? = nil) throws {
    let status = SecItemDelete(query(service: service, group: group) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError(status: status) }
  }

  private static func query(service: String, group: String?) -> [CFString: Any] {
    var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: "account", kSecAttrSynchronizable: false]
    if let group { query[kSecAttrAccessGroup] = group }
    return query
  }
}
