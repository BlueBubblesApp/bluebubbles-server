//  KeychainFallbackTests
//  The secret a build wrote and then could not read back.
//
//  `KeychainSecretStore` prefers the data protection keychain and falls back to the legacy
//  one when the `keychain-access-groups` entitlement is absent. The fallback was written as
//  if every call announced that the same way. It does not:
//
//      SecItemCopyMatching(kSecUseDataProtectionKeychain: true) -> -25300  errSecItemNotFound
//      SecItemAdd(kSecUseDataProtectionKeychain: true)          -> -34018  errSecMissingEntitlement
//
//  Both measured on an ad-hoc-signed build, which is what `swift build` and
//  `Tools/dev-bundle.sh` produce. So a WRITE reported the missing entitlement, latched, and
//  landed in `login.keychain-db`; a READ was told, truthfully, that the item was not in the
//  data protection keychain, took that as the final answer, and never looked in the store its
//  own write had just used. `password` resolved to the declared default of `""`, and the
//  Connection page rendered an empty field for a password sitting in the login keychain the
//  whole time — with no alert, because nothing had failed.
//
//  **Why nothing caught it.** `checkKeychainAndExit` performs exactly this round trip and
//  passes, because it WRITES the probe before it reads it: the write latches
//  `entitlementIsMissing`, so the read never attempts the data protection keychain at all.
//  The app does the opposite — it reads a password long before it ever writes one — and that
//  ordering is the entire difference. `resetEntitlementLatchForTesting` is here so these
//  tests start from the app's ordering rather than the probe's.

import Foundation
import Testing

@testable import BBSettings

#if canImport(Security)

  import Security

  @Suite("Keychain fallback")
  struct KeychainFallbackTests {

    // MARK: - The rule

    /// The case that was wrong, and the reason the type exists.
    @Test("A lookup that finds nothing in the data protection keychain tries the legacy one")
    func lookupFallsBackOnNotFound() {
      let verdict = KeychainFallback.decide(status: errSecItemNotFound, isLookup: true)
      #expect(verdict.retryOnLegacy)
      // Not-found says nothing about the entitlement. Latching here would send an entitled
      // build's writes to the legacy keychain for the rest of the process, on nothing more
      // than a first read of a key that had never been set.
      #expect(!verdict.entitlementIsMissing)
    }

    /// A write must NOT, and this is not symmetry for its own sake: `set` uses
    /// `errSecItemNotFound` from `SecItemUpdate` as its own signal to insert, then reports
    /// that status. Falling back on it would add a second copy of a just-added item to the
    /// legacy keychain.
    @Test("A write does not fall back merely because the item is not there yet")
    func writeDoesNotFallBackOnNotFound() {
      let verdict = KeychainFallback.decide(status: errSecItemNotFound, isLookup: false)
      #expect(!verdict.retryOnLegacy)
      #expect(!verdict.entitlementIsMissing)
    }

    @Test("A missing entitlement falls back and latches, whichever operation reported it")
    func missingEntitlementLatches() {
      for isLookup in [true, false] {
        let verdict = KeychainFallback.decide(
          status: errSecMissingEntitlement, isLookup: isLookup)
        #expect(verdict.retryOnLegacy)
        #expect(verdict.entitlementIsMissing)
      }
    }

    /// A locked keychain is a real failure with a real diagnosis. Retrying it against a
    /// different store turns one diagnosable error into two confusing ones, and would report
    /// "not set" for a keychain that is merely locked.
    @Test("A refusal is reported, not retried")
    func refusalIsNotRetried() {
      for isLookup in [true, false] {
        let verdict = KeychainFallback.decide(
          status: errSecInteractionNotAllowed, isLookup: isLookup)
        #expect(!verdict.retryOnLegacy)
        #expect(!verdict.entitlementIsMissing)
      }
    }

    // MARK: - The round trip, against the real Keychain

    /// The regression itself, end to end: an item in the LEGACY keychain, read by a store
    /// that has not yet learned the entitlement is missing — which is the app on launch.
    ///
    /// Seeded with `SecItemAdd` directly rather than through `set`, because going through
    /// `set` would latch on the way in and the read would then skip the data protection
    /// attempt entirely. That is precisely the shape that let `checkKeychainAndExit` pass
    /// over this bug.
    ///
    /// Its own service name per run, so nothing here can see or disturb the real
    /// installation's secrets. Both keychains are cleaned up whatever happens.
    @Test("A secret in the legacy keychain is found by a read that has not latched")
    func legacyItemIsFoundByAnUnlatchedRead() throws {
      let service = "app.bluebubbles.test.\(UUID().uuidString)"
      let account = "password"
      let expected = "correct-horse-battery-staple"

      func base(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: service,
          kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
      }

      defer {
        SecItemDelete(base(dataProtection: false) as CFDictionary)
        SecItemDelete(base(dataProtection: true) as CFDictionary)
      }

      var insert = base(dataProtection: false)
      insert[kSecValueData as String] = Data(expected.utf8)
      let seeded = SecItemAdd(insert as CFDictionary, nil)
      try #require(
        seeded == errSecSuccess,
        "could not seed the legacy keychain (OSStatus \(seeded))")

      KeychainSecretStore.resetEntitlementLatchForTesting()
      let store = KeychainSecretStore(service: service)

      // Before the fix this was nil: the data protection query answered `errSecItemNotFound`
      // and the store believed it.
      #expect(try store.get(account) == expected)
      // And the cheap presence check has to agree, or the settings row says "Not set" over
      // a value the reveal button then produces.
      #expect(try store.contains(account))
    }

    /// A key nothing wrote is absent from both stores, and says so rather than throwing.
    /// The fallback must not turn "there is nothing here" into an error.
    @Test("A key in neither keychain reads as absent")
    func absentKeyIsAbsent() throws {
      KeychainSecretStore.resetEntitlementLatchForTesting()
      let store = KeychainSecretStore(service: "app.bluebubbles.test.\(UUID().uuidString)")
      #expect(try store.get("password") == nil)
      #expect(try store.contains("password") == false)
    }

    /// The ordinary path still works: what this store writes, this store reads. Whichever
    /// keychain it lands in is the point of the fallback and not this test's business.
    @Test("A secret written through the store round-trips, and delete removes it")
    func roundTrip() throws {
      let service = "app.bluebubbles.test.\(UUID().uuidString)"
      let store = KeychainSecretStore(service: service)
      defer { try? store.delete("password") }

      try store.set("password", value: "first")
      #expect(try store.get("password") == "first")
      #expect(try store.contains("password"))

      // An update rather than an insert, which is the other half of `set`.
      try store.set("password", value: "second")
      #expect(try store.get("password") == "second")

      try store.delete("password")
      #expect(try store.get("password") == nil)
      #expect(try store.contains("password") == false)
    }
  }

#endif
