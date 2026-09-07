//  SecretStore
//  Secrets live in the Keychain; the database holds only a reference.
//
//  Why the Keychain rather than a tightly-permissioned file: the 2023 vulnerability report's
//  threat model is a malicious NON-PRIVILEGED process running AS THE SAME USER. File
//  permissions do not stop that — any process running as you can read your files. A Keychain
//  item does better, and since the move below it does so categorically rather than by
//  prompting.
//
//  THE DATA PROTECTION KEYCHAIN, with a fallback. This used to say the opposite — that these
//  calls addressed the legacy keychain and that moving was future work — and the move has now
//  happened. `KeychainSecretStore` passes `kSecUseDataProtectionKeychain` and falls back to
//  the legacy store only when the entitlement that authorises it is absent.
//
//  What the move buys, and it is not marginal:
//
//    1. **Access is by code signature, not by an ACL.** A process outside the access group is
//       REFUSED — the item does not exist for it. The legacy keychain merely PROMPTS, and a
//       user who clicks Allow has granted access for good. Measured: `security
//       find-generic-password`, which has no entitlement, can read a legacy item and cannot
//       see a data protection one.
//    2. **`kSecAttrAccessible` is honoured.** It was ignored entirely on the legacy keychain,
//       so `ThisDeviceOnly` bought nothing and `login.keychain-db` went into a Time Machine
//       backup like any other file.
//    3. **A re-signed update reads silently**, because identity is team plus access group
//       rather than a per-binary code requirement that a rebuild invalidates.
//
//  What it costs, and why the fallback exists. `keychain-access-groups` is a RESTRICTED
//  entitlement: authorised only by an embedded provisioning profile, and only a bundle can
//  carry one. A release build has both. `swift build` and `Tools/dev-bundle.sh` have neither.
//  Claiming the entitlement without a profile is not a soft failure — the kernel kills the
//  process at launch — which is why `Packaging/sign-app.sh` refuses to sign without one, and
//  why the headless CLI ships inside its own nested bundle rather than loose in
//  `Contents/MacOS`.
//
//  No migration of existing items was done, deliberately: the two stores are separate, so
//  anything written before this lives in the legacy keychain and is simply not read any more.
//
//  See `.claude/docs/decisions.md` and `distribution-docs/signing.md`.

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

  /// Keychain-backed store, preferring the data protection keychain.
  ///
  /// Which store an item lands in is decided by `kSecUseDataProtectionKeychain` on every
  /// call. The two are separate backing stores: an item written to one is INVISIBLE to a
  /// query against the other, so this is not a flag that can be toggled per call site.
  ///
  /// **Why data protection.** Access is by code signature — an app outside the access group
  /// is refused outright, where the legacy keychain merely PROMPTS and a user who clicks
  /// Allow has granted access for good. `kSecAttrAccessible` is also honoured here and
  /// ignored there, so `ThisDeviceOnly` genuinely keeps the item out of a Time Machine
  /// backup rather than buying nothing.
  ///
  /// **Why the fallback.** The data protection keychain requires the
  /// `keychain-access-groups` entitlement, which is RESTRICTED — authorised only by an
  /// embedded provisioning profile, and only a bundle can carry one. A release build has
  /// both; `swift build` and `Tools/dev-bundle.sh` have neither, and every call there
  /// returns `errSecMissingEntitlement`. Falling back keeps development working.
  ///
  /// The fallback is deliberately LOUD. A silent downgrade to the weaker store is worse than
  /// either store on its own, because nothing would ever reveal which one is in use —
  /// `usingDataProtection` exists so the app can say so, and so a test can assert it.
  public struct KeychainSecretStore: SecretStore {

    private let service: String

    /// Set once, on the first call that discovers the entitlement is absent.
    ///
    /// `nonisolated(unsafe)` over a lock: the value is written at most once per process, from
    /// a check that is idempotent, and a benign double-write stores the same `false`.
    nonisolated(unsafe) private static var entitlementIsMissing = false

    public init(service: String = "app.bluebubbles.server") {
      self.service = service
    }

    /// Whether this process is actually using the data protection keychain.
    ///
    /// False means the entitlement was absent and secrets are in the legacy keychain — which
    /// is expected for a development build and a defect for a release one.
    public static var usingDataProtection: Bool { !entitlementIsMissing }

    private func query(_ key: String, dataProtection: Bool) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      // The access GROUP is deliberately not specified. The entitlement names exactly one,
      // so a new item lands in it by default — naming it here would hardcode a team
      // identifier in source and break the moment the entitlement changed.
      if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
      return query
    }

    /// Runs `body` against the data protection keychain, falling back to the legacy one when
    /// the entitlement is absent.
    ///
    /// The fallback triggers on `errSecMissingEntitlement` alone. Any other failure is a real
    /// failure and is returned as-is — quietly retrying a locked or refused keychain against a
    /// different store would turn one diagnosable error into two confusing ones.
    private func withStore(
      _ key: String, _ body: ([String: Any]) -> OSStatus
    ) -> OSStatus {
      if !Self.entitlementIsMissing {
        let status = body(query(key, dataProtection: true))
        guard status == errSecMissingEntitlement else { return status }
        Self.entitlementIsMissing = true
      }
      return body(query(key, dataProtection: false))
    }

    public func get(_ key: String) throws -> String? {
      var item: CFTypeRef?
      let status = withStore(key) { base in
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, &item)
      }
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
        // HONOURED now, where the legacy keychain ignored it — see the header. On the data
        // protection keychain `ThisDeviceOnly` genuinely excludes the item from a Time
        // Machine backup and from any sync.
        //
        // `AfterFirstUnlock`, not `WhenUnlocked`: `auto_lock_mac` means this server is
        // expected to keep running with the screen locked, and `WhenUnlocked` would make
        // every secret unreadable the moment it did.
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]

      var addStatus: OSStatus = errSecSuccess
      let status = withStore(key) { base in
        let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var insert = base
        insert.merge(attributes) { _, new in new }
        addStatus = SecItemAdd(insert as CFDictionary, nil)
        // Reported as the update's status so `withStore` can see a missing entitlement on
        // the insert path too — otherwise a first write would never trigger the fallback.
        return addStatus == errSecMissingEntitlement ? addStatus : updated
      }
      if status == errSecItemNotFound {
        guard addStatus == errSecSuccess else {
          throw SettingsError.keychainUnavailable(key: key, status: addStatus)
        }
      } else if status != errSecSuccess {
        throw SettingsError.keychainUnavailable(key: key, status: status)
      }
    }

    public func delete(_ key: String) throws {
      let status = withStore(key) { SecItemDelete($0 as CFDictionary) }
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
