import Foundation

// HANDOFF/13 §14 — a stable, device-unique identifier for the recording lease.
//
// Unlike the E2E sync key (SyncCrypto), this id MUST NOT sync between devices —
// each Mac needs its own. It is stored ThisDeviceOnly and non-synchronizable in
// the data-protection keychain, surviving app reinstall but never propagating.
enum DeviceIdentity {
  private static let service = "so.dayflow.device"
  private static let account = "device-id-v1"

  /// Human-readable name for lease UI / logs (matches DayflowAuthManager's
  /// pattern). Not stable across hostname changes — used for display only.
  static var deviceName: String {
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
  }

  /// Stable per-device UUID, generated and persisted on first access.
  static var deviceID: String {
    if let existing = load() { return existing }
    let fresh = UUID().uuidString
    store(fresh)
    return fresh
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      // Explicitly NOT synchronizable: this id is per-device by design.
      kSecAttrSynchronizable as String: false,
    ]
  }

  private static func load() -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func store(_ id: String) {
    var query = baseQuery()
    query[kSecValueData as String] = Data(id.utf8)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(query as CFDictionary, nil)
  }
}
