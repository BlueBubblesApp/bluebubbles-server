//  TLSRenewalTests
//  What a renewal writes, and the two loops that happen when it writes only half of it.
//
//  Both failures these cover were live, and neither was visible from the outside: every
//  renewal SUCCEEDED, the server bound TLS, and nothing was logged as wrong.
//
//    - A renewal was handed only the disk store, so Keychain-resident material was replaced
//      on disk and left alone in the Keychain, which is the store read first. The server went
//      on serving the certificate it had just decided to replace.
//    - Nothing advanced `tls_certificate_expires_at`. It is written by the migration runner
//      and the import view and by nothing else, so the renewal clock stayed at the old value
//      and `needsRenewal` stayed true for the life of the install.
//
//  The invariant that catches both, and the one worth stating: after a renewal, EVERY store
//  holds the new material and the recorded expiry is the new certificate's.

import BBBuiltIns
import BBCore
import BBPersistence
import BBServiceKit
import BBSettings
import BBSystem
import Foundation
import Logging
import Testing

@testable import BlueBubblesServerCore

@Suite("TLS renewal")
struct TLSRenewalTests {

  private func makeScope(_ secrets: InMemorySecretStore) async throws -> (
    ScopedSettings, SettingsStore
  ) {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let store = try await SettingsStore(database: database, secrets: secrets)
    try await store.set(Settings.useCustomCertificate, to: true)
    return (
      ScopedSettings(
        store: store, manifest: BuiltInManifests.http, secretKeys: Settings.secretKeys),
      store
    )
  }

  private func diskStore() -> CertificateStore {
    CertificateStore(
      directory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bb-tls-renew-\(UUID().uuidString)", isDirectory: true))
  }

  private func material() throws -> CertificateStore.Material {
    let generated = try CertificateAuthority.selfSigned(hostnames: ["localhost"])
    return CertificateStore.Material(
      certificatePEM: generated.certificatePEM, privateKeyPEM: generated.privateKeyPEM)
  }

  /// Marks the installed certificate as ours and already due, which is what makes the
  /// renewer act. A past date is deliberate: `needsRenewal` compares against a window, so
  /// "expired" and "due" take the same branch and the past one cannot be mistaken for luck.
  private func markDue(_ settings: SettingsStore) async throws {
    try await settings.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.selfSigned.rawValue)
    try await settings.set(
      Settings.tlsCertificateExpiresAt, to: Int(Date().timeIntervalSince1970) - 60)
  }

  @Test("A renewal replaces the material in the Keychain, not only on disk")
  func renewalWritesThroughToTheKeychain() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    let original = try material()
    try await keychain.install(original)
    try await markDue(store)

    let bound = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    let renewed = try #require(bound)
    #expect(renewed != original, "the certificate was due and should have been replaced")
    // The store that is read FIRST has to hold it, or the next start serves the old one.
    #expect(try await keychain.load() == renewed)
    // Nothing was written back to disk. The files are an adoption source, not a second store.
    #expect(disk.exists == false)
  }

  @Test("A renewal advances the clock, so the next start does not renew again")
  func renewalAdvancesTheRecordedExpiry() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    try await keychain.install(try material())
    try await markDue(store)

    let first = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    let recorded = await store.get(Settings.tlsCertificateExpiresAt)
    #expect(
      recorded > Int(Date().timeIntervalSince1970),
      "the recorded expiry is still in the past, so every start will renew again")

    // The actual symptom, asserted as a symptom: run it again and nothing should change.
    let second = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))
    #expect(first == second, "a second start renewed a certificate that was not due")
    #expect(await store.get(Settings.tlsCertificateExpiresAt) == recorded)
  }

  /// The one-way door. Files left by an older build (or by the Electron server, which used
  /// the same directory) are read once, moved in, and removed.
  @Test("Material found on disk is adopted into the Keychain and the files are removed")
  func diskMaterialIsAdopted() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    let existing = try material()
    try disk.install(existing)
    // No marker: the rule an older build used for "the user installed this".

    let bound = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(bound == existing, "adoption must not change what is served")
    #expect(try await keychain.load() == existing)
    #expect(disk.exists == false)
    // Provenance has to be carried across, or the renewer loses the one rule that protects a
    // certificate somebody paid for.
    #expect(
      await store.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.imported.rawValue)
  }

  /// A marker present means this server generated it, and that has to survive the move too;
  /// otherwise an adopted self-signed certificate is recorded as the user's own and is never
  /// renewed again.
  @Test("Adoption carries the expiry marker across as self-signed")
  func adoptionCarriesSelfSignedProvenance() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    try disk.install(try material())
    // Far enough out that it is not also due for renewal, which would confuse the assertion.
    let expiry = Date().addingTimeInterval(60 * 60 * 24 * 365)
    try disk.recordExpiration(expiry)

    _ = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(
      await store.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.selfSigned.rawValue)
    #expect(
      await store.get(Settings.tlsCertificateExpiresAt) == Int(expiry.timeIntervalSince1970))
    #expect(disk.exists == false)
  }

  /// A record written by the import view or the migration runner is better evidence than a
  /// file that may predate either, so adoption must not overwrite one.
  @Test("Adoption does not overwrite provenance that is already recorded")
  func adoptionRespectsAnExistingRecord() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    try disk.install(try material())
    // A marker on disk says "self-signed"…
    try disk.recordExpiration(Date().addingTimeInterval(60 * 60 * 24 * 365))
    // …but the settings say the user imported it, and those win.
    try await store.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.imported.rawValue)
    try await store.set(Settings.tlsCertificateExpiresAt, to: 1)

    _ = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(
      await store.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.imported.rawValue)
  }

  /// A store that accepts nothing, standing in for the failure this cannot afford to get
  /// wrong: a signed build whose provisioning profile did not embed, a locked Keychain, a
  /// `keychain-access-groups` mismatch. All of them surface here as a throwing `set`.
  private final class RefusingSecretStore: SecretStore, @unchecked Sendable {
    struct Refused: Error {}
    func get(_ key: String) throws -> String? { nil }
    func set(_ key: String, value: String) throws { throw Refused() }
    func delete(_ key: String) throws {}
  }

  /// The failure that must not cost the user their HTTPS.
  ///
  /// Adoption is an optimisation: the certificate already works where it is. A Keychain that
  /// refuses the write leaves the server exactly where it was, which means serving TLS from
  /// the files, not falling back to plaintext over a certificate it just read successfully.
  @Test("A Keychain that refuses the write keeps the files and still serves TLS")
  func failedAdoptionKeepsTheFilesAndBinds() async throws {
    let (scope, _) = try await makeScope(InMemorySecretStore())
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: RefusingSecretStore())

    let existing = try material()
    try disk.install(existing)

    let bound = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(bound == existing, "HTTPS must not be dropped over a store that refused a copy")
    #expect(disk.exists, "the files are the only copy and must survive")
    #expect(try disk.load() == existing)
  }

  @Test("Generating a certificate populates the Keychain, not just the files")
  func generationPopulatesTheKeychain() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    // Nothing anywhere: the fresh-install path.
    #expect(disk.exists == false)
    #expect(await keychain.exists() == false)

    let generated = try #require(
      await TLSProvisioning.material(
        settings: scope, store: disk, keychain: keychain, alerts: nil,
        logger: Logger(label: "test")))

    #expect(try await keychain.load() == generated)
    #expect(disk.exists == false, "generation must not create files")
    // And it says what it is, so the renewer may act on it later.
    #expect(
      await store.get(Settings.tlsCertificateOrigin) == TLSCertificateOrigin.selfSigned.rawValue)
    #expect(await store.get(Settings.tlsCertificateExpiresAt) > Int(Date().timeIntervalSince1970))
  }

  /// The direction that must never invert, asserted through the whole path rather than on
  /// the origin enum alone: a certificate somebody paid for is not ours to replace, however
  /// close to expiry it is.
  @Test("An imported certificate is never renewed, even when it is due")
  func importedIsNeverRenewed() async throws {
    let secrets = InMemorySecretStore()
    let (scope, store) = try await makeScope(secrets)
    let disk = diskStore()
    defer { disk.clear() }
    let keychain = CertificateKeychainStore(secrets: secrets)

    let theirs = try material()
    try await keychain.install(theirs)
    try await store.set(
      Settings.tlsCertificateOrigin, to: TLSCertificateOrigin.imported.rawValue)
    try await store.set(
      Settings.tlsCertificateExpiresAt, to: Int(Date().timeIntervalSince1970) - 60)

    let bound = await TLSProvisioning.material(
      settings: scope, store: disk, keychain: keychain, alerts: nil,
      logger: Logger(label: "test"))

    #expect(bound == theirs)
    #expect(try await keychain.load() == theirs)
  }
}
