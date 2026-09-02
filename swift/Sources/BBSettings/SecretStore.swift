//  SecretStore
//  Secrets live in the Keychain; the database holds only a reference.
//
//  Why the Keychain rather than a tightly-permissioned file: the 2023 vulnerability report's
//  threat model is a malicious NON-PRIVILEGED process running AS THE SAME USER. File
//  permissions do not stop that — any process running as you can read your files. A Keychain
//  item does better, though read the caveat below for how much better.
//
//  CAVEAT — this is the LEGACY keychain. These calls omit `kSecUseDataProtectionKeychain`,
//  so on macOS they address the file-based login keychain, not the data-protection keychain.
//  Two consequences, both easy to get wrong:
//
//    1. Access is gated by the item's ACL, NOT by a hard code-signing check. The ACL trusts
//       the binary that created the item, by code requirement; another process is PROMPTED
//       rather than refused, and a user who clicks Allow has granted it access for good. So
//       this raises the bar against a same-user attacker, but it is not a categorical
//       "denied rather than merely inconvenienced".
//    2. `kSecAttrAccessible` below is IGNORED. The legacy keychain has no accessibility
//       classes, so `ThisDeviceOnly` buys nothing and login.keychain-db is carried in a Time
//       Machine backup like any other file.
//
//  The data-protection keychain has neither problem — access is by code-signing access
//  group, with no ACL and no prompt, so a re-signed update reads silently and another app is
//  refused outright. Moving to it needs the app signed with `keychain-access-groups` (an
//  embedded provisioning profile) plus a one-time migration of existing items, and the
//  accessibility class then wants to be `AfterFirstUnlock`, not `WhenUnlocked`, because
//  `auto_lock_mac` means the server is expected to run with the screen locked.
//
//  See `.claude/docs/decisions.md`.

import Foundation

#if canImport(Security)
  import Security
#endif

public protocol SecretStore: Sendable {
  func get(_ key: String) throws -> String?
  func set(_ key: String, value: String) throws
  func delete(_ key: String) throws
}

/// A secret held in memory, kept out of ordinary Strings.
///
/// Swift Strings are copy-on-write and heap-allocated with no guarantee about when the
/// backing store is released, so a password read into one may persist in freed memory
/// indefinitely. This zeroes on deinit and only exposes its bytes through a closure.
public final class SecureString: @unchecked Sendable {

  private var bytes: [UInt8]

  public init(_ string: String) {
    bytes = Array(string.utf8)
  }

  public init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  deinit {
    // Overwrite before the allocation returns to the heap.
    for index in bytes.indices { bytes[index] = 0 }
  }

  public var isEmpty: Bool { bytes.isEmpty }
  public var count: Int { bytes.count }

  public func withUnsafeBytes<R>(_ body: ([UInt8]) throws -> R) rethrows -> R {
    try body(bytes)
  }

  /// Escape hatch for APIs that demand a String. Every use is a place where the value can
  /// leak into an unmanaged allocation, so they should be few and deliberate.
  public func unsafeStringValue() -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// Constant-time comparison.
  ///
  /// Replaces `safeTrim(password) !== safeTrim(token)`, which short-circuits on the first
  /// differing byte and so leaks the length of the matching prefix through timing.
  public func constantTimeEquals(_ candidate: String) -> Bool {
    let candidateBytes = Array(candidate.utf8)

    // Comparing lengths first would itself leak, so fold length into the difference and
    // always walk the longer of the two.
    var difference: UInt8 = bytes.count == candidateBytes.count ? 0 : 1
    let length = max(bytes.count, candidateBytes.count)
    guard length > 0 else { return difference == 0 }

    for index in 0..<length {
      let lhs = index < bytes.count ? bytes[index] : 0
      let rhs = index < candidateBytes.count ? candidateBytes[index] : 0
      difference |= lhs ^ rhs
    }
    return difference == 0
  }
}

#if canImport(Security)

  /// Keychain-backed store, with the item ACL trusting this application.
  public struct KeychainSecretStore: SecretStore {

    private let service: String

    public init(service: String = "app.bluebubbles.server") {
      self.service = service
    }

    private func query(_ key: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
    }

    public func get(_ key: String) throws -> String? {
      var query = query(key)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne

      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data else {
        throw SettingsError.keychainUnavailable(key: key, status: status)
      }
      return String(decoding: data, as: UTF8.self)
    }

    public func set(_ key: String, value: String) throws {
      guard let data = value.data(using: .utf8) else { return }

      let attributes: [String: Any] = [
        kSecValueData as String: data,
        // Ignored today — see the CAVEAT at the top of this file: without
        // `kSecUseDataProtectionKeychain` these items live in the legacy keychain, which
        // has no accessibility classes. Set so the intent survives, and so the move to
        // the data-protection keychain is a smaller change than it would otherwise be.
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]

      let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        var insert = query(key)
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
          throw SettingsError.keychainUnavailable(key: key, status: addStatus)
        }
      } else if status != errSecSuccess {
        throw SettingsError.keychainUnavailable(key: key, status: status)
      }
    }

    public func delete(_ key: String) throws {
      let status = SecItemDelete(query(key) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw SettingsError.keychainUnavailable(key: key, status: status)
      }
    }
  }

#endif

/// In-memory store for tests and for Linux CI, where Security is unavailable.
///
/// Never used in the shipping app: the composition root builds a `KeychainSecretStore`.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {

  private var storage: [String: String] = [:]
  private let lock = NSLock()

  public init(seed: [String: String] = [:]) {
    storage = seed
  }

  public func get(_ key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return storage[key]
  }

  public func set(_ key: String, value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[key] = value
  }

  public func delete(_ key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    storage[key] = nil
  }
}
