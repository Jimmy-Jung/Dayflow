import CryptoKit
import Foundation
import os

// HANDOFF/13 §15 — end-to-end encryption for synced text.
//
// Sensitive card text (title / summary / detailed_summary / metadata) is
// encrypted on-device with AES-GCM before it ever reaches CloudKit, so neither
// Apple nor Dayflow can read it. The symmetric key lives in the iCloud Keychain
// (`kSecAttrSynchronizable`), so it propagates only between the user's own
// devices through Apple's end-to-end-encrypted keychain — never through the
// CloudKit record payload or any Dayflow server.
//
// Time-range / category / day columns are intentionally left in plaintext
// (RecordMapper) because the sync engine needs them for dedup, ordering, and
// filtering. Losing the key (all devices signed out) means cloud copies can't
// be decrypted, but the local originals survive — recovery is a re-upload.

enum SyncCryptoError: Error {
  case keyUnavailable
  case decryptionFailed
}

final class SyncCrypto: @unchecked Sendable {
  static let shared = SyncCrypto()

  private let service = "so.dayflow.sync.e2e"
  private let account = "field-key-v1"
  private let log = Logger(subsystem: "so.dayflow", category: "SyncCrypto")

  private let lock = NSLock()
  private var cachedKey: SymmetricKey?

  private init() {}

  // MARK: - Field encryption

  /// Encrypt a string field for storage in a CKRecord. `nil` passes through
  /// (absent field stays absent). Returns the AES-GCM combined box (nonce +
  /// ciphertext + tag).
  func encrypt(_ plaintext: String?) throws -> Data? {
    guard let plaintext else { return nil }
    let key = try symmetricKey()
    let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
    guard let combined = sealed.combined else { throw SyncCryptoError.decryptionFailed }
    return combined
  }

  /// Decrypt a CKRecord field back to its string. `nil` passes through.
  func decrypt(_ data: Data?) throws -> String? {
    guard let data else { return nil }
    let key = try symmetricKey()
    let box = try AES.GCM.SealedBox(combined: data)
    let opened = try AES.GCM.open(box, using: key)
    guard let string = String(data: opened, encoding: .utf8) else {
      throw SyncCryptoError.decryptionFailed
    }
    return string
  }

  // MARK: - Key management (iCloud Keychain, synchronizable)

  /// Returns the E2E key, generating and persisting it on first use. The key is
  /// shared across the user's devices via the iCloud Keychain.
  func symmetricKey() throws -> SymmetricKey {
    lock.lock()
    defer { lock.unlock() }
    if let cachedKey { return cachedKey }
    if let existing = try loadKey() {
      cachedKey = existing
      return existing
    }
    let fresh = SymmetricKey(size: .bits256)
    try storeKey(fresh)
    cachedKey = fresh
    log.info("Generated new E2E sync key")
    return fresh
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      // Critical on macOS: use the data-protection keychain so synchronizable +
      // accessibility behave like iOS (axiom-security keychain guidance).
      kSecUseDataProtectionKeychain as String: true,
      // Sync the key across the user's devices through iCloud Keychain.
      kSecAttrSynchronizable as String: true,
    ]
  }

  private func loadKey() throws -> SymmetricKey? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      // Never delete on errSecInteractionNotAllowed — the item is fine, the
      // device is just locked (axiom-security background-execution trap).
      throw SyncCryptoError.keyUnavailable
    }
    return SymmetricKey(data: data)
  }

  private func storeKey(_ key: SymmetricKey) throws {
    let data = key.withUnsafeBytes { Data($0) }
    var query = baseQuery()
    query[kSecValueData as String] = data
    // Available after first unlock so background sync can read it; NOT
    // ThisDeviceOnly, which would block iCloud Keychain propagation.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw SyncCryptoError.keyUnavailable
    }
  }
}
