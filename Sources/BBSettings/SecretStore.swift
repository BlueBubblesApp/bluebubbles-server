//  SecretStore
//  Secrets live in the Keychain; the database holds only a reference.
//
//  Why the Keychain rather than a tightly-permissioned file: the 2023 vulnerability report's
//  threat model is a malicious NON-PRIVILEGED process running AS THE SAME USER. File
//  permissions do not stop that: any process running as you can read your files. A Keychain
//  item does better, and since the move below it does so categorically rather than by
//  prompting.
//
//  THE DATA PROTECTION KEYCHAIN, with a fallback. `KeychainSecretStore` passes
//  `kSecUseDataProtectionKeychain` and falls back to the legacy store only when the
//  entitlement that authorises it is absent.
//
//  What the data protection keychain buys, and it is not marginal:
//
//    1. **Access is by code signature, not by an ACL.** A process outside the access group is
//       REFUSED: the item does not exist for it. The legacy keychain merely PROMPTS, and a
//       user who clicks Allow has granted access for good. Measured: `security
//       find-generic-password`, which has no entitlement, can read a legacy item and cannot
//       see a data protection one.
//    2. **`kSecAttrAccessible` is honoured.** The legacy keychain ignores it entirely, so
//       there `ThisDeviceOnly` buys nothing and `login.keychain-db` goes into a Time Machine
//       backup like any other file.
//    3. **A re-signed update reads silently**, because identity is team plus access group
//       rather than a per-binary code requirement that a rebuild invalidates.
//
//  What it costs, and why the fallback exists. `keychain-access-groups` is a RESTRICTED
//  entitlement: authorised only by an embedded provisioning profile, and only a bundle can
//  carry one. A release build has both; `swift build` and an ad-hoc dev bundle have neither.
//  Claiming the entitlement without a profile is not a soft failure: the kernel kills the
//  process at launch, which is why `Packaging/sign-app.sh` refuses to sign without one, and
//  why the headless CLI ships inside its own nested bundle rather than loose in
//  `Contents/MacOS`.
//
//  The two stores are separate and nothing moves items between them: an item a build without
//  the entitlement wrote to the legacy keychain is simply not read by one that has it — with
//  ONE deliberate exception, added because assuming the fallback was symmetric cost a
//  password: a LOOKUP that finds nothing in the data protection keychain also looks in the
//  legacy one. An unentitled build gets `errSecMissingEntitlement` from a WRITE and
//  `errSecItemNotFound` from a READ, so a `get` that only fell back on the former never
//  looked in the store its own `set` had just written to. See `withStore`.
//
//  See `.claude/docs/decisions.md` and `distribution-docs/signing.md`.

import BBCore
import Foundation

#if canImport(Security)
  import Security
#endif

public protocol SecretStore: Sendable {
  func get(_ key: String) throws -> String?
  func set(_ key: String, value: String) throws
  func delete(_ key: String) throws
  /// Whether a secret exists, without reading it.
  ///
  /// Separate from `get` because reading is the expensive and user-visible half: on the
  /// legacy keychain it can raise an access panel, and on any store it materialises a
  /// secret into memory. A screen that only needs to say "a password is stored" should not
  /// pay either price, which is what lets the settings screen read a secret ON DEMAND
  /// rather than on every appearance.
  func contains(_ key: String) throws -> Bool
}

extension SecretStore {
  /// The honest default: ask for the value and throw away everything but its presence.
  ///
  /// Correct for every store whose read is cheap and silent (`InMemorySecretStore`, the
  /// test fakes). `KeychainSecretStore` overrides it, because its read is neither.
  public func contains(_ key: String) throws -> Bool {
    try get(key) != nil
  }
}

/// A secret held as bytes rather than as a String, with a constant-time comparison.
///
/// **What this actually provides, stated honestly, because the header used to claim more.**
/// It said Swift Strings may persist in freed memory indefinitely and that this "zeroes on
/// deinit", which read as a memory-hygiene guarantee it does not deliver:
///
/// - `init(_ string:)` takes an ordinary String that is never zeroed, so the secret already
///   exists in unmanaged heap memory before this type sees it. So does anything
///   `unsafeStringValue()` hands back, and the byte array `constantTimeEquals` builds from a
///   candidate.
/// - The `deinit` loop is a dead store the optimiser is entitled to remove, which is exactly
///   why `memset_s` exists. It is kept because it costs nothing and may help; it is not
///   something to rely on.
///
/// What it does provide, and what every caller actually wants from it: a comparison that
/// does not short-circuit, and a type that makes materialising a secret as a String an
/// explicit, greppable act rather than the default. Narrowing construction to bytes and
/// using a real secure erase would make the stronger claim true; until someone does that,
/// the claim does not belong here.
public final class SecureString: @unchecked Sendable {

  private var bytes: [UInt8]

  public init(_ string: String) {
    bytes = Array(string.utf8)
  }

  public init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  deinit {
    // Best effort, and no more than that: see the type's header. A plain loop over a Swift
    // array is a dead store the optimiser may remove, so this is not the guarantee it
    // looks like.
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

  /// Constant-time comparison. See `ConstantTime` for what it does and does not hide.
  public func constantTimeEquals(_ candidate: String) -> Bool {
    ConstantTime.equals(bytes, Array(candidate.utf8))
  }
}

#if canImport(Security)

  /// Keychain-backed store, preferring the data protection keychain.
  ///
  /// Which store an item lands in is decided by `kSecUseDataProtectionKeychain` on every
  /// call. The two are separate backing stores: an item written to one is INVISIBLE to a
  /// query against the other, so this is not a flag that can be toggled per call site.
  ///
  /// **Why data protection.** Access is by code signature: an app outside the access group
  /// is refused outright, where the legacy keychain merely PROMPTS and a user who clicks
  /// Allow has granted access for good. `kSecAttrAccessible` is also honoured here and
  /// ignored there, so `ThisDeviceOnly` genuinely keeps the item out of a Time Machine
  /// backup rather than buying nothing.
  ///
  /// **Why the fallback.** The data protection keychain requires the
  /// `keychain-access-groups` entitlement, which is RESTRICTED: authorised only by an
  /// embedded provisioning profile, and only a bundle can carry one. A release build has
  /// both; `swift build` and an ad-hoc `Tools/dev-bundle.sh` have neither. Falling back keeps
  /// development working — but WHICH status says so depends on the operation, and
  /// `withStore` is where that is spelled out.
  ///
  /// The fallback is deliberately LOUD. A silent downgrade to the weaker store is worse than
  /// either store on its own, because nothing would ever reveal which one is in use:
  /// `usingDataProtection` exists so the app can say so, and so a test can assert it.
  /// What a status from the data protection keychain means for the legacy one.
  ///
  /// Its own type because the rule is the bug. Inside `withStore` it was three lines of
  /// control flow reachable only through a real Keychain on a real signature, so the case
  /// that was WRONG — a lookup answering `errSecItemNotFound` — could not be stated by any
  /// test, and the statuses it turns on had to be taken on trust from a comment. Here they
  /// are arguments, and `KeychainFallbackTests` pins all four combinations.
  enum KeychainFallback {

    struct Verdict: Equatable {
      /// Run the same operation against the legacy keychain.
      var retryOnLegacy: Bool
      /// Latch it: this process has no `keychain-access-groups`, so nothing should pay for
      /// the data protection attempt again.
      var entitlementIsMissing: Bool
    }

    /// - Parameters:
    ///   - status: what the data protection attempt returned.
    ///   - isLookup: whether the operation only READS an existing item; a delete has its
    ///     own rule, `deleteEverywhere`. A write must pass `false`:
    ///     `KeychainSecretStore.set` uses `errSecItemNotFound` from `SecItemUpdate` as its
    ///     own signal to insert, and reports the insert's status instead, so treating
    ///     not-found as a fallback there would write a second copy of a just-added item into
    ///     the legacy keychain.
    static func decide(status: OSStatus, isLookup: Bool) -> Verdict {
      // Measured on an ad-hoc-signed build, which is what `swift build` and
      // `Tools/dev-bundle.sh` produce:
      //
      //     SecItemCopyMatching(dataProtection: true) -> -25300  errSecItemNotFound
      //     SecItemAdd(dataProtection: true)          -> -34018  errSecMissingEntitlement
      //
      // Only the write says "no entitlement". The read just says the item is not there —
      // truthfully, because it is in the legacy keychain, where this same process put it.
      if status == errSecMissingEntitlement {
        return Verdict(retryOnLegacy: true, entitlementIsMissing: true)
      }
      // NOT a latch. Not-found is no evidence about the entitlement, and treating it as
      // some would send an entitled build's writes to the legacy keychain for the rest of
      // the process on nothing more than a first read of a key nobody had ever set.
      if isLookup, status == errSecItemNotFound {
        return Verdict(retryOnLegacy: true, entitlementIsMissing: false)
      }
      // Anything else is a real failure and is the caller's to report. Retrying a locked or
      // refused keychain against a different store turns one diagnosable error into two.
      return Verdict(retryOnLegacy: false, entitlementIsMissing: false)
    }

    /// A delete runs against BOTH keychains, not the first one that answers.
    ///
    /// `fallbackOnNotFound` is not enough for a delete. A key can be in both stores at once:
    /// an unentitled build wrote it to the legacy keychain, and an entitled one later wrote
    /// it to the data protection keychain. A delete that stopped at the data protection
    /// keychain's success left the legacy copy behind, and `get`, finding nothing in the
    /// data protection keychain, fell back to that copy, so a deleted secret came back on
    /// its next read: a cleared password still accepted, a revoked token still sent.
    ///
    /// - Parameters:
    ///   - dataProtection: the delete against the data protection keychain, or nil when the
    ///     entitlement is already known to be missing.
    ///   - legacy: the delete against the legacy keychain. Always run, unless the data
    ///     protection keychain REFUSED (anything but success, not-found or a missing
    ///     entitlement), which is reported as it is for every other operation.
    /// - Returns: success when either store removed an item, not-found when neither held
    ///   one, or the first real failure; and whether the entitlement turned out missing.
    static func deleteEverywhere(
      dataProtection: (() -> OSStatus)?, legacy: () -> OSStatus
    ) -> (status: OSStatus, entitlementIsMissing: Bool) {
      var entitlementIsMissing = false
      var removedOne = false
      if let dataProtection {
        let status = dataProtection()
        switch status {
        case errSecSuccess: removedOne = true
        case errSecItemNotFound: break
        case errSecMissingEntitlement: entitlementIsMissing = true
        default: return (status, false)
        }
      }
      let legacyStatus = legacy()
      switch legacyStatus {
      case errSecSuccess: removedOne = true
      case errSecItemNotFound: break
      default: return (legacyStatus, entitlementIsMissing)
      }
      return (removedOne ? errSecSuccess : errSecItemNotFound, entitlementIsMissing)
    }
  }

  public struct KeychainSecretStore: SecretStore {

    private let service: String

    /// Set once, on the first call that discovers the entitlement is absent.
    private static let entitlementIsMissing = Locked(false)

    /// No default. It used to be the real service name, so a caller that forgot to pass
    /// one silently reached the live Keychain items — defeating the `BB_SUPPORT_DIRECTORY`
    /// isolation `ApplicationSupport` exists to provide, in exactly the place where a test
    /// would then be writing the user's own secrets.
    public init(service: String) {
      self.service = service
    }

    /// Whether this process is actually using the data protection keychain.
    ///
    /// False means the entitlement was absent and secrets are in the legacy keychain, which
    /// is expected for a development build and a defect for a release one.
    public static var usingDataProtection: Bool { !entitlementIsMissing.value }

    /// Clears the latch, so a test can exercise the data protection attempt itself.
    ///
    /// The latch is what made the read bug invisible to the one check that should have
    /// caught it: `checkKeychainAndExit` writes its probe before it reads it, so the write
    /// latched and the read went straight to the legacy keychain and round-tripped. The app
    /// does the opposite — it reads a password long before it writes one — and that
    /// ordering is the whole difference. A test asserting the read path has to start from
    /// an unlatched process or it is asserting the probe's ordering all over again.
    static func resetEntitlementLatchForTesting() {
      entitlementIsMissing.withLock { $0 = false }
    }

    private func query(_ key: String, dataProtection: Bool) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      // The access GROUP is deliberately not specified. The entitlement names exactly one,
      // so a new item lands in it by default: naming it here would hardcode a team
      // identifier in source and break the moment the entitlement changed.
      if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
      return query
    }

    /// Runs `body` against the data protection keychain, falling back to the legacy one when
    /// the entitlement is absent, and — for a LOOKUP — when the item simply is not there.
    ///
    /// **Why "not found" is also a fallback, and why only for lookups.** The header says an
    /// unentitled build gets `errSecMissingEntitlement` from every call. That is true of a
    /// WRITE and false of a READ, and the asymmetry was silently losing secrets. Measured on
    /// an ad-hoc-signed build:
    ///
    ///     SecItemCopyMatching(dataProtection: true) -> -25300  errSecItemNotFound
    ///     SecItemAdd(dataProtection: true)          -> -34018  errSecMissingEntitlement
    ///
    /// So `set` latched `entitlementIsMissing` and wrote to the legacy keychain, while `get`
    /// took `-25300` as a final answer and never looked there. A password written by this
    /// very process read back as ABSENT, resolved to the declared default of `""`, and the
    /// settings screen showed an empty field for a password that was sitting in
    /// `login.keychain-db` the whole time — with no alert, because nothing had failed.
    ///
    /// A lookup therefore falls through on `errSecItemNotFound` too. It does NOT latch on
    /// one: not-found is not evidence about the entitlement, and claiming otherwise would
    /// send an entitled build's writes to the legacy store for the rest of the process, on
    /// nothing more than a first read of a key that had never been set.
    ///
    /// `set` passes `fallbackOnNotFound: false` and must: its own body uses
    /// `errSecItemNotFound` from `SecItemUpdate` as the signal to INSERT, so a fallback there
    /// would add a second copy of a freshly-added item to the legacy keychain.
    ///
    /// Any other failure is still returned as-is: quietly retrying a locked or refused
    /// keychain against a different store would turn one diagnosable error into two
    /// confusing ones.
    private func withStore(
      _ key: String, fallbackOnNotFound: Bool = false, _ body: ([String: Any]) -> OSStatus
    ) -> OSStatus {
      if !Self.entitlementIsMissing.value {
        let status = body(query(key, dataProtection: true))
        let verdict = KeychainFallback.decide(status: status, isLookup: fallbackOnNotFound)
        if verdict.entitlementIsMissing { Self.entitlementIsMissing.withLock { $0 = true } }
        guard verdict.retryOnLegacy else { return status }
      }
      return body(query(key, dataProtection: false))
    }

    /// Whether a secret exists, WITHOUT materialising it.
    ///
    /// Attributes only, deliberately: `kSecReturnData` on a legacy keychain item whose ACL
    /// does not already trust this binary raises the "BlueBubbles wants to use your
    /// confidential information" panel, and an ad-hoc rebuild invalidates that trust every
    /// time. This query does not, so the settings screen can say "a password is stored"
    /// on every appearance without a prompt, and read the value only when asked to.
    public func contains(_ key: String) throws -> Bool {
      var item: CFTypeRef?
      let status = withStore(key, fallbackOnNotFound: true) { base in
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, &item)
      }
      if status == errSecItemNotFound { return false }
      guard status == errSecSuccess else {
        throw SettingsError.keychainUnavailable(key: key, status: status)
      }
      return true
    }

    public func get(_ key: String) throws -> String? {
      var item: CFTypeRef?
      let status = withStore(key, fallbackOnNotFound: true) { base in
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
        // Honoured by the data protection keychain, where the legacy keychain ignores it:
        // see the header. `ThisDeviceOnly` genuinely excludes the item from a Time Machine
        // backup and from any sync.
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
        // the insert path too, otherwise a first write would never trigger the fallback.
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
      let status = KeychainFallback.deleteEverywhere(
        dataProtection: Self.entitlementIsMissing.value
          ? nil : { SecItemDelete(query(key, dataProtection: true) as CFDictionary) },
        legacy: { SecItemDelete(query(key, dataProtection: false) as CFDictionary) })
      if status.entitlementIsMissing { Self.entitlementIsMissing.withLock { $0 = true } }
      guard status.status == errSecSuccess || status.status == errSecItemNotFound else {
        throw SettingsError.keychainUnavailable(key: key, status: status.status)
      }
    }
  }

#endif

/// In-memory store for tests and for Linux CI, where Security is unavailable.
///
/// Never used in the shipping app: the composition root builds a `KeychainSecretStore`.
public final class InMemorySecretStore: SecretStore, Sendable {

  private let storage: Locked<[String: String]>

  public init(seed: [String: String] = [:]) {
    storage = Locked(seed)
  }

  public func get(_ key: String) throws -> String? {
    storage.withLock { $0[key] }
  }

  public func contains(_ key: String) throws -> Bool {
    storage.withLock { $0[key] != nil }
  }

  public func set(_ key: String, value: String) throws {
    storage.withLock { $0[key] = value }
  }

  public func delete(_ key: String) throws {
    storage.withLock { $0[key] = nil }
  }
}
